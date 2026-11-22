import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/models/shoppinglist.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/planner.dart';
import 'package:kitchenowl/services/transactions/shoppinglist.dart';

class PlannerCubit extends Cubit<PlannerCubitState> {
  final Household household;
  bool _refreshLock = false;

  /// Oldest day whose text notes are loaded. Starts a few weeks back and
  /// grows when the user browses older weeks, so old notes aren't
  /// downloaded on every refresh.
  DateTime _notesFrom = () {
    final now = DateTime.now();
    return DateTime.utc(now.year, now.month, now.day - 7 * 8);
  }();

  /// Makes sure notes from [day] on are loaded (called when browsing back).
  Future<void> loadNotesFrom(DateTime day) async {
    final utc = DateTime.utc(day.year, day.month, day.day);
    if (!utc.isBefore(_notesFrom)) return;
    _notesFrom = utc;
    await refresh();
  }

  PlannerCubit(this.household) : super(const LoadingPlannerCubitState()) {
    refresh();
  }

  Future<void> remove(
    Recipe recipe, [
    DateTime? cookingDate,
    Meal? meal,
  ]) async {
    await TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerRemoveRecipe(
      household: household,
      recipe: recipe,
      cookingDate: cookingDate,
      meal: meal,
    ));
    await refresh();
  }

  Future<void> add(
    Recipe recipe, [
    DateTime? cookingDate,
    Meal meal = Meal.any,
    int? yields,
  ]) async {
    await TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerAddRecipe(
      household: household,
      recipePlan: RecipePlan(
        recipe: recipe,
        cookingDate: cookingDate,
        meal: meal,
        yields: yields,
      ),
    ));
    await refresh();
  }

  /// Makes a recipe with only [name] and plans it for [cookingDate] and
  /// [meal]. Returns the new recipe, or null when the server did not make it
  /// (for example when offline). Making a recipe is online only.
  Future<Recipe?> createAndAdd(
    String name,
    DateTime cookingDate,
    Meal meal,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final recipe = await ApiService.getInstance().addRecipe(
      household,
      Recipe(name: trimmed.length > 128 ? trimmed.substring(0, 128) : trimmed),
    );
    if (recipe == null) return null;
    await add(recipe, cookingDate, meal);
    return recipe;
  }

  /// Moves a plan to another day and/or meal, keeping its yields.
  Future<void> move(RecipePlan plan, DateTime? cookingDate, Meal meal) async {
    if (plan.cookingDate == cookingDate && plan.meal == meal) return;
    // One request: the server removes the old slot and adds the new one
    // together, without logging it as dropped and re-added in the history
    await TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerAddRecipe(
      household: household,
      recipePlan: RecipePlan(
        recipe: plan.recipe,
        cookingDate: cookingDate,
        meal: meal,
        yields: plan.yields,
      ),
      moveFromDate: plan.isWithoutPlannedDay ? null : plan.cookingDate,
      moveFromMeal: plan.meal,
    ));
    await refresh();
  }

  /// Text meals (no recipe) are online only: these return false when the
  /// server didn't take the change, so the page can tell the user.
  Future<bool> addNote(DateTime cookingDate, Meal meal, String text) =>
      _noteRequest(() => ApiService.getInstance().addPlannerNote(
            household,
            PlannerNote(cookingDate: cookingDate, meal: meal, text: text.trim()),
          ));

  Future<bool> updateNote(PlannerNote note) => _noteRequest(
      () => ApiService.getInstance().updatePlannerNote(household, note));

  Future<bool> removeNote(PlannerNote note) => _noteRequest(
      () => ApiService.getInstance().deletePlannerNote(household, note));

  Future<bool> _noteRequest(Future<bool> Function() request) async {
    bool ok;
    try {
      ok = await request();
    } catch (_) {
      ok = false;
    }
    // Report the result right away; the reload can be slow when offline
    refresh().ignore();
    return ok;
  }

  Future<List<String>> recentNoteTexts() async =>
      await ApiService.getInstance().getRecentPlannerNoteTexts(household) ??
      const [];

  Future<void> refresh() async {
    if (_refreshLock) return;
    _refreshLock = true;
    final planned = TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerGetPlannedRecipes(
      household: household,
    ));
    final recent = TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerGetRecentPlannedRecipes(
      household: household,
    ));
    final suggested = TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerGetSuggestedRecipes(
      household: household,
    ));

    final notes = ApiService.getInstance()
        .getPlannerNotes(household, from: _notesFrom)
        .catchError((_) => null);

    emit(LoadedPlannerCubitState(
      await planned,
      await recent,
      await suggested,
      await notes ?? const [],
    ));
    _refreshLock = false;
  }

  Future<void> refreshSuggestions() async {
    if (state is LoadedPlannerCubitState) {
      final suggested = await TransactionHandler.getInstance()
          .runTransaction(TransactionPlannerRefreshSuggestedRecipes(
        household: household,
      ));
      emit((state as LoadedPlannerCubitState)
          .copyWith(suggestedRecipes: suggested));
    }
  }

  Future<void> addItemsToList(
    ShoppingList shoppingList,
    List<RecipeItem> items,
  ) {
    return TransactionHandler.getInstance()
        .runTransaction(TransactionShoppingListAddRecipeItems(
      household: household,
      shoppinglist: shoppingList,
      items: items,
    ));
  }
}

