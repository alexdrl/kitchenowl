import 'dart:convert';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/services/api/api_service.dart';

extension PlannerApi on ApiService {
  static const baseRoute = '/planner';

  Future<List<RecipePlan>?> getPlanned(Household household) async {
    final res = await get('${householdPath(household)}$baseRoute');
    if (res.statusCode != 200) return null;

    final body = List.from(jsonDecode(res.body));

    return body.map((e) => RecipePlan.fromJson(e)).toList();
  }

  /// Adds a plan. With [moveFromMeal] it is a move instead: the plan on
  /// [moveFromDate] (null = no day) and [moveFromMeal] is removed in the same
  /// request, so the plan can't get lost halfway.
  Future<bool> addPlannedRecipe(
    Household household,
    RecipePlan recipePlan, {
    DateTime? moveFromDate,
    Meal? moveFromMeal,
  }) async {
    final res = await post(
      '${householdPath(household)}$baseRoute/recipe',
      jsonEncode({
        ...recipePlan.toJson(),
        if (moveFromMeal != null) ...{
          'move': true,
          'from_meal': moveFromMeal.name,
          if (moveFromDate != null)
            'from_cooking_date': moveFromDate.millisecondsSinceEpoch,
        },
      }),
    );

    return res.statusCode == 200;
  }

  Future<bool> removePlannedRecipe(
    Household household,
    Recipe recipe,
    DateTime? cookingDate, [
    Meal? meal,
  ]) async {
    final body = {};
    if (cookingDate != null)
      body['cooking_date'] = cookingDate.millisecondsSinceEpoch;
    // Without a meal the backend removes the recipe from every meal of the day
    if (meal != null) body['meal'] = meal.name;
    final res = await delete(
      '${householdPath(household)}$baseRoute/recipe/${recipe.id}',
      body: jsonEncode(body),
    );

    return res.statusCode == 200;
  }

  /// Notes on or after [from] (all of them when null)
  Future<List<PlannerNote>?> getPlannerNotes(
    Household household, {
    DateTime? from,
  }) async {
    final query = from != null ? '?from=${from.millisecondsSinceEpoch}' : '';
    final res = await get('${householdPath(household)}$baseRoute/notes$query');
    if (res.statusCode != 200) return null;

    return List.from(jsonDecode(res.body))
        .map((e) => PlannerNote.fromJson(e))
        .toList();
  }

  Future<List<String>?> getRecentPlannerNoteTexts(Household household) async {
    final res = await get('${householdPath(household)}$baseRoute/notes/recent');
    if (res.statusCode != 200) return null;

    return List<String>.from(jsonDecode(res.body));
  }

  Future<bool> addPlannerNote(Household household, PlannerNote note) async {
    final res = await post(
      '${householdPath(household)}$baseRoute/notes',
      jsonEncode(note.toJson()),
    );

    return res.statusCode == 200;
  }

  Future<bool> updatePlannerNote(Household household, PlannerNote note) async {
    final res = await post(
      '${householdPath(household)}$baseRoute/notes/${note.id}',
      jsonEncode(note.toJson()),
    );

    return res.statusCode == 200;
  }

  Future<bool> deletePlannerNote(Household household, PlannerNote note) async {
    final res = await delete(
      '${householdPath(household)}$baseRoute/notes/${note.id}',
    );

    return res.statusCode == 200;
  }

  Future<List<Recipe>?> getRecentPlannedRecipes(
    Household household,
    int? page,
  ) async {
    final res = await get(
        '${householdPath(household)}$baseRoute/recent-recipes' +
            (page == null ? '' : '/${page}'));
    if (res.statusCode != 200) return null;

    final body = List.from(jsonDecode(res.body));

    return body.map((e) => Recipe.fromJson(e)).toList();
  }

  Future<List<Recipe>?> getSuggestedRecipes(
    Household household,
    int? page,
  ) async {
    final res = await get(
        '${householdPath(household)}$baseRoute/suggested-recipes' +
            (page == null ? '' : '/${page}'));
    if (res.statusCode != 200) return null;

    final body = List.from(jsonDecode(res.body));

    return body.map((e) => Recipe.fromJson(e)).toList();
  }

  Future<List<Recipe>?> refreshSuggestedRecipes(Household household) async {
    final res = await get(
      '${householdPath(household)}$baseRoute/refresh-suggested-recipes',
    );
    if (res.statusCode != 200) return null;

    final body = List.from(jsonDecode(res.body));

    return body.map((e) => Recipe.fromJson(e)).toList();
  }
}
