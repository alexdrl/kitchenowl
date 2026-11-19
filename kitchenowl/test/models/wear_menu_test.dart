import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/models/wear_menu.dart';

RecipePlan _plan(String name, DateTime? day, Meal meal) => RecipePlan(
      recipe: Recipe(name: name),
      cookingDate: day == null ? null : DateTime.utc(day.year, day.month, day.day),
      meal: meal,
    );

PlannerNote _note(String text, DateTime day, Meal meal) => PlannerNote(
      cookingDate: DateTime.utc(day.year, day.month, day.day),
      meal: meal,
      text: text,
    );

void main() {
  // Thursday 19 November 2026
  final now = DateTime(2026, 11, 19, 13, 41);
  final today = DateTime(2026, 11, 19);
  final tomorrow = DateTime(2026, 11, 20);

  Map<String, dynamic> build(List<RecipePlan> plans, List<PlannerNote> notes) =>
      WearMenu.build(householdId: 9, plans: plans, notes: notes, now: now);

  test('has the documented shape and 14 days from this week\'s Monday', () {
    final menu = build([_plan('Lentejas', today, Meal.lunch)], []);
    expect(menu['version'], 1);
    expect(menu['household_id'], 9);
    expect(menu['updated_ms'], now.millisecondsSinceEpoch);

    final days = menu['days'] as Map<String, dynamic>;
    expect(days.length, 14);
    expect(days.keys.first, '2026-11-16'); // Monday
    expect(days.keys.last, '2026-11-29'); // Sunday of next week
    expect(days['2026-11-19'], {
      'lunch': ['Lentejas'],
    });
    expect(days['2026-11-17'], isEmpty);
  });

  test('recipes come before text notes, and only planned meals are present', () {
    final menu = build(
      [
        _plan('Lentejas', today, Meal.lunch),
        _plan('Tortilla', today, Meal.dinner),
        _plan('Ensalada', today, Meal.lunch),
      ],
      [
        _note('  Comer fuera ', today, Meal.lunch),
        _note('   ', today, Meal.breakfast), // blank notes are ignored
      ],
    );
    final day = (menu['days'] as Map)['2026-11-19'] as Map;
    expect(day['lunch'], ['Lentejas', 'Ensalada', 'Comer fuera']);
    expect(day['dinner'], ['Tortilla']);
    expect(day.containsKey('breakfast'), isFalse);
  });

  test('plans without a day, and other days, stay out of today', () {
    final menu = build(
      [
        _plan('Sin día', null, Meal.lunch),
        _plan('Mañana', tomorrow, Meal.lunch),
      ],
      [],
    );
    final days = menu['days'] as Map;
    expect((days['2026-11-19'] as Map), isEmpty);
    expect((days['2026-11-20'] as Map)['lunch'], ['Mañana']);
  });

  test('the Sunday still belongs to the week that started on Monday', () {
    final sunday = DateTime(2026, 11, 22, 9);
    final menu = WearMenu.build(
        householdId: 1, plans: [], notes: [], now: sunday);
    expect((menu['days'] as Map).keys.first, '2026-11-16');
  });

  test('JSON round trip and the content key ignores the time', () {
    final a = build([_plan('Lentejas', today, Meal.lunch)], []);
    final b = WearMenu.build(
      householdId: 9,
      plans: [_plan('Lentejas', today, Meal.lunch)],
      notes: [],
      now: now.add(const Duration(minutes: 10)),
    );
    expect(jsonDecode(WearMenu.encode(a)), a);
    expect(WearMenu.contentKey(a), WearMenu.contentKey(b));

    final c = build([_plan('Paella', today, Meal.lunch)], []);
    expect(WearMenu.contentKey(a), isNot(WearMenu.contentKey(c)));
  });
}
