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

/**
 * Writes each action as its own Data Layer item, not as a message: it survives a lost
 * connection and reaches the phone when it is back. The phone deletes it once applied.
 */
class DataLayerActionSink(private val context: Context) : ActionSink {
    override fun send(uuid: String, action: WatchAction): Boolean = try {
        val request = PutDataRequest.create("$ACTIONS_PATH/$uuid")
            .setData(encodeAction(action))
            .setUrgent()
        Wearable.getDataClient(context).putDataItem(request)
            .addOnFailureListener { ServiceLocator.repository.markUnsent(uuid) }
        true
    } catch (e: Exception) {
        // Play services missing or the like: kept and retried on the next start.
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
                    event.dataItem.data?.let(::parseSnapshot)?.let(ServiceLocator.repository::onSnapshot)
                event.type == DataEvent.TYPE_CHANGED && path == MENU_PATH ->
                    event.dataItem.data?.let(::parseMenu)?.let(ServiceLocator.menuRepository::onMenu)
                // The phone deleted an action item: it has applied it.
                event.type == DataEvent.TYPE_DELETED -> actionUuid(path)?.let(ServiceLocator.repository::onActionDeleted)
            }
        }
    }

    companion object {
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
                                item.data?.let(::parseSnapshot)?.let(ServiceLocator.repository::onSnapshot)
                            } else if (path == MENU_PATH) {
                                item.data?.let(::parseMenu)?.let(ServiceLocator.menuRepository::onMenu)
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
        }
    }
}
