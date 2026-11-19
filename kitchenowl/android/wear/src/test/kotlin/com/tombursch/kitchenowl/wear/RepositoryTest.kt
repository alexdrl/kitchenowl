package com.tombursch.kitchenowl.wear

import com.tombursch.kitchenowl.wear.data.ActionSink
import com.tombursch.kitchenowl.wear.data.ActionType
import com.tombursch.kitchenowl.wear.data.ListRef
import com.tombursch.kitchenowl.wear.data.PendingAction
import com.tombursch.kitchenowl.wear.data.PhoneSnapshot
import com.tombursch.kitchenowl.wear.data.WatchAction
import com.tombursch.kitchenowl.wear.data.WatchItem
import com.tombursch.kitchenowl.wear.data.WatchRepository
import com.tombursch.kitchenowl.wear.data.WatchStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private val milk = WatchItem(1, "Milk", "2 l", "Dairy")
private val butter = WatchItem(2, "Butter", "", "Dairy")
private val bread = WatchItem(3, "Bread")

private fun snapshot(updated: Long, listId: Long = 7, vararg items: WatchItem) = PhoneSnapshot(
    householdId = 1,
    listId = listId,
    listName = "List $listId",
    updatedMs = updated,
    lists = listOf(ListRef(7, "List 7"), ListRef(8, "List 8")),
    items = items.toList(),
)

private class FakeStore : WatchStore {
    var snapshot: PhoneSnapshot? = null
    var queue: List<PendingAction> = emptyList()
    var requested: Pair<Long, Long>? = null
    override fun loadSnapshot() = snapshot
    override fun saveSnapshot(snapshot: PhoneSnapshot) { this.snapshot = snapshot }
    override fun loadQueue() = queue
    override fun saveQueue(queue: List<PendingAction>) { this.queue = queue }
    override fun loadRequestedList() = requested
    override fun saveRequestedList(listId: Long?, atMillis: Long) { requested = listId?.let { it to atMillis } }
}

private class FakeSink : ActionSink {
    var accept = true
    val sent = mutableListOf<Pair<String, WatchAction>>()
    override fun send(uuid: String, action: WatchAction): Boolean {
        if (accept) sent += uuid to action
        return accept
    }
    val types get() = sent.map { it.second.type }
}

class RepositoryTest {
    private var now = 10_000L
    private var counter = 0
    private val store = FakeStore()
    private val sink = FakeSink()

    private fun repo() = WatchRepository(sink, store, { now }, { "u${++counter}" })
    private fun WatchRepository.names() = state.value.items.map { it.item.name }

    @Test
    fun nothingShownUntilThePhoneSendsAList() {
        val r = repo()
        assertNull(r.state.value.snapshot)
        assertTrue(r.state.value.items.isEmpty())
        r.onSnapshot(snapshot(1, 7, milk))
        assertEquals(listOf("Milk"), r.names())
        assertEquals("List 7", r.state.value.listName)
    }

    @Test
    fun theSnapshotSurvivesARestart() {
        repo().onSnapshot(snapshot(1, 7, milk, butter))
        // no Data Layer, no phone: the cached list is there
        assertEquals(listOf("Milk", "Butter"), repo().names())
    }

    @Test
    fun anOlderSnapshotIsIgnored() {
        val r = repo()
        r.onSnapshot(snapshot(5, 7, milk))
        r.onSnapshot(snapshot(3, 7, butter))
        assertEquals(listOf("Milk"), r.names())
    }

    @Test
    fun tickingHidesAtOnceAndWritesARemoveAction() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        now = 12_000
        r.remove(milk)

