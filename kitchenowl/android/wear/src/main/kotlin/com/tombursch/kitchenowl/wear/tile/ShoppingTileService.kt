package com.tombursch.kitchenowl.wear.tile

import android.content.Context
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.protolayout.TypeBuilders.StringProp
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import com.tombursch.kitchenowl.wear.R
import com.tombursch.kitchenowl.wear.ServiceLocator
import com.tombursch.kitchenowl.wear.data.WatchState
import com.tombursch.kitchenowl.wear.data.groupByCategory
import com.tombursch.kitchenowl.wear.ui.STALE_AFTER_MILLIS
import com.tombursch.kitchenowl.wear.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.guava.future

/** "N items left" + the first three, for the watch's tile carousel. Tap opens the app. */
class ShoppingTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        scope.future {
            // Reads the phone's last snapshot (plus what was ticked since); no network involved.
            buildTile(applicationContext, ServiceLocator.repository.state.value)
        }

    override fun onTileResourcesRequest(
        requestParams: RequestBuilders.ResourcesRequest,
    ): ListenableFuture<ResourceBuilders.Resources> =
        scope.future { ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build() }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val RESOURCES_VERSION = "1"
        private const val FRESHNESS_INTERVAL_MILLIS = 15 * 60_000L
        private const val MAX_ITEMS = 3

        private const val WHITE = 0xFFFFFFFF.toInt()
        private const val GREY = 0xFFB0B0B0.toInt()
        private const val GREEN = 0xFF20AC64.toInt()
        private const val RED = 0xFFFF8A80.toInt()

        internal fun buildTile(context: Context, state: WatchState): TileBuilders.Tile =
            TileBuilders.Tile.Builder()
                .setResourcesVersion(RESOURCES_VERSION)
                .setFreshnessIntervalMillis(FRESHNESS_INTERVAL_MILLIS)
                .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout(context, state)))
                .build()

        private fun layout(context: Context, state: WatchState): LayoutElementBuilders.LayoutElement {
            val column = LayoutElementBuilders.Column.Builder()
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_START)
                .setWidth(expand())

            if (state.snapshot == null) {
                column.addContent(text(context.getString(R.string.tile_no_snapshot), 16f, WHITE, bold = true, lines = 3))
            } else {
                val items = groupByCategory(state.items).flatMap { it.items }.map { it.item }
                column.addContent(
                    text(
                        if (items.isEmpty()) context.getString(R.string.tile_all_done)
                        else context.resources.getQuantityString(R.plurals.tile_items_left, items.size, items.size),
                        16f, GREEN, bold = true,
                    ),
                )
                items.take(MAX_ITEMS).forEach { column.addContent(text(it.name, 14f, WHITE)) }
                if (items.size > MAX_ITEMS) {
                    column.addContent(text("+${items.size - MAX_ITEMS}", 12f, GREY))
                }
                val age = System.currentTimeMillis() - state.updatedMs
                if (state.updatedMs > 0 && age >= STALE_AFTER_MILLIS) {
                    val hours = (age / (60 * 60 * 1000L)).toInt()
                    column.addContent(
                        text(
                            if (hours < 48) context.getString(R.string.updated_hours, hours)
                            else context.getString(R.string.updated_days, hours / 24),
                            11f, RED,
                        ),
                    )
                } else if (state.pendingCount > 0) {
                    column.addContent(text(context.getString(R.string.not_confirmed, state.pendingCount), 11f, GREY))
                }
            }

            val open = ModifiersBuilders.Clickable.Builder()
                .setId("open")
                .setOnClick(
                    ActionBuilders.LaunchAction.Builder()
                        .setAndroidActivity(
                            ActionBuilders.AndroidActivity.Builder()
                                .setPackageName(context.packageName)
                                .setClassName(MainActivity::class.java.name)
                                .build(),
                        )
                        .build(),
                )
                .build()

            return LayoutElementBuilders.Box.Builder()
                .setWidth(expand())
                .setHeight(expand())
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_START)
                .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
                .setModifiers(
                    ModifiersBuilders.Modifiers.Builder()
                        .setClickable(open)
                        // Room for the round screen's corners.
                        .setPadding(
                            ModifiersBuilders.Padding.Builder()
                                .setStart(dp(26f)).setEnd(dp(26f)).setTop(dp(18f)).setBottom(dp(18f))
                                .build(),
                        )
                        .build(),
                )
                .addContent(column.build())
                .build()
        }

        private fun text(value: String, sizeSp: Float, color: Int, bold: Boolean = false, lines: Int = 1) =
            LayoutElementBuilders.Text.Builder()
                .setText(StringProp.Builder(value).build())
                .setMaxLines(lines)
                .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE)
                .setFontStyle(
                    LayoutElementBuilders.FontStyle.Builder()
                        .setSize(sp(sizeSp))
                        .setColor(argb(color))
                        .setWeight(
                            if (bold) LayoutElementBuilders.FONT_WEIGHT_BOLD
                            else LayoutElementBuilders.FONT_WEIGHT_NORMAL,
                        )
                        .build(),
                )
                .build()
    }
}
