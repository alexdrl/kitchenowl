import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';

/// Feeds the Android home screen widget with the planned menu
/// (`MenuWidgetProvider.kt`).
///
/// The app writes the next [days] days whenever the planner loads; the widget
/// only reads that JSON and picks today's entry itself, so it moves on at
/// midnight without the app. Anything else that refreshes the plan (e.g. a
/// background job) just has to call [MenuWidget.update] too.
abstract class MenuWidget {
  /// Key of the JSON in the widget storage, read by the native side.
  static const dataKey = 'menu';
  static const androidProvider = 'com.tombursch.kitchenowl.MenuWidgetProvider';
  static const days = 7;

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
    } catch (_) {
      // The widget is a nicety: never let it break the planner.
    }
  }

  /// The widget's JSON (version 1):
  /// `{"version", "household": {"id", "name"}, "updated": <ms>,
  ///   "days": {"2026-11-19": {"lunch": ["Paella", ...], ...}}}`.
  /// Days are local calendar days; a meal is only present when something is
  /// planned for it. Recipes come before text notes, each in plan order.
  @visibleForTesting
  static Map<String, dynamic> buildData({
    required Household household,
    required List<RecipePlan> plans,
    required List<PlannerNote> notes,
    required DateTime now,
  }) {
    final result = <String, Map<String, List<String>>>{};
    for (var i = 0; i < days; i++) {
      final day = DateTime(now.year, now.month, now.day + i);
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
