package com.tombursch.kitchenowl.wear.log

import android.content.Context
import android.util.Log
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/**
 * The watch app's log: logcat as before, plus a ~200 KB [LogRing] on disk that the phone
 * receives over the Data Layer ([LogRelay]) and sends with its own logs as
 * `service.name=kitchenowl-wear`. Lines use the phone's format (lib/services/app_log.dart):
 * `{"t": ms, "l": "warn", "m": "...", "src": "wear", "f": {...}, "et": "...", "e": "...", "st": "..."}`.
 */
object WearLog {
    @Volatile
    var ring: LogRing? = null
        private set

    fun init(context: Context) {
        if (ring != null) return
        ring = LogRing(File(context.filesDir, "logs"))
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            write("error", "Crash", "Uncaught exception in ${thread.name}", e, emptyMap())
            previous?.uncaughtException(thread, e)
        }
    }

    fun d(tag: String, message: String, fields: Map<String, Any?> = emptyMap()) {
        Log.d(TAG_PREFIX + tag, message)
        write("debug", tag, message, null, fields)
    }

    fun i(tag: String, message: String, fields: Map<String, Any?> = emptyMap()) {
        Log.i(TAG_PREFIX + tag, message)
        write("info", tag, message, null, fields)
    }

    fun w(tag: String, message: String, e: Throwable? = null, fields: Map<String, Any?> = emptyMap()) {
        Log.w(TAG_PREFIX + tag, message, e)
        write("warn", tag, message, e, fields)
    }

    fun e(tag: String, message: String, e: Throwable? = null, fields: Map<String, Any?> = emptyMap()) {
        Log.e(TAG_PREFIX + tag, message, e)
        write("error", tag, message, e, fields)
    }

    private fun write(level: String, tag: String, message: String, e: Throwable?, fields: Map<String, Any?>) {
        try {
            ring?.append(encodeLine(System.currentTimeMillis(), level, tag, message, e, fields))
        } catch (_: Exception) {
            // logging must never break the app
        }
    }

    /** One line of the file (also used by the tests). */
    fun encodeLine(
        timeMs: Long,
        level: String,
        tag: String,
        message: String,
        e: Throwable?,
        fields: Map<String, Any?>,
    ): String = buildJsonObject {
        put("t", timeMs)
        put("l", level)
        put("m", message.take(MAX_MESSAGE))
        put("src", "wear")
        put("f", buildJsonObject {
            put("tag", tag)
            for ((k, v) in fields) {
                when (v) {
                    null -> {}
                    is Number -> put(k, JsonPrimitive(v))
                    is Boolean -> put(k, v)
                    else -> put(k, v.toString())
                }
            }
        })
        if (e != null) {
            put("et", e.javaClass.name)
            put("e", (e.message ?: "").take(MAX_MESSAGE))
            put("st", e.stackTraceToString().take(MAX_STACK))
        }
    }.toString()

    private const val TAG_PREFIX = "KO."
    private const val MAX_MESSAGE = 2_000
    private const val MAX_STACK = 4_000
}
