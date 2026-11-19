package com.tombursch.kitchenowl

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

/**
 * Home screen widget with the planned menu, laid out by its shape: today's meals
 * when small; today plus the next days when wide (beside it) or tall (below it);
 * the current week (Monday-Sunday, no breakfast) as a table when big both ways.
 *
 * The app writes this week and the next as JSON (`lib/services/menu_widget.dart`);
 * this picks today or the current week from it, so the widget moves on at
 * midnight by itself: an alarm re-renders it right after the day changes.
 */
class MenuWidgetProvider : HomeWidgetProvider() {

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val data = parse(widgetData)
    for (id in appWidgetIds) {
      appWidgetManager.updateAppWidget(id, viewsFor(context, appWidgetManager, id, data))
    }
    scheduleMidnightUpdate(context)
  }

  /** Called on every resize: the layout depends on the widget's shape (viewsFor). */
  override fun onAppWidgetOptionsChanged(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetId: Int,
      newOptions: Bundle,
  ) {
    super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
    val data = parse(HomeWidgetPlugin.getData(context))
    appWidgetManager.updateAppWidget(appWidgetId, viewsFor(context, appWidgetManager, appWidgetId, data))
  }

  override fun onDisabled(context: Context) {
    super.onDisabled(context)
    context.getSystemService(AlarmManager::class.java)?.cancel(midnightIntent(context))
  }

  private fun parse(widgetData: SharedPreferences): JSONObject? =
      widgetData.getString(DATA_KEY, null)?.let {
        try {
          JSONObject(it)
        } catch (_: Exception) {
          null
        }
      }

  /**
   * The layout follows the widget's shape, not just its size: clearly tall → today + next
   * days below; clearly wide → today + next 3 days beside it; big and roughly square → the
   * current week table; anything smaller → today only.
   *
   * Not Android 12's size-mapped RemoteViews: the system picks the mapped layout whose
   * minimum size is closest to the widget's, which put the week table on a 3x4 tablet
   * widget instead of the tall layout. The launcher calls onAppWidgetOptionsChanged on
   * every resize, so picking here works the same on every version.
   */
  private fun viewsFor(
      context: Context,
      manager: AppWidgetManager,
      id: Int,
      data: JSONObject?,
  ): RemoteViews {
    val options = manager.getAppWidgetOptions(id)
    // Portrait size: min width and max height (dp). 0 before the launcher reports it.
    val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).toFloat()
    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT).toFloat()
    return when {
      height >= width * TALL_RATIO && width >= TALL_MIN_WIDTH_DP && height >= tallHeightFor(width, 1) -> {
        val rows = (1..4).last { height >= tallHeightFor(width, it) }
        renderWithNext(context, data, R.layout.menu_widget_tall, rows, 4, "EEEEd")
      }
      width >= height * WIDE_RATIO && width >= WIDE_MIN_WIDTH_DP && height >= WIDE_MIN_HEIGHT_DP ->
          renderWithNext(context, data, R.layout.menu_widget_wide, 3, 3, "EEEd")
      width >= WEEK_MIN_WIDTH_DP && height >= WEEK_MIN_HEIGHT_DP -> renderWeek(context, data)
      else -> render(context, data, R.layout.menu_widget, "EEEEdMMMM")
    }
  }

  /**
   * Height (dp) the tall layout needs for [rows] next days. Measured on a Pixel 7 emulator
   * at 2 columns (~190dp wide): today's card with two-line meals is about 200dp, the rest
   * about 65dp, each next day about 68dp. From ~280dp wide the meals fit on one line and
   * the card is ~50dp shorter. Rows that would not fit whole are hidden, not cut in half.
   */
  private fun tallHeightFor(width: Float, rows: Int) = (if (width >= 280f) 215f else 265f) + 68f * rows

  /**
   * Today's card plus the next [count] days (lunch and dinner), for the wide and tall shapes;
   * the layout has [capacity] rows, the ones past [count] are hidden.
   */
  private fun renderWithNext(
      context: Context,
      data: JSONObject?,
      layout: Int,
      count: Int,
      capacity: Int,
      dayPattern: String,
  ): RemoteViews {
    val views = render(context, data, layout, "EEEEd")
    val days = data?.optJSONObject("days")
    if (days == null) {
      views.setViewVisibility(R.id.menu_widget_next, View.GONE)
      return views
    }
    for (i in 0 until capacity) {
      val visibility = if (i < count) View.VISIBLE else View.GONE
      views.setViewVisibility(NEXT_ROWS[i], visibility)
      views.setViewVisibility(NEXT_DIVIDERS[i], visibility)
    }
    val pattern = DateFormat.getBestDateTimePattern(Locale.getDefault(), dayPattern)
    val day = Calendar.getInstance()
    for (i in 0 until count) {
      day.add(Calendar.DAY_OF_YEAR, 1)
      val meals = days.optJSONObject(dayKey(day))
      views.setTextViewText(NEXT_DAYS[i], DateFormat.format(pattern, day))
      for ((meal, ids) in listOf("lunch" to NEXT_LUNCH, "dinner" to NEXT_DINNER)) {
        val entries = meals?.optJSONArray(meal)
        val names = (0 until (entries?.length() ?: 0)).map { entries!!.optString(it) }
        views.setTextViewText(ids[i], if (names.isEmpty()) "—" else names.joinToString(" · "))
      }
    }
    return views
  }

  /** The current week, Monday to Sunday, today highlighted: lunch, dinner and "other" when used. */
  private fun renderWeek(context: Context, data: JSONObject?): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.menu_widget_week)
    val householdId = data?.optJSONObject("household")?.optInt("id", -1) ?: -1
    views.setOnClickPendingIntent(R.id.menu_widget_root, openAppIntent(context, householdId))
    val days = data?.optJSONObject("days")
    val pattern = DateFormat.getBestDateTimePattern(Locale.getDefault(), "EEEd")
    val used = mutableSetOf("lunch", "dinner")
    val today = Calendar.getInstance()
    // Monday of the current week, whatever the locale's first day of the week
    val day =
        (today.clone() as Calendar).apply {
          add(Calendar.DAY_OF_YEAR, -((get(Calendar.DAY_OF_WEEK) - Calendar.MONDAY + 7) % 7))
        }
    val rangePattern = DateFormat.getBestDateTimePattern(Locale.getDefault(), "dMMM")
    val sunday = (day.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, 6) }
    views.setTextViewText(
        R.id.menu_widget_date,
        "${context.getString(R.string.menu_widget_week_title)} · " +
            "${DateFormat.format(rangePattern, day)} – ${DateFormat.format(rangePattern, sunday)}",
    )
    val todayKey = dayKey(today)
    var past = true
    for (i in 0 until 7) {
      val key = dayKey(day)
      val isToday = key == todayKey
      if (isToday) past = false
      views.setTextViewText(WEEK_DAYS[i], DateFormat.format(pattern, day))
      views.setInt(
          WEEK_ROWS[i], "setBackgroundResource", if (isToday) R.drawable.menu_widget_today else 0)
      // Days already gone are greyed out
      val color = if (past) R.color.menu_widget_text_secondary else R.color.menu_widget_text
      val meals = days?.optJSONObject(key)
      for ((meal, cells) in WEEK_CELLS) {
        val entries = meals?.optJSONArray(meal)
        val names = (0 until (entries?.length() ?: 0)).map { entries!!.optString(it) }
        if (names.isNotEmpty()) used += meal
        views.setTextViewText(cells[i], names.joinToString(" · "))
        setTextColor(context, views, cells[i], color)
      }
      setTextColor(context, views, WEEK_DAYS[i], color)
      day.add(Calendar.DAY_OF_YEAR, 1)
    }
    for ((meal, cells) in WEEK_CELLS) {
      val visibility = if (meal in used) View.VISIBLE else View.GONE
      views.setViewVisibility(WEEK_HEADS.getValue(meal), visibility)
      cells.forEach { views.setViewVisibility(it, visibility) }
    }
    setUpdated(context, views, data)
    return views
  }

  /** Android 12+ keeps the colour resource, so it follows a light/dark switch. */
  private fun setTextColor(context: Context, views: RemoteViews, id: Int, color: Int) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      views.setColorStateList(id, "setTextColor", color)
    } else {
      views.setTextColor(id, context.getColor(color))
    }
  }

  private fun setUpdated(context: Context, views: RemoteViews, data: JSONObject?) {
    val updated = data?.optLong("updated", 0) ?: 0
    if (updated > 0) {
      views.setTextViewText(
          R.id.menu_widget_updated,
          context.getString(
              R.string.menu_widget_updated,
              DateFormat.format(
                  DateFormat.getBestDateTimePattern(Locale.getDefault(), "dMMMHHmm"), updated),
          ),
      )
      views.setViewVisibility(R.id.menu_widget_updated, View.VISIBLE)
    } else {
      views.setViewVisibility(R.id.menu_widget_updated, View.GONE)
    }
  }

  /** Today's meals into [layout]: menu_widget.xml, or the today card of the wide and tall ones. */
  private fun render(context: Context, data: JSONObject?, layout: Int, datePattern: String): RemoteViews {
    val views = RemoteViews(context.packageName, layout)
    val now = Calendar.getInstance()
    views.setTextViewText(
        R.id.menu_widget_date,
        DateFormat.format(DateFormat.getBestDateTimePattern(Locale.getDefault(), datePattern), now),
    )

    val householdId = data?.optJSONObject("household")?.optInt("id", -1) ?: -1
    views.setOnClickPendingIntent(R.id.menu_widget_root, openAppIntent(context, householdId))

    if (data == null) {
      showMessage(views, context.getString(R.string.menu_widget_open_app))
      return views
    }

    val today = data.optJSONObject("days")?.optJSONObject(dayKey(now))
    var shown = 0
    for ((meal, row, label, text) in ROWS) {
      val entries = today?.optJSONArray(meal)
      val names = (0 until (entries?.length() ?: 0)).map { entries!!.optString(it) }
      // Lunch and dinner always show (a dash when empty); the others only
      // when something is planned for them.
      val alwaysShown = meal == "lunch" || meal == "dinner"
      if (names.isEmpty() && !alwaysShown) {
        views.setViewVisibility(row, View.GONE)
        continue
      }
      views.setViewVisibility(row, View.VISIBLE)
      views.setTextViewText(label, context.getString(MEAL_LABELS.getValue(meal)))
      views.setTextViewText(text, if (names.isEmpty()) "—" else names.joinToString(" · "))
      if (names.isNotEmpty()) shown++
    }
    if (today == null) {
      // The app hasn't written this far ahead: old data, open the app.
      showMessage(views, context.getString(R.string.menu_widget_open_app))
    } else if (shown == 0) {
      showMessage(views, context.getString(R.string.menu_widget_nothing_planned))
    } else {
      views.setViewVisibility(R.id.menu_widget_message, View.GONE)
    }
    setUpdated(context, views, data)
    return views
  }

  private fun showMessage(views: RemoteViews, message: String) {
    for ((_, row) in ROWS) views.setViewVisibility(row, View.GONE)
    views.setTextViewText(R.id.menu_widget_message, message)
    views.setViewVisibility(R.id.menu_widget_message, View.VISIBLE)
  }

  /** Opens the planner of the household the menu is from (Flutter deep link). */
  private fun openAppIntent(context: Context, householdId: Int): PendingIntent {
    val intent =
        Intent(context, MainActivity::class.java).apply {
          action = Intent.ACTION_VIEW
          if (householdId >= 0) data = Uri.parse("kitchenowl://widget/household/$householdId/planner")
          flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
    return PendingIntent.getActivity(
        context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
  }

  /** Inexact alarm a few seconds after midnight; needs no permission. */
  private fun scheduleMidnightUpdate(context: Context) {
    val next =
        Calendar.getInstance().apply {
          add(Calendar.DAY_OF_YEAR, 1)
          set(Calendar.HOUR_OF_DAY, 0)
          set(Calendar.MINUTE, 0)
          set(Calendar.SECOND, 5)
          set(Calendar.MILLISECOND, 0)
        }
    context
        .getSystemService(AlarmManager::class.java)
        ?.set(AlarmManager.RTC, next.timeInMillis, midnightIntent(context))
  }

  private fun midnightIntent(context: Context): PendingIntent {
    val manager = AppWidgetManager.getInstance(context)
    val ids = manager.getAppWidgetIds(ComponentName(context, MenuWidgetProvider::class.java))
    val intent =
        Intent(context, MenuWidgetProvider::class.java).apply {
          action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
          putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        }
    return PendingIntent.getBroadcast(
        context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
  }

  private data class Row(val meal: String, val row: Int, val label: Int, val text: Int)

  companion object {
    /** Same key and format as `MenuWidget.dataKey` / `MenuWidget.dayKey`. */
    private const val DATA_KEY = "menu"

    private fun dayKey(day: Calendar) =
        String.format(
            Locale.ROOT,
            "%04d-%02d-%02d",
            day.get(Calendar.YEAR),
            day.get(Calendar.MONTH) + 1,
            day.get(Calendar.DAY_OF_MONTH))

    private val ROWS =
        listOf(
            Row("breakfast", R.id.menu_widget_breakfast, R.id.menu_widget_breakfast_label, R.id.menu_widget_breakfast_text),
            Row("lunch", R.id.menu_widget_lunch, R.id.menu_widget_lunch_label, R.id.menu_widget_lunch_text),
            Row("dinner", R.id.menu_widget_dinner, R.id.menu_widget_dinner_label, R.id.menu_widget_dinner_text),
            Row("any", R.id.menu_widget_any, R.id.menu_widget_any_label, R.id.menu_widget_any_text),
        )

    private val MEAL_LABELS =
        mapOf(
            "breakfast" to R.string.menu_widget_breakfast,
            "lunch" to R.string.menu_widget_lunch,
            "dinner" to R.string.menu_widget_dinner,
            "any" to R.string.menu_widget_other,
        )

    // Shapes (viewsFor). Tall: height at least 1.2x the width (2x3 on the phone, 3x4 on
    // the tablet). Wide: width at least 1.4x the height (4-6x2 on the tablet). Big and
    // roughly square (4x4 on the phone): the week table.
    private const val TALL_RATIO = 1.2f
    private const val TALL_MIN_WIDTH_DP = 150f
    private const val WIDE_RATIO = 1.4f
    /** Below 400dp (3 tablet columns) both halves got cut to a few words each. */
    private const val WIDE_MIN_WIDTH_DP = 400f
    /** Room for its 3 next days, which are not hidden one by one. */
    private const val WIDE_MIN_HEIGHT_DP = 210f
    private const val WEEK_MIN_WIDTH_DP = 300f
    private const val WEEK_MIN_HEIGHT_DP = 340f

    private val NEXT_ROWS =
        intArrayOf(
            R.id.menu_widget_next0, R.id.menu_widget_next1,
            R.id.menu_widget_next2, R.id.menu_widget_next3)
    private val NEXT_DIVIDERS =
        intArrayOf(
            R.id.menu_widget_next0_divider, R.id.menu_widget_next1_divider,
            R.id.menu_widget_next2_divider, R.id.menu_widget_next3_divider)

    // Ids of the generated menu_widget_wide.xml / menu_widget_tall.xml (android/tools/
    // gen_menu_widget_cards.py): the wide one has rows 0-2, the tall one 0-3.
    private val NEXT_DAYS =
        intArrayOf(
            R.id.menu_widget_next0_day, R.id.menu_widget_next1_day,
            R.id.menu_widget_next2_day, R.id.menu_widget_next3_day)
    private val NEXT_LUNCH =
        intArrayOf(
            R.id.menu_widget_next0_lunch, R.id.menu_widget_next1_lunch,
            R.id.menu_widget_next2_lunch, R.id.menu_widget_next3_lunch)
    private val NEXT_DINNER =
        intArrayOf(
            R.id.menu_widget_next0_dinner, R.id.menu_widget_next1_dinner,
            R.id.menu_widget_next2_dinner, R.id.menu_widget_next3_dinner)

    // Ids of the generated menu_widget_week.xml (android/tools/gen_menu_widget_week.py),
    // Monday to Sunday: the row, its day label and one cell per meal. No breakfast column:
    // the week table is for the main meals.
    private val WEEK_ROWS =
        intArrayOf(
            R.id.menu_widget_week_row0, R.id.menu_widget_week_row1, R.id.menu_widget_week_row2,
            R.id.menu_widget_week_row3, R.id.menu_widget_week_row4, R.id.menu_widget_week_row5,
            R.id.menu_widget_week_row6)

    private val WEEK_DAYS =
        intArrayOf(
            R.id.menu_widget_week_day0, R.id.menu_widget_week_day1, R.id.menu_widget_week_day2,
            R.id.menu_widget_week_day3, R.id.menu_widget_week_day4, R.id.menu_widget_week_day5,
            R.id.menu_widget_week_day6)

    private val WEEK_CELLS =
        mapOf(
            "lunch" to
                intArrayOf(
                    R.id.menu_widget_week_lunch0, R.id.menu_widget_week_lunch1,
                    R.id.menu_widget_week_lunch2, R.id.menu_widget_week_lunch3,
                    R.id.menu_widget_week_lunch4, R.id.menu_widget_week_lunch5,
                    R.id.menu_widget_week_lunch6),
            "dinner" to
                intArrayOf(
                    R.id.menu_widget_week_dinner0, R.id.menu_widget_week_dinner1,
                    R.id.menu_widget_week_dinner2, R.id.menu_widget_week_dinner3,
                    R.id.menu_widget_week_dinner4, R.id.menu_widget_week_dinner5,
                    R.id.menu_widget_week_dinner6),
            "any" to
                intArrayOf(
                    R.id.menu_widget_week_any0, R.id.menu_widget_week_any1,
                    R.id.menu_widget_week_any2, R.id.menu_widget_week_any3,
                    R.id.menu_widget_week_any4, R.id.menu_widget_week_any5,
                    R.id.menu_widget_week_any6),
        )

    private val WEEK_HEADS =
        mapOf(
            "lunch" to R.id.menu_widget_week_head_lunch,
            "dinner" to R.id.menu_widget_week_head_dinner,
            "any" to R.id.menu_widget_week_head_any,
        )
  }
}
