package com.tombursch.kitchenowl

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Facts for the summary of "Send logs" (lib/services/app_log_upload.dart)
        AppDiagnostics.install(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
