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
import com.tombursch.kitchenowl.wear.data.DayMenu
import com.tombursch.kitchenowl.wear.data.MealKind
import com.tombursch.kitchenowl.wear.data.PhoneMenu
import com.tombursch.kitchenowl.wear.data.day
import com.tombursch.kitchenowl.wear.ui.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.guava.future
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.TextStyle
import java.util.Locale

/**
 * The menu tile: lunch and dinner of today, and of tomorrow. Reads the phone's last menu (no network);
 * tap opens the week in the app. Today's lunch is greyed out once it is past 16:00.
 */
class MenuTileService : TileService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> =
        scope.future { buildTile(applicationContext, ServiceLocator.menuRepository.state.value, LocalDateTime.now()) }

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

        /** The tile is redrawn at least this often, so it moves on at 16:00 and at midnight. */
        private const val FRESHNESS_INTERVAL_MILLIS = 15 * 60_000L

        private const val WHITE = 0xFFFFFFFF.toInt()
        private const val DIM = 0xFF8A8A94.toInt()
        private const val GREY = 0xFFB0B0B0.toInt()
        private const val GREEN = 0xFF6FD08C.toInt()
        private const val BLUE = 0xFF9DB8FF.toInt()

        internal fun buildTile(context: Context, menu: PhoneMenu?, now: LocalDateTime): TileBuilders.Tile =
            TileBuilders.Tile.Builder()
                .setResourcesVersion(RESOURCES_VERSION)
                .setFreshnessIntervalMillis(FRESHNESS_INTERVAL_MILLIS)
                .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout(context, menu, now)))
                .build()

        private fun layout(context: Context, menu: PhoneMenu?, now: LocalDateTime): LayoutElementBuilders.LayoutElement {
            val today = now.toLocalDate()
            val todayMenu = menu?.day(today)
            val column = LayoutElementBuilders.Column.Builder()
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_START)
                .setWidth(expand())

            when {
                menu == null -> column.addContent(text(context.getString(R.string.menu_empty_title), 16f, WHITE, bold = true, lines = 3))
                todayMenu == null -> column.addContent(text(context.getString(R.string.menu_no_today), 16f, WHITE, bold = true, lines = 2))
                else -> {
                    val lunchPast = now.hour >= 16
                    column.addContent(header(context, today, today, GREEN))
                    column.addContent(mealLine(context, todayMenu, MealKind.LUNCH, 15f, GREEN, dim = lunchPast))
                    column.addContent(mealLine(context, todayMenu, MealKind.DINNER, 15f, BLUE, dim = false))
                    column.addContent(spacer(8f))
                    val tomorrow = menu.day(today.plusDays(1))
                    column.addContent(header(context, today.plusDays(1), today, GREY))
                    if (tomorrow != null) {
                        column.addContent(mealLine(context, tomorrow, MealKind.LUNCH, 13f, GREEN, dim = false))
                        column.addContent(mealLine(context, tomorrow, MealKind.DINNER, 13f, BLUE, dim = false))
                    }
                }
            }

            val open = ModifiersBuilders.Clickable.Builder()
                .setId("open-menu")
                .setOnClick(
                    ActionBuilders.LaunchAction.Builder()
                        .setAndroidActivity(
                            ActionBuilders.AndroidActivity.Builder()
                                .setPackageName(context.packageName)
                                .setClassName(MainActivity::class.java.name)
                                // The app opens on its menu screen (MainActivity reads this).
                                .addKeyToExtraMapping(MainActivity.EXTRA_SCREEN, ActionBuilders.stringExtra(MainActivity.SCREEN_MENU))
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
                                .setStart(dp(26f)).setEnd(dp(22f)).setTop(dp(18f)).setBottom(dp(18f))
                                .build(),
                        )
                        .build(),
                )
                .addContent(column.build())
                .build()
        }

        /** "HOY · JUE 19" / "MAÑANA · VIE 20". */
        private fun header(context: Context, date: LocalDate, today: LocalDate, color: Int): LayoutElementBuilders.LayoutElement {
            val relative = if (date == today) context.getString(R.string.day_today) else context.getString(R.string.day_tomorrow)
            val weekday = date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())
            return text("${relative.uppercase()} · ${weekday.uppercase()} ${date.dayOfMonth}", 12f, color, bold = true)
        }

        /** "COMIDA  Lentejas, Ensalada" on one line: the label small and coloured, the dishes after it. */
        private fun mealLine(
            context: Context,
            day: DayMenu,
            meal: MealKind,
            sizeSp: Float,
            labelColor: Int,
            dim: Boolean,
        ): LayoutElementBuilders.LayoutElement {
            val label = context.getString(if (meal == MealKind.LUNCH) R.string.meal_lunch else R.string.meal_dinner).uppercase()
            val dishes = day.dishes(meal).joinToString(", ").ifEmpty { "–" }
            val color = if (dim) DIM else WHITE
            return LayoutElementBuilders.Spannable.Builder()
                .setMaxLines(1)
                .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE)
                .addSpan(span("$label  ", sizeSp - 4f, if (dim) DIM else labelColor, bold = true))
                .addSpan(span(dishes, sizeSp, color, bold = !dim && day.dishes(meal).isNotEmpty()))
                .build()
        }

        private fun span(value: String, sizeSp: Float, color: Int, bold: Boolean) =
            LayoutElementBuilders.SpanText.Builder()
                .setText(value)
                .setFontStyle(fontStyle(sizeSp, color, bold))
                .build()

        private fun fontStyle(sizeSp: Float, color: Int, bold: Boolean) =
            LayoutElementBuilders.FontStyle.Builder()
                .setSize(sp(sizeSp))
                .setColor(argb(color))
                .setWeight(if (bold) LayoutElementBuilders.FONT_WEIGHT_BOLD else LayoutElementBuilders.FONT_WEIGHT_NORMAL)
                .build()

        private fun spacer(heightDp: Float) =
            LayoutElementBuilders.Spacer.Builder().setHeight(dp(heightDp)).build()

        private fun text(value: String, sizeSp: Float, color: Int, bold: Boolean = false, lines: Int = 1) =
            LayoutElementBuilders.Text.Builder()
                .setText(StringProp.Builder(value).build())
                .setMaxLines(lines)
                .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE)
                .setFontStyle(fontStyle(sizeSp, color, bold))
                .build()
    }
}