abstract class PlannerCubitState extends Equatable {
  const PlannerCubitState();
}

class LoadingPlannerCubitState extends PlannerCubitState {
  const LoadingPlannerCubitState();

  @override
  List<Object?> get props => [];
}

class LoadedPlannerCubitState extends PlannerCubitState {
  final List<RecipePlan> recipePlans;
  final List<Recipe> recentRecipes;
  final List<Recipe> suggestedRecipes;
  final List<PlannerNote> notes;

  const LoadedPlannerCubitState([
    this.recipePlans = const [],
    this.recentRecipes = const [],
    this.suggestedRecipes = const [],
    this.notes = const [],
  ]);

  @override
  List<Object?> get props =>
      recipePlans.cast<Object?>() + recentRecipes + suggestedRecipes + notes;

  LoadedPlannerCubitState copyWith({
    List<RecipePlan>? recipePlans,
    Map<int, List<Recipe>>? plannedRecipeDayMap,
    List<Recipe>? recentRecipes,
    List<Recipe>? suggestedRecipes,
  }) =>
      LoadedPlannerCubitState(
        recipePlans ?? this.recipePlans,
        recentRecipes ?? this.recentRecipes,
        suggestedRecipes ?? this.suggestedRecipes,
        notes,
      );

  List<RecipePlan> getPlannedWithoutDay() {
    return recipePlans
        .where((element) =>
            element.cookingDate == null ||
            (element.cookingDate != null &&
                element.cookingDate!.millisecondsSinceEpoch < 0))
        .toList();
  }

  List<RecipePlan> getPlannedOfDate(DateTime cookingDate) {
    return recipePlans
        .where((element) =>
            element.cookingDate?.year == cookingDate.year &&
            element.cookingDate?.month == cookingDate.month &&
            element.cookingDate?.day == cookingDate.day)
        .toList();
  }

  /// Plans of one day and meal; `meals` lets the caller fold several meals
  /// into one row (e.g. breakfast into "other" when breakfast is hidden).
  List<RecipePlan> getPlannedOfDateAndMeals(
    DateTime cookingDate,
    Set<Meal> meals,
  ) {
    return getPlannedOfDate(cookingDate)
        .where((element) => meals.contains(element.meal))
        .toList();
  }

  List<PlannerNote> getNotesOfDateAndMeals(
    DateTime cookingDate,
    Set<Meal> meals,
  ) {
    return notes
        .where((n) =>
            n.cookingDate.year == cookingDate.year &&
            n.cookingDate.month == cookingDate.month &&
            n.cookingDate.day == cookingDate.day &&
            meals.contains(n.meal))
        .toList();
  }

  List<DateTime> getUniqueCookingDays() {
    Set<DateTime> uniqueDays = {};

    for (var recipe in recipePlans) {
      if (recipe.cookingDate != null &&
          recipe.cookingDate!.millisecondsSinceEpoch > 0) {
        uniqueDays.add(recipe.cookingDate!);
      }
    }
    return uniqueDays.toList()..sort();
  }
}
