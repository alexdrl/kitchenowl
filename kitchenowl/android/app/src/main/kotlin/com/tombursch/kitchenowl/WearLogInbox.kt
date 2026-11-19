package com.tombursch.kitchenowl

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.io.File

/**
 * The watch's log lines (`/kitchenowl/logs/<uuid>`, android/wear LogRelay.kt). They are appended
 * to `files/logs/inbox-kitchenowl-wear.jsonl`, which the Dart uploader
 * (lib/services/app_log_upload.dart) sends with the phone's own logs under the watch's resource
 * (`inbox-kitchenowl-wear.resource.json`). The item is then deleted from the Data Layer.
 *
 * No network and no Flutter engine here: the lines wait for the next upload, except when the
 * watch's own "Send logs" asks for one now ([uploadNow]).
 */
object WearLogInbox {
    const val LOGS_PATH = "/kitchenowl/logs"
    const val REQUEST_PATH = "/kitchenowl/logs-request"
    private const val SERVICE = "kitchenowl-wear"
    private const val TAG = "WearLogInbox"

    /** Never more than this waiting for an upload: the oldest lines go first. */
    private const val MAX_INBOX_BYTES = 1_000_000L

    private fun dir(context: Context) = File(context.filesDir, "logs").apply { mkdirs() }

    /** What one payload asked for. */
    data class Received(val requestId: String?, val uploadNow: Boolean, val version: String?, val lines: Int)

    fun isLogsPath(path: String?) = path?.startsWith("$LOGS_PATH/") == true

    /** Stores [item]'s lines and deletes it. Null when it was not a payload we understand. */
    @Synchronized
    fun receive(context: Context, item: DataItem): Received? {
        val data = item.data ?: return null
        val received = try {
            store(context, data)
        } catch (e: Exception) {
            Log.w(TAG, "Unreadable log payload from the watch", e)
            null
        }
        Wearable.getDataClient(context).deleteDataItems(item.uri)
        return received
    }

    private fun store(context: Context, data: ByteArray): Received {
        val json = JSONObject(String(data, Charsets.UTF_8))
        val lines = json.optString("lines", "")
        val dir = dir(context)
        val inbox = File(dir, "inbox-$SERVICE.jsonl")
        if (inbox.length() + lines.length > MAX_INBOX_BYTES) {
            // Nobody sent them for a long time: keep the newest.
            inbox.delete()
        }
        if (lines.isNotEmpty()) {
            inbox.appendText(if (lines.endsWith("\n")) lines else "$lines\n", Charsets.UTF_8)
        }
        val resource = json.optJSONObject("resource")
        if (resource != null) {
            File(dir, "inbox-$SERVICE.resource.json").writeText(resource.toString(), Charsets.UTF_8)
        }
        val requestId = json.optString("request_id").takeIf { it.isNotEmpty() && !json.isNull("request_id") }
        val uploadNow = json.optBoolean("upload_now", false)
        if (uploadNow) {
            // Read by AppLogUploader: the next run sends even before its interval.
            File(dir, "upload-now").createNewFile()
        }
        return Received(
            requestId = requestId,
            uploadNow = uploadNow,
            version = resource?.optString("service.version"),
            lines = lines.count { it == '\n' },
        )
    }

    /**
     * Payloads that arrived while nothing was listening (the service is normally woken for each
     * one; this is the safety net, called when Dart reads the pending actions).
     */
    fun drain(context: Context, onReceived: (Received) -> Unit) {
        val uri = Uri.Builder().scheme("wear").path(LOGS_PATH).build()
        Wearable.getDataClient(context).getDataItems(uri, DataClient.FILTER_PREFIX)
            .addOnSuccessListener { items ->
                try {
                    for (item in items) {
                        if (isLogsPath(item.uri.path)) receive(context, item)?.let(onReceived)
                    }
                } finally {
                    items.release()
                }
            }
    }
}
