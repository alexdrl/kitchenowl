package com.tombursch.kitchenowl

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var calendarSync: CalendarSyncChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Facts for the summary of "Send logs" (lib/services/app_log_upload.dart)
        AppDiagnostics.install(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        // Wear OS bridge (lib/services/wear_bridge.dart): the watch app's shopping list.
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WearBridge.CHANNEL)
        WearBridge.install(channel, applicationContext)
        WearBridge.uiChannel = channel
        WearBridge.scheduleRefresh(applicationContext)
        // Planned meals in the phone's calendar (CalendarSync.kt)
        calendarSync = CalendarSyncChannel(this, flutterEngine.dartExecutor.binaryMessenger)
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (calendarSync?.onRequestPermissionsResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
