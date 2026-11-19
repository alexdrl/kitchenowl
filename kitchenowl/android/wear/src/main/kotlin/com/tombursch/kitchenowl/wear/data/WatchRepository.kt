package com.tombursch.kitchenowl.wear.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/** Hands an action to the Wearable Data Layer (Android: [DataLayerActionSink]). */
interface ActionSink {
    /** @return false when it could not even be handed over (it is retried later). */
    fun send(uuid: String, action: WatchAction): Boolean
}

/** Persistence of the last snapshot, the unconfirmed actions and the list the user picked. */
interface WatchStore {
    fun loadSnapshot(): PhoneSnapshot?
    fun saveSnapshot(snapshot: PhoneSnapshot)
    fun loadQueue(): List<PendingAction>
    fun saveQueue(queue: List<PendingAction>)
    fun loadRequestedList(): Pair<Long, Long>?
    fun saveRequestedList(listId: Long?, atMillis: Long)
}

/** What the screen and the tile show. */
data class WatchState(
    /** Null until the phone sent the first one. */
    val snapshot: PhoneSnapshot? = null,
    /** The snapshot's items with the unconfirmed actions applied. */
    val items: List<DisplayItem> = emptyList(),
    /** Remove/add actions the phone has not confirmed yet. */
    val pendingCount: Int = 0,
    /** The list the user picked on the watch, until the phone's snapshot shows it. */
    val requestedListId: Long? = null,
    /** A refresh request is on its way. */
    val refreshPending: Boolean = false,
) {
    val listName: String get() = snapshot?.listName.orEmpty()
    val lists: List<ListRef> get() = snapshot?.lists.orEmpty()
    val updatedMs: Long get() = snapshot?.updatedMs ?: 0
    val switchingList: Boolean get() = requestedListId != null && requestedListId != snapshot?.listId
}

/**
 * The watch's view of the list: the phone's snapshot plus what the user did since, until the
 * phone confirms it. No network here: actions go to the phone through [ActionSink].
 *
 * An action counts as confirmed when the phone deletes its Data Layer item (it applies the
 * action, deletes it, then publishes a new snapshot). It is then dropped at the next snapshot,
 * so an item the user removed does not come back for a moment between the two.
 */
