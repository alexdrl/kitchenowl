import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/services/menu_widget.dart';

const household = Household(id: 1, name: "Casa");
// Thursday, late evening: "today" must still be the local day, not tomorrow
// in UTC, and the week must start on Monday the 16th
final now = DateTime(2026, 11, 19, 23, 30);

RecipePlan plan(String name, DateTime day, Meal meal) => RecipePlan(
      recipe: Recipe(name: name),
      cookingDate: DateTime.utc(day.year, day.month, day.day),
      meal: meal,
    );

void main() {
  test("groups recipes and notes by local day and meal", () {
    final data = MenuWidget.buildData(
      household: household,
      plans: [
        plan("Paella", DateTime(2026, 11, 19), Meal.lunch),
        plan("Tortilla", DateTime(2026, 11, 19), Meal.dinner),
        plan("Lentejas", DateTime(2026, 11, 20), Meal.lunch),
        plan("Lunes", DateTime(2026, 11, 16), Meal.lunch),
        plan("Semana pasada", DateTime(2026, 11, 15), Meal.lunch),
        plan("Domingo siguiente", DateTime(2026, 11, 29), Meal.dinner),
        plan("Demasiado lejos", DateTime(2026, 11, 30), Meal.dinner),
      ],
      notes: [
        PlannerNote(
          cookingDate: DateTime.utc(2026, 11, 19),
          meal: Meal.dinner,
          text: " Sobras ",
        ),
      ],
      now: now,
    );

    final days = data["days"] as Map<String, Map<String, List<String>>>;
    expect(days.keys, hasLength(14));
    expect(days.keys.first, "2026-11-16");
    expect(days.keys.last, "2026-11-29");
    expect(days["2026-11-16"], {
      "lunch": ["Lunes"],
    });
    expect(days["2026-11-19"], {
      "lunch": ["Paella"],
      "dinner": ["Tortilla", "Sobras"],
    });
    expect(days["2026-11-20"], {
      "lunch": ["Lentejas"],
    });
    expect(days["2026-11-21"], isEmpty);
    expect(days["2026-11-29"], {
      "dinner": ["Domingo siguiente"],
    });
    expect(days.containsKey("2026-11-15"), isFalse);
    expect(days.containsKey("2026-11-30"), isFalse);
    expect(data["household"], {"id": 1, "name": "Casa"});
    expect(data["updated"], now.millisecondsSinceEpoch);
  });

  test("on Monday the week starts that same day", () {
    final data = MenuWidget.buildData(
      household: household,
      plans: const [],
      notes: const [],
      now: DateTime(2026, 11, 23, 0, 1),
    );

    expect((data["days"] as Map).keys.first, "2026-11-23");
  });

  test("week across a month end", () {
    final data = MenuWidget.buildData(
      household: household,
      plans: const [],
      notes: const [],
      now: DateTime(2026, 12, 2),
    );

    final keys = (data["days"] as Map).keys;
    expect(keys.first, "2026-11-30");
    expect(keys.elementAt(2), "2026-12-02");
  });

  test("leaves out plans without a day and empty notes", () {
    final data = MenuWidget.buildData(
      household: household,
      plans: [
        RecipePlan(recipe: const Recipe(name: "Someday"), meal: Meal.lunch),
      ],
      notes: [
        PlannerNote(
          cookingDate: DateTime.utc(2026, 11, 19),
          meal: Meal.lunch,
          text: "  ",
        ),
      ],
      now: now,
    );

    expect((data["days"] as Map)["2026-11-19"], isEmpty);
  });

  test("dayKey pads month and day", () {
    expect(MenuWidget.dayKey(DateTime(2027, 1, 5)), "2027-01-05");
  });
}
