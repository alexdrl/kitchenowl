import 'dart:convert';

import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';

/// The planned menu the phone publishes for the Wear OS app at `/kitchenowl/menu`
/// (Wearable Data Layer, UTF-8 JSON). Same content as the home screen widget gets, so
/// the watch needs no network and no token.
///
/// ```json
/// {"version":1,"household_id":1,"updated_ms":1700000000000,
///  "days":{"2026-11-19":{"lunch":["Lentejas","Ensalada"],"dinner":["Tortilla"]}, ...}}
/// ```
///
/// [days] calendar days (local time) from this week's Monday on, so the watch can move on
/// at midnight and on Monday without the phone. A meal is only present when something is
/// planned for it; recipes come before text notes, each in plan order. Meal names are the
/// [Meal] names: `breakfast`, `lunch`, `dinner`, `any`.
abstract class WearMenu {
  static const int version = 1;

  /// This week and the next one.
  static const int days = 14;

  static Map<String, dynamic> build({
    required int householdId,
    required List<RecipePlan> plans,
    required List<PlannerNote> notes,
    required DateTime now,
  }) {
    final result = <String, Map<String, List<String>>>{};
    final monday = now.day - (now.weekday - DateTime.monday);
    for (var i = 0; i < days; i++) {
      final day = DateTime(now.year, now.month, monday + i);
      final meals = <String, List<String>>{};
      for (final meal in Meal.values) {
        final entries = [
          for (final plan in plans)
            if (plan.meal == meal &&
                !plan.isWithoutPlannedDay &&
                _sameDay(plan.cookingDate, day))
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
      'version': version,
      'household_id': householdId,
      'updated_ms': now.millisecondsSinceEpoch,
      'days': result,
    };
  }

  /// `yyyy-MM-dd`, the key the watch builds for today.
  static String dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static String encode(Map<String, dynamic> menu) => jsonEncode(menu);

  /// The menu apart from its time: used to skip identical republishes.
  static String contentKey(Map<String, dynamic> menu) =>
      jsonEncode(Map.of(menu)..remove('updated_ms'));

  // Plans and notes are stored as UTC midnight of their calendar day.
  static bool _sameDay(DateTime? date, DateTime day) =>
      date != null &&
      date.year == day.year &&
      date.month == day.month &&
      date.day == day.day;
}
