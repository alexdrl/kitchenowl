package com.tombursch.kitchenowl.wear

import android.app.Application
import android.content.Context
import androidx.wear.tiles.TileService
import com.tombursch.kitchenowl.wear.data.PrefsStore
import com.tombursch.kitchenowl.wear.data.WatchRepository
import com.tombursch.kitchenowl.wear.sync.DataLayerActionSink
import com.tombursch.kitchenowl.wear.tile.ShoppingTileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

class WearApp : Application() {
    override fun onCreate() {
        super.onCreate()
        ServiceLocator.init(this)
    }
}

/** Process-wide singletons: the activity, the tile and the Data Layer service share them. */
object ServiceLocator {
    lateinit var repository: WatchRepository
        private set

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @OptIn(FlowPreview::class)
    fun init(application: Application) {
        repository = WatchRepository(DataLayerActionSink(application), PrefsStore(application))

        // Keep the tile current after every change (a tick, a new snapshot).
        appScope.launch {
            repository.state
                .map { s -> Triple(s.items.map { it.item.id to it.item.name }, s.pendingCount, s.snapshot?.listId) }
                .distinctUntilChanged()
                .debounce(500)
                .collect { requestTileUpdate(application) }
        }
    }

    fun requestTileUpdate(context: Context) {
        try {
            TileService.getUpdater(context).requestUpdate(ShoppingTileService::class.java)
        } catch (e: Exception) {
            // The tile is optional; never let it break anything else.
        }
    }
}
