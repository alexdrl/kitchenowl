package com.tombursch.kitchenowl

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.google.android.gms.wearable.Wearable
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs `wearActionsMain` (lib/services/wear_bridge.dart) in a headless FlutterEngine: connects
 * to the server like the background fetch does, applies the watch's actions with the normal
 * transactions, republishes the list and calls `headlessDone`.
 *
 * Used for actions written while the app is not open, and (periodic mode) to refresh the
 * watch's list every ~30 minutes when a watch is connected.
 */
class WearActionsWorker(context: Context, params: WorkerParameters) : ListenableWorker(context, params) {
    private val main = Handler(Looper.getMainLooper())

    override fun startWork(): ListenableFuture<Result> =
        CallbackToFutureAdapter.getFuture { completer ->
            if (inputData.getBoolean(KEY_PERIODIC, false)) {
                // No point in waking Dart (and the server) when there is no watch.
                Wearable.getNodeClient(applicationContext).connectedNodes
                    .addOnSuccessListener { nodes ->
                        if (nodes.isEmpty()) completer.set(Result.success()) else runEngine(completer)
                    }
                    .addOnFailureListener { completer.set(Result.success()) }
            } else {
                runEngine(completer)
            }
            "WearActionsWorker"
        }

    private fun runEngine(completer: CallbackToFutureAdapter.Completer<Result>) {
        main.post {
            if (WearBridge.headlessChannel != null) {
                // Another run is active and picks the actions up on its next loop.
                WearBridge.headlessChannel?.invokeMethod("actionsChanged", null)
                completer.set(Result.success())
                return@post
            }
            var engine: FlutterEngine? = null
            var finished = false
            fun finish(result: Result) {
                if (finished) return
                finished = true
                WearBridge.headlessChannel = null
                WearBridge.onHeadlessDone = null
                main.removeCallbacksAndMessages(TIMEOUT_TOKEN)
                engine?.destroy()
                completer.set(result)
            }
            try {
                val ctx = applicationContext
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(ctx)
                loader.ensureInitializationComplete(ctx, null)

                val flutterEngine = FlutterEngine(ctx) // also registers the plugins (secure storage, ...)
                engine = flutterEngine
                val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WearBridge.CHANNEL)
                WearBridge.install(channel, ctx)
                WearBridge.headlessChannel = channel
                WearBridge.onHeadlessDone = { finish(Result.success()) }
                // Dart has its own timeouts; this is the backstop. The actions stay in the Data
                // Layer until applied, so a cut run is only a delay.
                main.postAtTime({ finish(Result.success()) }, TIMEOUT_TOKEN, android.os.SystemClock.uptimeMillis() + TIMEOUT_MILLIS)

                flutterEngine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        "package:kitchenowl/services/wear_bridge.dart",
                        "wearActionsMain",
                    ),
                )
            } catch (e: Throwable) {
                finish(Result.failure())
            }
        }
    }

    override fun onStopped() {
        // WorkManager cancelled us (e.g. the expedited quota): drop the engine.
        main.post { WearBridge.onHeadlessDone?.invoke() }
    }

    companion object {
        const val KEY_PERIODIC = "periodic"
        private const val TIMEOUT_MILLIS = 100_000L
        private val TIMEOUT_TOKEN = Any()
    }
}
