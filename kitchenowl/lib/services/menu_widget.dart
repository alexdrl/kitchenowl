import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/app_log.dart';

/// Feeds the Android home screen widget with the planned menu
/// (`MenuWidgetProvider.kt`).
///
/// Whenever the planner loads, the app writes [days] days starting on the
/// Monday of the current week: the small widget shows today, the big one the
/// current Monday-Sunday week. Covering next week too lets both move on at
/// midnight (and on Monday) without the app. The background fetch task also
/// downloads the plan again ([refreshInBackground]), so changes made on another
/// device show up without opening the app.
abstract class MenuWidget {
  /// Key of the JSON in the widget storage, read by the native side.
  static const dataKey = 'menu';
  static const androidProvider = 'com.tombursch.kitchenowl.MenuWidgetProvider';

  /// Asks for a sync of the phone calendar (`PhoneCalendar`), which reads the
  /// same data. Sent through home_widget because that also works headless.
  static const _calendarTrigger = 'com.tombursch.kitchenowl.CalendarSyncTrigger';

  /// Set by the native side while the phone calendar is on.
  static const _calendarFlag = 'calendar_sync';

  /// This week and the next one.
  static const days = 14;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> update(
    Household household,
    List<RecipePlan> plans,
    List<PlannerNote> notes,
  ) async {
    if (!supported) return;
    try {
      final data = buildData(
        household: household,
        plans: plans,
        notes: notes,
        now: DateTime.now(),
      );
      await HomeWidget.saveWidgetData<String>(dataKey, jsonEncode(data));
      await HomeWidget.updateWidget(qualifiedAndroidName: androidProvider);
      if (await _calendarOn()) {
        await HomeWidget.updateWidget(qualifiedAndroidName: _calendarTrigger);
      }
    } catch (e, st) {
      // The widget is a nicety: never let it break the planner.
      AppLog.warn('Menu widget update failed', error: e, stack: st);
    }
  }

  /// Downloads the plan of the household the widget shows and redraws it.
  /// Called by the background fetch task, with [ApiService] already connected.
  /// Does nothing when neither a menu widget nor the phone calendar is on, when the app has
  /// never written one (it doesn't know which household to show) or when a
  /// request fails: the widget then keeps what it had.
  static Future<void> refreshInBackground() async {
    if (!supported) return;
    try {
      final widgets = await HomeWidget.getInstalledWidgets();
      // androidClassName is the short name: ".MenuWidgetProvider"
      final shown = widgets.any(
        (w) => w.androidClassName?.endsWith('MenuWidgetProvider') ?? false,
      );
      if (!shown && !await _calendarOn()) return;

      final household = householdOf(
        await HomeWidget.getWidgetData<String>(dataKey),
      );
      if (household == null) return;

      final api = ApiService.getInstance();
      final (plans, notes) = await (
        api.getPlanned(household),
        api.getPlannerNotes(household, from: firstDay(DateTime.now())),
      ).wait;
      if (plans == null || notes == null) return;
      await update(household, plans, notes);
    } catch (e, st) {
      // Same as update(): the widget must never break the background task.
      AppLog.warn('Menu widget background refresh failed',
          error: e, stack: st);
    }
  }

  static Future<bool> _calendarOn() async =>
      await HomeWidget.getWidgetData<bool>(_calendarFlag) ?? false;

  /// The household of the widget JSON the app wrote last, or null.
  @visibleForTesting
  static Household? householdOf(String? json) {
    if (json == null) return null;
    try {
      final household = (jsonDecode(json) as Map)['household'] as Map;
      final id = household['id'];
      if (id is! int) return null;
      return Household(id: id, name: household['name'] as String? ?? '');
    } catch (e, st) {
      AppLog.warn('Unreadable menu widget data', error: e, stack: st);
      return null;
    }
  }

  /// The Monday of [now]'s week, as the UTC midnight plans and notes use.
  @visibleForTesting
  static DateTime firstDay(DateTime now) => DateTime.utc(
        now.year,
        now.month,
        now.day - (now.weekday - DateTime.monday),
      );

  /// The widget's JSON (version 1):
  /// `{"version", "household": {"id", "name"}, "updated": <ms>,
  ///   "days": {"2026-11-16": {"lunch": ["Paella", ...], ...}, ...}}`.
  /// Days are local calendar days from this week's Monday on; a meal is only
  /// present when something is planned for it. Recipes come before text notes, each in plan order.
  @visibleForTesting
  static Map<String, dynamic> buildData({
    required Household household,
    required List<RecipePlan> plans,
    required List<PlannerNote> notes,
    required DateTime now,
  }) {
    final result = <String, Map<String, List<String>>>{};
    // DateTime.weekday: Monday = 1
    final monday = now.day - (now.weekday - DateTime.monday);
    for (var i = 0; i < days; i++) {
      final day = DateTime(now.year, now.month, monday + i);
      final meals = <String, List<String>>{};
      for (final meal in Meal.values) {
        final entries = [
          for (final plan in plans)
            if (plan.meal == meal &&
                _sameDay(plan.cookingDate, day) &&
                !plan.isWithoutPlannedDay)
              plan.recipe.name,
          for (final note in notes)
            if (note.meal == meal &&
                _sameDay(note.cookingDate, day) &&
                note.text.trim().isNotEmpty)
              note.text.trim(),
        ];
        if (entries.isNotEmpty) meals[meal.name] = entries;
      }
      result[dayKey(day)] = meals;
    }
    return {
      'version': 1,
      'household': {'id': household.id, 'name': household.name},
      'updated': now.millisecondsSinceEpoch,
      'days': result,
    };
  }

  /// `yyyy-MM-dd`, the same key the native side builds for today.
  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  // Plans and notes are stored as UTC midnight of their calendar day.
  static bool _sameDay(DateTime? date, DateTime day) =>
      date != null &&
      date.year == day.year &&
      date.month == day.month &&
      date.day == day.day;
}
