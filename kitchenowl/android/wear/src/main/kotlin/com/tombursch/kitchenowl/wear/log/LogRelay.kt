package com.tombursch.kitchenowl.wear.log

import android.content.Context
import android.os.Build
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.tombursch.kitchenowl.wear.BuildConfig
import com.tombursch.kitchenowl.wear.ServiceLocator
import java.io.File
import java.util.UUID

/**
 * Hands the watch's log lines to the phone over the Data Layer. The watch never uses the
 * network, and this never syncs on its own: it rides along with something already being
 * sent (an action), or answers the phone's "Send logs", or the watch's own button.
 */
object LogRelay {
    private const val TAG = "LogRelay"
    private const val MAX_ITEMS = 3

    /** Next to an action the watch is writing anyway: only new lines, nothing when there are none. */
    fun withAction(context: Context) {
        send(context, requestId = null, uploadNow = false, summary = false)
    }

    /** The phone's "Send logs" asked: a summary and all new lines, tagged with its request. */
    fun answer(context: Context, requestId: String) {
        WearLog.i(TAG, "The phone asked for the logs")
        send(context, requestId = requestId, uploadNow = false, summary = true)
    }

    /** The watch's "Send logs": a summary and all new lines, and the phone sends them now. */
    fun sendNow(context: Context): Boolean {
        WearLog.i(TAG, "Send logs pressed on the watch")
        return send(context, requestId = null, uploadNow = true, summary = true)
    }

    @Synchronized
    private fun send(context: Context, requestId: String?, uploadNow: Boolean, summary: Boolean): Boolean {
        val ring = WearLog.ring ?: return false
        if (summary) WearLog.i(TAG, "Watch summary", summaryFields(ring))
        var sent = 0
        try {
            val client = Wearable.getDataClient(context)
            while (sent < MAX_ITEMS) {
                val batch = ring.takeNew(MAX_LOG_ITEM_BYTES) ?: break
                val payload = LogPayload(
                    createdMs = System.currentTimeMillis(),
                    requestId = requestId,
                    uploadNow = uploadNow,
                    resource = resource(context),
                    lines = batch.text,
                )
                val request = PutDataRequest.create("$LOGS_PATH/${UUID.randomUUID()}")
                    .setData(encodeLogPayload(payload))
                    .setUrgent()
                client.putDataItem(request)
                // Stored by the Data Layer on the watch, which delivers it when the phone is near.
                ring.commit(batch.end)
                sent++
            }
        } catch (e: Exception) {
            // Play services missing or the like: the lines stay for the next time.
            WearLog.w(TAG, "Could not hand the logs to the Data Layer", e)
            return false
        }
        return sent > 0
    }

    private fun resource(context: Context): Map<String, String> = mapOf(
        "service.name" to "kitchenowl-wear",
        "service.instance.id" to instanceId(context),
        "service.version" to BuildConfig.VERSION_NAME,
        "app.build" to BuildConfig.VERSION_CODE.toString(),
        "device.model.identifier" to Build.MODEL,
        "device.model.name" to Build.MODEL,
        "device.manufacturer" to Build.MANUFACTURER,
        "os.name" to "Wear OS",
        "os.version" to Build.VERSION.RELEASE,
    )

    /** A random id per install, like the phone's. */
    private fun instanceId(context: Context): String {
        val file = File(File(context.filesDir, "logs"), "instance-id")
        return try {
            file.readText().trim().ifEmpty { null }
        } catch (e: Exception) {
            null
        } ?: UUID.randomUUID().toString().replace("-", "").also {
            try {
                file.parentFile?.mkdirs()
                file.writeText(it)
            } catch (e: Exception) {
                // a new id next time is not a problem
            }
        }
    }

    private fun summaryFields(ring: LogRing): Map<String, Any?> {
        val state = ServiceLocator.repository.state.value
        val menu = ServiceLocator.menuRepository.state.value
        return mapOf(
            "version" to BuildConfig.VERSION_NAME,
            "snapshot_updated_ms" to state.snapshot?.updatedMs,
            "list_items" to state.items.size,
            "pending_actions" to state.pendingCount,
            "menu_updated_ms" to menu?.updatedMs,
            "menu_days" to menu?.days?.size,
            "log_bytes" to ring.totalBytes,
        )
    }
}
