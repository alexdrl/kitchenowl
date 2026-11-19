package com.tombursch.kitchenowl

import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * `kitchenowl/calendar_sync` (lib/services/phone_calendar.dart): turns the phone calendar of
 * the planned meals on and off. Turning it on asks for the calendar permissions first.
 */
class CalendarSyncChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private var pendingEnable: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(
                    CalendarSync.isEnabled(activity) && CalendarSync.hasPermissions(activity),
                )
                "enable" -> enable(result)
                "disable" -> {
                    CalendarSync.disable(activity)
                    result.success(true)
                }
                "requestSync" -> {
                    CalendarSync.requestSync(activity)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enable(result: MethodChannel.Result) {
        if (CalendarSync.hasPermissions(activity)) {
            result.success(CalendarSync.enable(activity))
            return
        }
        pendingEnable?.success(false)
        pendingEnable = result
        activity.requestPermissions(CalendarSync.PERMISSIONS, REQUEST_CODE)
    }

    /** From the activity's onRequestPermissionsResult. True when it was ours. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingEnable ?: return true
        pendingEnable = null
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        result.success(granted && CalendarSync.enable(activity))
        return true
    }

    companion object {
        const val CHANNEL = "kitchenowl/calendar_sync"
        private const val REQUEST_CODE = 4711
    }
}