        assertEquals(listOf("Bread"), r.names())
        assertEquals(1, r.state.value.pendingCount)
        val (uuid, action) = sink.sent.single()
        assertEquals("u1", uuid)
        assertEquals(ActionType.REMOVE, action.type)
        assertEquals(7L, action.listId)
        assertEquals(1L, action.itemId)
        assertEquals("Milk", action.itemName)
        assertEquals(12_000L, action.createdMs)
    }

    @Test
    fun theTickStaysHiddenBetweenTheConfirmationAndTheNewSnapshot() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        // the phone applied it and deleted the action; its new snapshot is not here yet
        r.onActionDeleted("u1")
        assertEquals(listOf("Bread"), r.names())
        assertEquals(0, r.state.value.pendingCount) // confirmed, no longer "not confirmed"
    }

    @Test
    fun anUnconfirmedTickIsKeptAcrossSnapshots() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        // the phone is away and republishes an old state; the action is still waiting
        r.onSnapshot(snapshot(2, 7, milk, bread))
        assertEquals(listOf("Bread"), r.names())
        assertEquals(1, r.state.value.pendingCount)
    }

    @Test
    fun confirmedActionsAreDroppedWhenTheNextSnapshotArrives() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        r.onActionDeleted("u1")
        r.onSnapshot(snapshot(2, 7, bread))
        assertEquals(listOf("Bread"), r.names())
        assertTrue(store.queue.isEmpty())
    }

    @Test
    fun undoAfterTheActionWasSentWritesAnAddAndShowsTheItemAsNotConfirmed() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        r.undo(milk)

        assertEquals(listOf(ActionType.REMOVE, ActionType.ADD), sink.types)
        val add = sink.sent[1].second
        assertEquals("Milk", add.itemName)
        assertEquals("2 l", add.description)
        // back on screen at once, marked until the phone confirms
        val shown = r.state.value.items
        assertEquals(listOf("Bread", "Milk"), shown.map { it.item.name })
        assertTrue(shown.first { it.item.name == "Milk" }.pending)
        assertFalse(shown.first { it.item.name == "Bread" }.pending)

        // the phone applies both, in order, and sends a snapshot with the item
        r.onActionDeleted("u1")
        r.onActionDeleted("u2")
        r.onSnapshot(snapshot(2, 7, milk, bread))
        assertEquals(listOf("Milk", "Bread"), r.names())
        assertTrue(r.state.value.items.none { it.pending })
        assertEquals(0, r.state.value.pendingCount)
    }

    @Test
    fun undoBeforeTheActionLeftTheWatchCancelsIt() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        sink.accept = false // no Data Layer right now
        r.remove(milk)
        r.undo(milk)
        assertEquals(0, r.state.value.pendingCount)
        assertEquals(listOf("Milk", "Bread"), r.names())
        sink.accept = true
        r.resendUnsent()
        assertTrue(sink.sent.isEmpty())
    }

    @Test
    fun unsentActionsAreHandedOverLater() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        sink.accept = false
        r.remove(milk)
        assertTrue(sink.sent.isEmpty())
        assertEquals(1, r.state.value.pendingCount)

        sink.accept = true
        r.resendUnsent()
        assertEquals(listOf(ActionType.REMOVE), sink.types)
        r.resendUnsent() // not twice
        assertEquals(1, sink.sent.size)
    }

    @Test
    fun theQueueSurvivesARestartAndIsReconciledWithTheDataLayer() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, butter, bread))
        r.remove(milk)
        r.remove(butter)

        val restarted = repo()
        assertEquals(listOf("Bread"), restarted.names())
        assertEquals(2, restarted.state.value.pendingCount)

        // while the app was closed the phone applied u1 (its item is gone), u2 still waits
        restarted.reconcile(setOf("u2"))
        assertEquals(1, restarted.state.value.pendingCount)
        assertEquals(listOf("Bread"), restarted.names())
    }

    @Test
    fun anActionTheDataLayerRefusedIsNotReconciledAway() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        r.markUnsent("u1") // the async put failed
        r.reconcile(emptySet())
        assertEquals(1, r.state.value.pendingCount)
        r.resendUnsent()
        assertEquals(2, sink.sent.size)
    }

    @Test
    fun actionsOfAnotherListAreNotAppliedToThisOne() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk) // list 7
        r.onSnapshot(snapshot(2, 8, WatchItem(1, "Milk"), butter)) // phone shows list 8
        assertEquals(listOf("Milk", "Butter"), r.names())
    }

    @Test
    fun staleUnconfirmedActionsExpire() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk, bread))
        r.remove(milk)
        now += WatchRepository.EXPIRY_MILLIS + 1
        r.onSnapshot(snapshot(2, 7, milk, bread))
        assertEquals(listOf("Milk", "Bread"), r.names())
        assertEquals(0, r.state.value.pendingCount)
    }

    @Test
    fun refreshIsAskedOnceUntilTheAnswerComes() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk))
        assertTrue(r.refresh())
        assertTrue(r.state.value.refreshPending)
        assertFalse(r.refresh()) // still waiting: no second request
        assertEquals(listOf(ActionType.REFRESH), sink.types)
        // refresh requests are not "changes not confirmed yet"
        assertEquals(0, r.state.value.pendingCount)

        r.onActionDeleted("u1")
        r.onSnapshot(snapshot(2, 7, milk))
        assertFalse(r.state.value.refreshPending)
        assertTrue(r.refresh())
    }

    @Test
    fun anUnansweredRefreshIsAskedAgainAfterAWhile() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk))
        r.refresh()
        now += WatchRepository.REFRESH_RETRY_MILLIS + 1
        assertTrue(r.refresh())
        assertEquals(2, sink.sent.size)
    }

    @Test
    fun pickingAListAsksThePhoneAndWaitsForItsSnapshot() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk))
        r.selectList(8)
        assertEquals(ActionType.SELECT_LIST, sink.sent.single().second.type)
        assertEquals(8L, sink.sent.single().second.listId)
        assertTrue(r.state.value.switchingList)
        assertEquals(listOf("Milk"), r.names()) // the old list stays until the phone answers

        r.onSnapshot(snapshot(2, 8, butter))
        assertFalse(r.state.value.switchingList)
        assertEquals("List 8", r.state.value.listName)
        assertEquals(listOf("Butter"), r.names())
    }

    @Test
    fun switchingListIsNotShownForever() {
        val r = repo()
        r.onSnapshot(snapshot(1, 7, milk))
        r.selectList(8)
        now += WatchRepository.REQUEST_MILLIS + 1
        r.refresh() // any change recomputes the state
        assertFalse(r.state.value.switchingList)
    }
}
