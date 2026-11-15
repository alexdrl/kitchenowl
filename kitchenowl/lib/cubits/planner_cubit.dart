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

  /// Moves a plan to another day and/or meal, keeping its yields.
  Future<void> move(RecipePlan plan, DateTime? cookingDate, Meal meal) async {
    if (plan.cookingDate == cookingDate && plan.meal == meal) return;
    await TransactionHandler.getInstance()
        .runTransaction(TransactionPlannerRemoveRecipe(
      household: household,
      recipe: plan.recipe,
      cookingDate: plan.isWithoutPlannedDay ? null : plan.cookingDate,
      meal: plan.meal,
    ));
    await add(plan.recipe, cookingDate, meal, plan.yields);
  }

  /// Text meals (no recipe). Online only: offline they are simply hidden.
  Future<void> addNote(DateTime cookingDate, Meal meal, String text) async {
    await ApiService.getInstance().addPlannerNote(
      household,
      PlannerNote(cookingDate: cookingDate, meal: meal, text: text.trim()),
    );
    await refresh();
  }

  Future<void> updateNote(PlannerNote note) async {
    await ApiService.getInstance().updatePlannerNote(household, note);
    await refresh();
  }

  Future<void> removeNote(PlannerNote note) async {
    await ApiService.getInstance().deletePlannerNote(household, note);
    await refresh();
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
        .getPlannerNotes(household)
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
