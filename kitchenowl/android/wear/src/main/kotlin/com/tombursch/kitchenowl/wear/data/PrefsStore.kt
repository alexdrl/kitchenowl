package com.tombursch.kitchenowl.wear.data

import android.content.Context
import com.tombursch.kitchenowl.wear.log.WearLog
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * The cached snapshot and the unconfirmed actions, as JSON in the app's private storage.
 * Nothing secret in here: the watch holds no token, only the shopping list the phone sent.
 */
class PrefsStore(context: Context) : WatchStore, MenuStorage {
    private val prefs = context.getSharedPreferences("watch", Context.MODE_PRIVATE)

    override fun loadSnapshot(): PhoneSnapshot? = read(KEY_SNAPSHOT)

    override fun saveSnapshot(snapshot: PhoneSnapshot) {
        prefs.edit().putString(KEY_SNAPSHOT, json.encodeToString(snapshot)).apply()
    }

    override fun loadQueue(): List<PendingAction> = read<Queue>(KEY_QUEUE)?.actions.orEmpty()

    override fun saveQueue(queue: List<PendingAction>) {
        // commit(): a tick must survive the process being killed right after the tap.
        prefs.edit().putString(KEY_QUEUE, json.encodeToString(Queue(queue))).commit()
    }

    override fun loadMenu(): PhoneMenu? = read(KEY_MENU)

    override fun saveMenu(menu: PhoneMenu) {
        prefs.edit().putString(KEY_MENU, json.encodeToString(menu)).apply()
    }

    override fun loadRequestedList(): Pair<Long, Long>? =
        if (prefs.contains(KEY_REQUESTED)) prefs.getLong(KEY_REQUESTED, 0) to prefs.getLong(KEY_REQUESTED_AT, 0) else null

    override fun saveRequestedList(listId: Long?, atMillis: Long) {
        prefs.edit().apply {
            if (listId == null) {
                remove(KEY_REQUESTED)
                remove(KEY_REQUESTED_AT)
            } else {
                putLong(KEY_REQUESTED, listId)
                putLong(KEY_REQUESTED_AT, atMillis)
            }
        }.apply()
    }

    private inline fun <reified T> read(key: String): T? = try {
        prefs.getString(key, null)?.let { json.decodeFromString<T>(it) }
    } catch (e: Exception) {
        WearLog.w("Prefs", "Unreadable stored $key", e)
        null
    }

    @Serializable
    private data class Queue(val actions: List<PendingAction>)

    private companion object {
        const val KEY_SNAPSHOT = "snapshot"
        const val KEY_MENU = "menu"
        const val KEY_QUEUE = "queue"
        const val KEY_REQUESTED = "requested_list"
        const val KEY_REQUESTED_AT = "requested_list_at"
    }
}
