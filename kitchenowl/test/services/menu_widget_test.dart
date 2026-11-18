import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/services/menu_widget.dart';

const household = Household(id: 1, name: "Casa");
// Late evening: "today" must still be the local day, not tomorrow in UTC
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
        plan("Ayer", DateTime(2026, 11, 18), Meal.lunch),
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
    expect(days.keys, hasLength(MenuWidget.days));
    expect(days.keys.first, "2026-11-19");
    expect(days["2026-11-19"], {
      "lunch": ["Paella"],
      "dinner": ["Tortilla", "Sobras"],
    });
    expect(days["2026-11-20"], {
      "lunch": ["Lentejas"],
    });
    expect(days["2026-11-21"], isEmpty);
    expect(days.containsKey("2026-11-18"), isFalse);
    expect(data["household"], {"id": 1, "name": "Casa"});
    expect(data["updated"], now.millisecondsSinceEpoch);
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
