package com.tombursch.kitchenowl.wear.sync

import android.content.Context
import android.net.Uri
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.tombursch.kitchenowl.wear.ServiceLocator
import com.tombursch.kitchenowl.wear.data.ACTIONS_PATH
import com.tombursch.kitchenowl.wear.data.MENU_PATH
import com.tombursch.kitchenowl.wear.data.parseMenu
import com.tombursch.kitchenowl.wear.data.ActionSink
import com.tombursch.kitchenowl.wear.data.SNAPSHOT_PATH
import com.tombursch.kitchenowl.wear.data.WatchAction
import com.tombursch.kitchenowl.wear.data.actionUuid
import com.tombursch.kitchenowl.wear.data.encodeAction
import com.tombursch.kitchenowl.wear.data.parseSnapshot
import com.tombursch.kitchenowl.wear.log.LOGS_REQUEST_PATH
import com.tombursch.kitchenowl.wear.log.LogRelay
import com.tombursch.kitchenowl.wear.log.WearLog
import com.tombursch.kitchenowl.wear.log.parseLogRequest

/**
 * Writes each action as its own Data Layer item, not as a message: it survives a lost
 * connection and reaches the phone when it is back. The phone deletes it once applied.
 */
class DataLayerActionSink(private val context: Context) : ActionSink {
    override fun send(uuid: String, action: WatchAction): Boolean = try {
        WearLog.d("Actions", "Sending action", mapOf("type" to action.type.name, "list_id" to action.listId))
        // New log lines ride along with the action, in the same sync.
        LogRelay.withAction(context)
        val request = PutDataRequest.create("$ACTIONS_PATH/$uuid")
            .setData(encodeAction(action))
            .setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
            .addOnFailureListener { e ->
                WearLog.w("Actions", "Action not handed to the Data Layer", e)
                ServiceLocator.repository.markUnsent(uuid)
            }
        true
    } catch (e: Exception) {
        // Play services missing or the like: kept and retried on the next start.
        WearLog.w("Actions", "Could not send an action", e)
        false
    }
}

/** Receives the phone's snapshots and learns which actions it has applied. */
class PhoneListenerService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            val path = event.dataItem.uri.path
            when {
                event.type == DataEvent.TYPE_CHANGED && path == SNAPSHOT_PATH ->
                    onSnapshotData(event.dataItem.data)
                event.type == DataEvent.TYPE_CHANGED && path == MENU_PATH ->
                    onMenuData(event.dataItem.data)
                event.type == DataEvent.TYPE_CHANGED && path?.startsWith("$LOGS_REQUEST_PATH/") == true ->
                    event.dataItem.data?.let(::parseLogRequest)?.let { request ->
                        // An old request found later (the watch was away): the phone gave up on it.
                        if (System.currentTimeMillis() - request.createdMs < REQUEST_MAX_AGE_MS) {
                            LogRelay.answer(applicationContext, request.requestId)
                        }
                    }
                // The phone deleted an action item: it has applied it.
                event.type == DataEvent.TYPE_DELETED -> actionUuid(path)?.let(ServiceLocator.repository::onActionDeleted)
            }
        }
    }

    companion object {
        private const val REQUEST_MAX_AGE_MS = 2 * 60 * 1000L

        private fun onSnapshotData(data: ByteArray?) {
            val snapshot = data?.let(::parseSnapshot)
            if (snapshot == null) {
                WearLog.w("Sync", "Unreadable list from the phone", fields = mapOf("bytes" to data?.size))
                return
            }
            WearLog.d(
                "Sync",
                "List received",
                mapOf("list_id" to snapshot.listId, "items" to snapshot.items.size, "updated_ms" to snapshot.updatedMs),
            )
            ServiceLocator.repository.onSnapshot(snapshot)
        }

        private fun onMenuData(data: ByteArray?) {
            val menu = data?.let(::parseMenu)
            if (menu == null) {
                WearLog.w("Sync", "Unreadable menu from the phone", fields = mapOf("bytes" to data?.size))
                return
            }
            WearLog.d("Sync", "Menu received", mapOf("days" to menu.days.size, "updated_ms" to menu.updatedMs))
            ServiceLocator.menuRepository.onMenu(menu)
        }

        /**
         * Reads what the Data Layer holds, for the moments nothing was listening: the latest
         * snapshot, and which of our actions are still waiting for the phone.
         */
        fun checkPending(context: Context) {
            val uri = Uri.Builder().scheme("wear").path("/kitchenowl").build()
            Wearable.getDataClient(context).getDataItems(uri, DataClient.FILTER_PREFIX)
                .addOnSuccessListener { items ->
                    val waiting = mutableSetOf<String>()
                    try {
                        for (item in items) {
                            val path = item.uri.path
                            if (path == SNAPSHOT_PATH) {
                                onSnapshotData(item.data)
                            } else if (path == MENU_PATH) {
                                onMenuData(item.data)
                            } else {
                                actionUuid(path)?.let(waiting::add)
                            }
                        }
                    } finally {
                        items.release()
                    }
                    ServiceLocator.repository.reconcile(waiting)
                    ServiceLocator.repository.resendUnsent()
                }
                .addOnFailureListener { e -> WearLog.w("Sync", "Could not read the Data Layer", e) }
        }
    }
}