class WatchRepository(
    private val sink: ActionSink,
    private val store: WatchStore,
    private val clock: () -> Long = System::currentTimeMillis,
    private val newUuid: () -> String = { UUID.randomUUID().toString() },
) {
    private val lock = Any()
    private var snapshot: PhoneSnapshot? = store.loadSnapshot()
    private val queue: MutableList<PendingAction> = store.loadQueue().toMutableList()
    private var requested: Pair<Long, Long>? = store.loadRequestedList()

    private val _state = MutableStateFlow(compute())
    val state: StateFlow<WatchState> = _state.asStateFlow()

    /** The phone published a (new) snapshot. */
    fun onSnapshot(new: PhoneSnapshot) = synchronized(lock) {
        val current = snapshot
        if (current != null && new.updatedMs < current.updatedMs) return@synchronized // stale delivery
        snapshot = new
        store.saveSnapshot(new)
        val now = clock()
        queue.removeAll { it.confirmed || now - it.action.createdMs > EXPIRY_MILLIS }
        if (requested?.first == new.listId) setRequested(null)
        persistQueue()
        publish()
    }

    /** The phone deleted an action's Data Layer item: it has applied it. */
    fun onActionDeleted(uuid: String) = synchronized(lock) {
        val i = queue.indexOfFirst { it.uuid == uuid }
        if (i < 0) return@synchronized
        queue[i] = queue[i].copy(confirmed = true)
        persistQueue()
        publish()
    }

    /** At start: actions that are no longer in the Data Layer were applied while we were away. */
    fun reconcile(existingUuids: Set<String>) = synchronized(lock) {
        var changed = false
        for (i in queue.indices) {
            val p = queue[i]
            if (p.sent && !p.confirmed && p.uuid !in existingUuids) {
                queue[i] = p.copy(confirmed = true)
                changed = true
            }
        }
        if (changed) {
            persistQueue()
            publish()
        }
    }

    /** Hand over what could not be handed over before. */
    fun resendUnsent() = synchronized(lock) {
        for (i in queue.indices) {
            val p = queue[i]
            if (!p.sent && !p.confirmed) queue[i] = p.copy(sent = sink.send(p.uuid, p.action))
        }
        persistQueue()
        publish()
    }

    /** The Data Layer refused the item after all. */
    fun markUnsent(uuid: String) = synchronized(lock) {
        val i = queue.indexOfFirst { it.uuid == uuid }
        if (i >= 0) {
            queue[i] = queue[i].copy(sent = false)
            persistQueue()
        }
    }

    /** Tap on an item: gone from the screen at once, removed on the phone when it can. */
    fun remove(item: WatchItem) = synchronized(lock) {
        val listId = snapshot?.listId ?: return@synchronized
        enqueue(WatchAction(ActionType.REMOVE, listId, item.id, item.name, item.description, clock()), item)
    }

    /** Undo: back at once. If the removal never left the watch the two cancel out. */
    fun undo(item: WatchItem) = synchronized(lock) {
        val listId = snapshot?.listId ?: return@synchronized
        val unsent = queue.firstOrNull {
            it.action.type == ActionType.REMOVE && !it.sent && !it.confirmed && it.item?.id == item.id
        }
        if (unsent != null) {
            queue.remove(unsent)
            persistQueue()
            publish()
        } else {
            enqueue(WatchAction(ActionType.ADD, listId, item.id, item.name, item.description, clock()), item)
        }
    }

    /** Ask the phone for another snapshot (not while an earlier request is still waiting). */
    fun refresh(): Boolean = synchronized(lock) {
        val listId = snapshot?.listId ?: requested?.first ?: 0L
        // An older request the phone never answered (it was away): ask again.
        val now = clock()
        queue.removeAll {
            it.action.type == ActionType.REFRESH && !it.confirmed && now - it.action.createdMs > REFRESH_RETRY_MILLIS
        }
        if (queue.any { it.action.type == ActionType.REFRESH && !it.confirmed }) return@synchronized false
        enqueue(WatchAction(ActionType.REFRESH, listId, createdMs = clock()), null)
        true
    }

    /** Pick another list: the phone answers with its snapshot. */
    fun selectList(listId: Long) = synchronized(lock) {
        if (listId == snapshot?.listId && requested == null) return@synchronized
        setRequested(listId)
        enqueue(WatchAction(ActionType.SELECT_LIST, listId, createdMs = clock()), null)
    }

    private fun setRequested(listId: Long?) {
        requested = listId?.let { it to clock() }
        store.saveRequestedList(listId, clock())
    }

    private fun enqueue(action: WatchAction, item: WatchItem?) {
        val uuid = newUuid()
        val sent = sink.send(uuid, action)
        queue.add(PendingAction(uuid, action, item, sent))
        persistQueue()
        publish()
    }

    private fun persistQueue() = store.saveQueue(queue.toList())

    private fun publish() {
        _state.value = compute()
    }

    private fun compute(): WatchState {
        val snap = snapshot
        var items = snap?.items.orEmpty().map { DisplayItem(it) }
        if (snap != null) {
            for (p in queue.sortedBy { it.action.createdMs }) {
                val item = p.item ?: continue
                if (p.action.listId != snap.listId) continue
                when (p.action.type) {
                    ActionType.REMOVE -> items = items.filterNot { same(it.item, item) }
                    ActionType.ADD ->
                        if (items.none { same(it.item, item) }) items = items + DisplayItem(item, pending = !p.confirmed)
                    else -> Unit
                }
            }
        }
        val req = requested?.takeIf { clock() - it.second < REQUEST_MILLIS }
        return WatchState(
            snapshot = snap,
            items = items,
            pendingCount = queue.count {
                (it.action.type == ActionType.REMOVE || it.action.type == ActionType.ADD) && !it.confirmed
            },
            requestedListId = req?.first,
            refreshPending = queue.any { it.action.type == ActionType.REFRESH && !it.confirmed },
        )
    }

    private fun same(a: WatchItem, b: WatchItem) = a.id == b.id || a.name.equals(b.name, ignoreCase = true)

    companion object {
        /** Unconfirmed actions older than this are forgotten (the phone was gone for good). */
        const val EXPIRY_MILLIS = 12 * 60 * 60 * 1000L

        /** An unanswered refresh request is replaced by a new one after this long. */
        const val REFRESH_RETRY_MILLIS = 60_000L

        /** "Switching list" is only shown for this long. */
        const val REQUEST_MILLIS = 60_000L
    }
}
