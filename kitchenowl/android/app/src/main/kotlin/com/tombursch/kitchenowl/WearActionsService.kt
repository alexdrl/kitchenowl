package com.tombursch.kitchenowl

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService

/**
 * Wakes the phone when the watch writes an action (`/kitchenowl/actions/<uuid>`).
 * It does no work itself: [WearBridge] hands over to Dart, in the open app or in a headless
 * engine run by [WearActionsWorker]. Deletions (the phone's own acks) are ignored.
 */
class WearActionsService : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        val written = events.any {
            it.type == DataEvent.TYPE_CHANGED &&
                it.dataItem.uri.path?.startsWith(WearBridge.ACTIONS_PATH + "/") == true
        }
        if (written) WearBridge.onActionsWritten(applicationContext)
    }
}
