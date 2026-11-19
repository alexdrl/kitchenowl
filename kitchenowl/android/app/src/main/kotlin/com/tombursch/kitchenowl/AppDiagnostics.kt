package com.tombursch.kitchenowl

import android.app.ActivityManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * System facts for the summary record of "Send logs" (AppDiagnostics in
 * lib/services/app_log_upload.dart): what decides whether background work runs at all.
 */
object AppDiagnostics {
    const val CHANNEL = "com.tombursch.kitchenowl/diagnostics"

    fun install(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "snapshot") {
                try {
                    result.success(snapshot(app))
                } catch (e: Exception) {
                    result.error("diagnostics_failed", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    fun snapshot(context: Context): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        val power = context.getSystemService(PowerManager::class.java)
        out["power_save_mode"] = power?.isPowerSaveMode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val notifications = context.getSystemService(NotificationManager::class.java)
            out["notifications_enabled"] = notifications?.areNotificationsEnabled()
            out["battery_optimization_ignored"] = power?.isIgnoringBatteryOptimizations(context.packageName)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val usage = context.getSystemService(UsageStatsManager::class.java)
            out["standby_bucket"] = when (val bucket = usage?.appStandbyBucket) {
                UsageStatsManager.STANDBY_BUCKET_ACTIVE -> "active"
                UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> "working_set"
                UsageStatsManager.STANDBY_BUCKET_FREQUENT -> "frequent"
                UsageStatsManager.STANDBY_BUCKET_RARE -> "rare"
                45 -> "restricted" // STANDBY_BUCKET_RESTRICTED, API 30
                null -> null
                else -> bucket.toString()
            }
            val activity = context.getSystemService(ActivityManager::class.java)
            out["background_restricted"] = activity?.isBackgroundRestricted
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            out["data_saver"] = when (connectivity?.restrictBackgroundStatus) {
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED -> "enabled"
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED -> "allowed_for_app"
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED -> "disabled"
                else -> null
            }
        }
        out["sdk"] = Build.VERSION.SDK_INT
        return out
    }
}
