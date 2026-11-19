package com.tombursch.kitchenowl.wear.data

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

internal val json = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    // actions omit what they do not use (item_id of a refresh, ...)
    explicitNulls = false
    encodeDefaults = true
}

/** Null for anything that is not a snapshot we understand (a newer `version` is still read). */
fun parseSnapshot(bytes: ByteArray): PhoneSnapshot? = try {
    json.decodeFromString<PhoneSnapshot>(bytes.toString(Charsets.UTF_8))
} catch (e: SerializationException) {
    null
} catch (e: IllegalArgumentException) {
    null
}

/** Null for anything that is not a menu we understand. */
fun parseMenu(bytes: ByteArray): PhoneMenu? = try {
    json.decodeFromString<PhoneMenu>(bytes.toString(Charsets.UTF_8))
} catch (e: SerializationException) {
    null
} catch (e: IllegalArgumentException) {
    null
}

fun encodeAction(action: WatchAction): ByteArray =
    json.encodeToString(WatchAction.serializer(), action).toByteArray(Charsets.UTF_8)

/** The uuid of `/kitchenowl/actions/<uuid>`, null for any other path. */
fun actionUuid(path: String?): String? {
    val prefix = "$ACTIONS_PATH/"
    if (path == null || !path.startsWith(prefix)) return null
    return path.removePrefix(prefix).takeIf { it.isNotEmpty() && '/' !in it }
}
