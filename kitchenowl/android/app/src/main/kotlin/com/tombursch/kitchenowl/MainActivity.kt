package com.tombursch.kitchenowl

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Facts for the summary of "Send logs" (lib/services/app_log_upload.dart)
        AppDiagnostics.install(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // Wear OS bridge (lib/services/wear_bridge.dart): the watch app's shopping list.
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WearBridge.CHANNEL)
        WearBridge.install(channel, applicationContext)
        WearBridge.uiChannel = channel
        WearBridge.scheduleRefresh(applicationContext)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        WearBridge.uiChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        WearBridge.uiResumed = true
    }

    override fun onPause() {
        WearBridge.uiResumed = false
        super.onPause()
    }
}
