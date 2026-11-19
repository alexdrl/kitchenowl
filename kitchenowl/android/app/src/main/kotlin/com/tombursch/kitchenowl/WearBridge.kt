package com.tombursch.kitchenowl

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * Native half of lib/services/wear_bridge.dart: the Wearable Data Layer for the KitchenOwl
 * Wear OS app (kitchenowl/android/wear). The watch has no network access and no token.
 *
 *  - phone to watch: `/kitchenowl/shoppinglist`, the JSON built by Dart (WearSnapshot), and
 *    `/kitchenowl/menu`, the planned menu (WearMenu)
 *  - watch to phone: `/kitchenowl/actions/<uuid>`, one item per action, deleted once applied
 *
 * The same channel handler is installed in the UI engine (MainActivity) and in the headless
 * engine of [WearActionsWorker]; all the logic stays in Dart.
 */
object WearBridge {
    const val CHANNEL = "com.tombursch.kitchenowl/wear"
    const val SNAPSHOT_PATH = "/kitchenowl/shoppinglist"
    const val MENU_PATH = "/kitchenowl/menu"
    const val ACTIONS_PATH = "/kitchenowl/actions"

    private const val WORK_ACTIONS = "wear-actions"
    private const val WORK_REFRESH = "wear-refresh"

    /** Engine of the visible app, when there is one. */
    @Volatile var uiChannel: MethodChannel? = null
    @Volatile var uiResumed = false

    /** Engine started by [WearActionsWorker], while it runs. */
    @Volatile var headlessChannel: MethodChannel? = null
    @Volatile var onHeadlessDone: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())

    fun install(channel: MethodChannel, context: Context) {
        val app = context.applicationContext
        channel.setMethodCallHandler { call, result -> handle(app, call, result) }
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "publishSnapshot" -> publish(context, SNAPSHOT_PATH, call.arguments as String, result)
                "publishMenu" -> publish(context, MENU_PATH, call.arguments as String, result)
                "pendingActions" -> pendingActions(context, result)
                "ackActions" -> ack(context, call.arguments as List<*>, result)
                "headlessDone" -> {
                    onHeadlessDone?.invoke()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Typically Google Play services missing: Dart treats it as "no watch".
            result.error("wear_unavailable", e.message, null)
        }
    }

    private fun publish(context: Context, path: String, json: String, result: MethodChannel.Result) {
        val request = PutDataRequest.create(path)
            .setData(json.toByteArray(Charsets.UTF_8))
            .setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { e -> result.error("publish_failed", e.message, null) }
    }

    /** Every action item currently in the Data Layer: [{uri, json}]. */
    private fun pendingActions(context: Context, result: MethodChannel.Result) {
        val uri = Uri.Builder().scheme("wear").path(ACTIONS_PATH).build()
        Wearable.getDataClient(context).getDataItems(uri, DataClient.FILTER_PREFIX)
            .addOnSuccessListener { items ->
                val out = try {
                    items.map {
                        mapOf(
                            "uri" to it.uri.toString(),
                            "json" to (it.data?.toString(Charsets.UTF_8) ?: ""),
                        )
                    }
                } finally {
                    items.release()
                }
                result.success(out)
            }
            .addOnFailureListener { e -> result.error("read_failed", e.message, null) }
    }

    /** The actions were applied (or are garbage): remove them from the Data Layer. */
    private fun ack(context: Context, uris: List<*>, result: MethodChannel.Result) {
        val client = Wearable.getDataClient(context)
        val tasks = uris.filterIsInstance<String>().map { client.deleteDataItems(Uri.parse(it)) }
        Tasks.whenAllComplete(tasks).addOnCompleteListener { result.success(null) }
    }

    /** The watch wrote an action. Called from [WearActionsService], on a binder thread. */
    fun onActionsWritten(context: Context) {
        val app = context.applicationContext
        main.post {
            val ui = uiChannel
            val headless = headlessChannel
            when {
                // The app is open: Dart handles it right here.
                ui != null && uiResumed -> ui.invokeMethod("actionsChanged", null)
                // A headless run is going: it will loop once more.
                headless != null -> headless.invokeMethod("actionsChanged", null)
                else -> enqueueActionsWork(app)
            }
        }
    }

    /**
     * Expedited work: runs right away with foreground-service priority, so the process is
     * not frozen as a cached app while the headless engine talks to the server.
     * It waits for a network because applying an action needs the server (without one the
     * action simply stays in the Data Layer, and the watch shows it as not confirmed).
     */
    private fun enqueueActionsWork(context: Context) {
        val builder = OneTimeWorkRequest.Builder(WearActionsWorker::class.java)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
        // Before Android 12 expedited work needs a foreground notification; plain work will do there.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        val request = builder.build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_ACTIONS, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    /** Republish the list to the watch every ~30 minutes (skipped when no watch is connected). */
    fun scheduleRefresh(context: Context) {
        val request = PeriodicWorkRequest.Builder(WearActionsWorker::class.java, 30, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setInputData(androidx.work.Data.Builder().putBoolean(WearActionsWorker.KEY_PERIODIC, true).build())
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(WORK_REFRESH, ExistingPeriodicWorkPolicy.KEEP, request)
    }
}
