package com.tombursch.kitchenowl

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.text.format.DateFormat
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale

/**
 * Home screen widget with today's planned menu.
 *
 * The app writes the next days as JSON (`lib/services/menu_widget.dart`); this
 * only picks today's entry, so the widget moves on at midnight by itself: an
 * alarm re-renders it right after the day changes.
 */
class MenuWidgetProvider : HomeWidgetProvider() {

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val data =
        widgetData.getString(DATA_KEY, null)?.let {
          try {
            JSONObject(it)
          } catch (_: Exception) {
            null
          }
        }
    for (id in appWidgetIds) {
      appWidgetManager.updateAppWidget(id, render(context, data))
    }
    scheduleMidnightUpdate(context)
  }

  override fun onDisabled(context: Context) {
    super.onDisabled(context)
    context.getSystemService(AlarmManager::class.java)?.cancel(midnightIntent(context))
  }

  private fun render(context: Context, data: JSONObject?): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.menu_widget)
    val now = Calendar.getInstance()
    views.setTextViewText(
        R.id.menu_widget_date,
        DateFormat.format(DateFormat.getBestDateTimePattern(Locale.getDefault(), "EEEEdMMMM"), now),
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

    val updated = data.optLong("updated", 0)
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
  }
}
