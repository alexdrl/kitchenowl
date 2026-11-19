package com.tombursch.kitchenowl.wear.log

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

//   /kitchenowl/logs/<uuid>          watch -> phone  LogPayload, deleted by the phone once stored
//   /kitchenowl/logs-request/<id>    phone -> watch  LogRequest ("Send logs" on the phone)

const val LOGS_PATH = "/kitchenowl/logs"
const val LOGS_REQUEST_PATH = "/kitchenowl/logs-request"

/** The Data Layer allows 100 KB per item. */
const val MAX_LOG_ITEM_BYTES = 90_000

/**
 * A batch of the watch's log lines for the phone (WearLogInbox.kt in the phone app appends
 * [lines] to its inbox and sends them with its own logs under [resource]).
 */
@Serializable
data class LogPayload(
    val version: Int = 1,
    @SerialName("created_ms") val createdMs: Long,
    /** The phone's request this answers, so its "Send logs" knows the watch replied. */
    @SerialName("request_id") val requestId: String? = null,
    /** The watch's own "Send logs": the phone sends right away instead of at its next run. */
    @SerialName("upload_now") val uploadNow: Boolean = false,
    /** OpenTelemetry resource attributes: service.name, service.version, device.model.name, ... */
    val resource: Map<String, String>,
    /** JSON lines, newline-terminated. */
    val lines: String,
)

@Serializable
data class LogRequest(
    @SerialName("request_id") val requestId: String,
    @SerialName("created_ms") val createdMs: Long = 0,
)

private val logJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
}

fun encodeLogPayload(payload: LogPayload): ByteArray =
    logJson.encodeToString(LogPayload.serializer(), payload).toByteArray(Charsets.UTF_8)

fun decodeLogPayload(bytes: ByteArray): LogPayload? = try {
    logJson.decodeFromString(LogPayload.serializer(), bytes.toString(Charsets.UTF_8))
} catch (e: Exception) {
    null
}

fun parseLogRequest(bytes: ByteArray): LogRequest? = try {
    logJson.decodeFromString(LogRequest.serializer(), bytes.toString(Charsets.UTF_8))
} catch (e: Exception) {
    null
}

/** The id of `/kitchenowl/logs-request/<id>`, null for any other path. */
fun logRequestId(path: String?): String? {
    val prefix = "$LOGS_REQUEST_PATH/"
    if (path == null || !path.startsWith(prefix)) return null
    return path.removePrefix(prefix).takeIf { it.isNotEmpty() && '/' !in it }
}
