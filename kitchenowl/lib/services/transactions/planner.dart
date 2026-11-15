import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/storage/mem_storage.dart';
import 'package:kitchenowl/services/transaction.dart';

class TransactionPlannerGetPlannedRecipes
    extends Transaction<List<RecipePlan>> {
  final Household household;

  TransactionPlannerGetPlannedRecipes({
    DateTime? timestamp,
    required this.household,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerGetPlannedRecipes",
        );

  @override
  Future<List<RecipePlan>> runLocal() async {
    final recipes = List<Recipe>.from(
      await MemStorage.getInstance().readRecipes(household) ?? const [],
    );
    recipes.retainWhere((e) => e.isPlanned);

    return recipes
        .expand((r) => r.plannedSlots.isNotEmpty
            ? r.plannedSlots.map((slot) => RecipePlan(
                  recipe: r,
                  cookingDate: slot.$1,
                  meal: Meal.parse(slot.$2),
                ))
            : r.plannedCookingDates.isNotEmpty
                ? r.plannedCookingDates.map((cookingDate) =>
                    RecipePlan(recipe: r, cookingDate: cookingDate))
                : [RecipePlan(recipe: r)])
        .toList();
  }

  @override
  Future<List<RecipePlan>?> runOnline() async {
    return await ApiService.getInstance().getPlanned(household);
  }
}

class TransactionPlannerGetRecentPlannedRecipes
    extends Transaction<List<Recipe>> {
  final Household household;
  final int? page;

  TransactionPlannerGetRecentPlannedRecipes({
    DateTime? timestamp,
    required this.household,
    this.page,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerGetRecentPlannedRecipes",
        );

  @override
  Future<List<Recipe>> runLocal() async {
    return const [];
  }

  @override
  Future<List<Recipe>?> runOnline() async {
    return await ApiService.getInstance()
        .getRecentPlannedRecipes(household, page);
  }
}

class TransactionPlannerGetSuggestedRecipes extends Transaction<List<Recipe>> {
  final Household household;
  final int? page;

  TransactionPlannerGetSuggestedRecipes({
    DateTime? timestamp,
    required this.household,
    this.page,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerGetSuggestedRecipes",
        );

  @override
  Future<List<Recipe>> runLocal() async {
    return const [];
  }

  @override
  Future<List<Recipe>?> runOnline() async {
    return await ApiService.getInstance().getSuggestedRecipes(household, page);
  }
}

class TransactionPlannerAddRecipe extends Transaction<bool> {
  final Household household;
  final RecipePlan recipePlan;

  /// Set for a move: the slot the plan leaves (date null = no day)
  final DateTime? moveFromDate;
  final Meal? moveFromMeal;

  TransactionPlannerAddRecipe({
    required this.household,
    required this.recipePlan,
    this.moveFromDate,
    this.moveFromMeal,
    DateTime? timestamp,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerAddRecipe",
        );

  factory TransactionPlannerAddRecipe.fromJson(
    Map<String, dynamic> map,
    DateTime timestamp,
  ) =>
      TransactionPlannerAddRecipe(
        household: Household.fromJson(map['household']),
        recipePlan: RecipePlan.fromJson(map['recipePlan']),
        moveFromDate: map['moveFromDate'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                map['moveFromDate'],
                isUtc: true,
              )
            : null,
        moveFromMeal:
            map['moveFromMeal'] != null ? Meal.parse(map['moveFromMeal']) : null,
        timestamp: timestamp,
      );

  @override
  bool get saveTransaction => true;

  @override
  Map<String, dynamic> toJson() => super.toJson()
    ..addAll({
      "household": household.toJsonWithId(),
      "recipePlan": recipePlan.toJsonWithId(),
      if (moveFromDate != null)
        "moveFromDate": moveFromDate!.millisecondsSinceEpoch,
      if (moveFromMeal != null) "moveFromMeal": moveFromMeal!.name,
    });

  @override
  Future<bool> runLocal() async {
    return true;
  }

  @override
  Future<bool?> runOnline() {
    return ApiService.getInstance().addPlannedRecipe(
      household,
      recipePlan,
      moveFromDate: moveFromDate,
      moveFromMeal: moveFromMeal,
    );
  }
}

class TransactionPlannerRemoveRecipe extends Transaction<bool> {
  final Household household;
  final Recipe recipe;
  final DateTime? cookingDate;
  final Meal? meal;

  TransactionPlannerRemoveRecipe({
    required this.household,
    required this.recipe,
    this.cookingDate,
    this.meal,
    DateTime? timestamp,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerRemoveRecipe",
        );

  factory TransactionPlannerRemoveRecipe.fromJson(
    Map<String, dynamic> map,
    DateTime timestamp,
  ) =>
      TransactionPlannerRemoveRecipe(
        household: Household.fromJson(map['household']),
        recipe: Recipe.fromJson(map['recipe']),
        timestamp: timestamp,
        cookingDate: map['cooking_date'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                map['cooking_date'],
                isUtc: true,
              )
            : null,
        meal: map['meal'] != null ? Meal.parse(map['meal']) : null,
      );

  @override
  bool get saveTransaction => true;

  @override
  Map<String, dynamic> toJson() => super.toJson()
    ..addAll({
      "household": household.toJsonWithId(),
      "recipe": recipe.toJsonWithId(),
      "cooking_date": cookingDate?.millisecondsSinceEpoch,
      if (meal != null) "meal": meal!.name,
    });

  @override
  Future<bool> runLocal() async {
    return true;
  }

  @override
  Future<bool?> runOnline() {
    return ApiService.getInstance()
        .removePlannedRecipe(household, recipe, cookingDate, meal);
  }
}

class TransactionPlannerRefreshSuggestedRecipes
    extends Transaction<List<Recipe>> {
  final Household household;

  TransactionPlannerRefreshSuggestedRecipes({
    DateTime? timestamp,
    required this.household,
  }) : super.internal(
          timestamp ?? DateTime.now(),
          "TransactionPlannerRefreshSuggestedRecipes",
        );

  @override
  Future<List<Recipe>> runLocal() async {
    return const [];
  }

  @override
  Future<List<Recipe>?> runOnline() async {
    return await ApiService.getInstance().refreshSuggestedRecipes(household);
  }
}
