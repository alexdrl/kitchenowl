import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kitchenowl/app.dart';
import 'package:kitchenowl/cubits/household_cubit.dart';
import 'package:kitchenowl/cubits/planner_cubit.dart';
import 'package:kitchenowl/cubits/settings_cubit.dart';
import 'package:kitchenowl/cubits/shoppinglist_cubit.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/enums/update_enum.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/models/shoppinglist.dart';
import 'package:kitchenowl/pages/item_selection_page.dart';
import 'package:kitchenowl/pages/recipe_list_display_page.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/planner.dart';
import 'package:kitchenowl/services/transactions/recipe.dart';
import 'package:kitchenowl/widgets/planner_add_sheet.dart';
import 'package:kitchenowl/widgets/planner_calendar_sheet.dart';
import 'package:kitchenowl/widgets/planner_week_view.dart';
import 'package:kitchenowl/widgets/sliver_recipe_carousel.dart';
import 'package:tuple/tuple.dart';

enum _PlannerMenu { breakfast, calendar }

String formatDateAsWeekday(
  BuildContext context,
  DateTime date, {
  String default_format = 'EEEE',
}) {
  DateTime today = DateTime.now();
  DateTime tomorrow = today.add(Duration(days: 1));
  DateTime yesterday = today.subtract(Duration(days: 1));

  // Check if the date is today or tomorrow
  if (date.year == today.year &&
      date.month == today.month &&
      date.day == today.day) {
    return AppLocalizations.of(context)!.today;
  } else if (date.year == tomorrow.year &&
      date.month == tomorrow.month &&
      date.day == tomorrow.day) {
    return AppLocalizations.of(context)!.tomorrow;
  } else if (date.year == yesterday.year &&
      date.month == yesterday.month &&
      date.day == yesterday.day) {
    return AppLocalizations.of(context)!.yesterday;
  } else {
    // Return the weekday name
    return DateFormat(default_format).format(date);
  }
}

DateTime _toDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

String _formatDate(BuildContext context, int daysToAdd) {
  DateTime date = DateTime.now().add(Duration(days: daysToAdd));
  if (daysToAdd >= -1 && daysToAdd < 7) {
    return formatDateAsWeekday(context, date, default_format: 'E');
  } else {
    return DateFormat.yMMMd().format(date);
  }
}

int daysBetween(DateTime from, DateTime to) {
  // otherwise it's rounded
  from = DateTime(from.year, from.month, from.day);
  to = DateTime(to.year, to.month, to.day);
  return (to.difference(from).inHours / 24).round();
}

class PlannerPage extends StatefulWidget {
  const PlannerPage({super.key});

  @override
  _PlannerPageState createState() => _PlannerPageState();
}

class _PlannerPageState extends State<PlannerPage> {
  final TextEditingController searchController = TextEditingController();
  final ScrollController suggestedRecipesScrollController = ScrollController();
  bool weekView = true;
  int weekOffset = 0;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = BlocProvider.of<PlannerCubit>(context);
    final household = BlocProvider.of<HouseholdCubit>(context).state.household;
    final showBreakfast = context.select<HouseholdCubit, bool>(
      (c) => c.state.household.plannerBreakfast ?? true,
    );

    return SafeArea(
      child: Scrollbar(
        child: RefreshIndicator(
          onRefresh: cubit.refresh,
          child: BlocBuilder<PlannerCubit, PlannerCubitState>(
            bloc: cubit,
            builder: (context, state) {
              if (state is! LoadedPlannerCubitState) {
                return CustomScrollView(
                  primary: true,
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      sliver: SliverToBoxAdapter(
                        child: Container(
                          height: 80,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            AppLocalizations.of(context)!.plannerTitle,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                      ),
                    ),
                    const SliverItemGridList(
                      isLoading: true,
                    ),
                  ],
                );
              }

              return CustomScrollView(
                primary: true,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(
                      child: Container(
                        height: 80,
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context)!.plannerTitle,
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                              ),
                            ),
                            IconButton(
                              tooltip: weekView
                                  ? AppLocalizations.of(context)!
                                      .plannerListView
                                  : AppLocalizations.of(context)!
                                      .plannerWeekView,
                              onPressed: () =>
                                  setState(() => weekView = !weekView),
                              icon: Icon(
                                weekView
                                    ? Icons.view_agenda_outlined
                                    : Icons.calendar_view_week_rounded,
                              ),
                            ),
                            PopupMenuButton<_PlannerMenu>(
                              onSelected: (value) async {
                                switch (value) {
                                  case _PlannerMenu.breakfast:
                                    _reportFailure(
                                      await context
                                          .read<HouseholdCubit>()
                                          .setPlannerBreakfast(!showBreakfast),
                                    );
                                  case _PlannerMenu.calendar:
                                    await showPlannerCalendarSheet(
                                      context,
                                      household,
                                    );
                                }
                              },
                              itemBuilder: (context) => [
                                if (weekView)
                                  CheckedPopupMenuItem(
                                    value: _PlannerMenu.breakfast,
                                    checked: showBreakfast,
                                    child: Text(
                                      AppLocalizations.of(context)!
                                          .plannerShowBreakfast,
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: _PlannerMenu.calendar,
                                  child: Text(
                                    AppLocalizations.of(context)!
                                        .plannerCalendar,
                                  ),
                                ),
                              ],
                            ),
                            if (state.recipePlans.isNotEmpty &&
                                household.defaultShoppingList != null)
                              IconButton(
                                tooltip: AppLocalizations.of(context)!.itemsAdd,
                                onPressed: () =>
                                    _openItemSelectionPage(context, cubit),
                                icon: const Icon(
                                  Icons.add_shopping_cart_rounded,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (weekView)
                    ..._buildWeekSlivers(context, cubit, state, showBreakfast),
                  if (!weekView && state.recipePlans.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Icon(Icons.no_food_rounded),
                            const SizedBox(height: 16),
                            Text(
                              AppLocalizations.of(context)!.plannerEmpty,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!weekView)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) => SliverToBoxAdapter(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.end,
                          alignment: WrapAlignment.start,
                          children: [
                            for (final plan in state.getPlannedWithoutDay())
                              KitchenOwlFractionallySizedBox(
                                widthFactor: (1 /
                                    DynamicStyling.itemCrossAxisCount(
                                      constraints.crossAxisExtent,
                                      context
                                          .read<SettingsCubit>()
                                          .state
                                          .gridSize,
                                    )),
                                child: AspectRatio(
                                  aspectRatio: 1,
                                  child: SelectableButtonCard(
                                    key: ValueKey(plan.recipe.id),
                                    title: plan.recipe.name,
                                    selected: true,
                                    description: plan.yields?.toString(),
                                    onLongPressedIcon: const Icon(
                                      Icons.done_rounded,
                                    ),
                                    onLongPressed: () {
                                      cubit.remove(plan.recipe);
                                    },
                                    onPressed: () => _openRecipePage(
                                      context,
                                      cubit,
                                      plan.recipe,
                                      plan.yields,
                                    ),
                                  ),
                                ),
                              ),
                            for (final cookingDate
                                in state.getUniqueCookingDays())
                              for (final plan
                                  in state.getPlannedOfDate(cookingDate))
                                KitchenOwlFractionallySizedBox(
                                  widthFactor: (1 /
                                      DynamicStyling.itemCrossAxisCount(
                                        constraints.crossAxisExtent,
                                        context
                                            .read<SettingsCubit>()
                                            .state
                                            .gridSize,
                                      )),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (plan ==
                                          state
                                              .getPlannedOfDate(cookingDate)[0])
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 5),
                                          child: Text(
                                            '${_formatDate(context, daysBetween(DateTime.now(), cookingDate))}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyLarge,
                                          ),
                                        ),
                                      AspectRatio(
                                        aspectRatio: 1,
                                        child: SelectableButtonCard(
                                          key: ValueKey(
                                            plan.recipe.id,
                                          ),
                                          title: plan.recipe.name,
                                          description: plan.yields?.toString(),
                                          selected: plan.cookingDate == null ||
                                              !_toDate(plan.cookingDate!)
                                                  .isBefore(
                                                      _toDate(DateTime.now())),
                                          onLongPressedIcon: const Icon(
                                            Icons.done_rounded,
                                          ),
                                          onLongPressed: () {
                                            cubit.remove(
                                              plan.recipe,
                                              plan.cookingDate,
                                              plan.meal,
                                            );
                                          },
                                          onPressed: () => _openRecipePage(
                                            context,
                                            cubit,
                                            plan.recipe,
                                            plan.yields,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (state.recentRecipes.isNotEmpty)
                    SliverRecipeCarousel(
                      recipes: state.recentRecipes,
                      title: "${AppLocalizations.of(context)!.recipesRecent}:",
                      onLongPressed: (r) => cubit.add(r),
                      onAddToDate: (r) =>
                          _addRecipeToSpecificDay(context, cubit, r),
                      onPressed: (r) => _openRecipePage(
                        context,
                        cubit,
                        r,
                      ),
                      showMore: () =>
                          Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(
                          builder: (context) => RecipeListDisplayPage(
                            title: AppLocalizations.of(context)!.recipesRecent,
                            household: cubit.household,
                            recipes: state.recentRecipes,
                            moreRecipes: (page) =>
                                TransactionHandler.getInstance().runTransaction(
                              TransactionPlannerGetRecentPlannedRecipes(
                                household: cubit.household,
                                page: page,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (state.suggestedRecipes.isNotEmpty)
                    SliverRecipeCarousel(
                      //padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      recipes: state.suggestedRecipes,
                      scrollController: suggestedRecipesScrollController,
                      title:
                          "${AppLocalizations.of(context)!.recipesSuggested}:",
                      actions: [
                        LoadingIconButton(
                          onPressed: () async {
                            await cubit.refreshSuggestions();
                            suggestedRecipesScrollController.animateTo(
                              0,
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeIn,
                            );
                          },
                          icon: const Icon(Icons.shuffle_rounded),
                          tooltip: AppLocalizations.of(context)!.refresh,
                        ),
                      ],
                      onLongPressed: (r) => cubit.add(r),
                      onAddToDate: (r) => _addRecipeToSpecificDay(
                        context,
                        cubit,
                        r,
                      ),
                      onPressed: (r) => _openRecipePage(
                        context,
                        cubit,
                        r,
                      ),
                      showMore: () =>
                          Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(
                          builder: (context) => RecipeListDisplayPage(
                            title:
                                AppLocalizations.of(context)!.recipesSuggested,
                            household: cubit.household,
                            recipes: state.suggestedRecipes,
                            actions: (oCubit, controller) => [
                              LoadingIconButton(
                                onPressed: () async {
                                  await cubit.refreshSuggestions();
                                  await oCubit.refresh();
                                  controller.animateTo(
                                    0,
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeIn,
                                  );
                                },
                                icon: const Icon(Icons.shuffle_rounded),
                                tooltip: AppLocalizations.of(context)!.refresh,
                              ),
                            ],
                            moreRecipes: (page) =>
                                TransactionHandler.getInstance().runTransaction(
                              TransactionPlannerGetSuggestedRecipes(
                                household: cubit.household,
                                page: page,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!App.isOffline)
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverToBoxAdapter(
                        child: ElevatedButton.icon(
                          onPressed: () => context.push(
                            "/household/${cubit.household.id}/recipes/discover",
                            extra: cubit.household,
                          ),
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: Text(
                              AppLocalizations.of(context)!.recipesDiscover),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openRecipePage(
    BuildContext context,
    PlannerCubit cubit,
    Recipe recipe, [
    int? yields,
  ]) async {
    final household = BlocProvider.of<HouseholdCubit>(context).state.household;
    final res = await context.push<UpdateEnum>(
      Uri(
        path: "/household/${household.id}/recipes/details/${recipe.id}",
        queryParameters: {
          "updateOnPlanningEdit": true.toString(),
          if (yields != null) "selectedYields": yields.toString(),
        },
      ).toString(),
      extra: Tuple2<Household, Recipe>(household, recipe),
    );
    if (res == UpdateEnum.updated || res == UpdateEnum.deleted) {
      cubit.refresh();
    }
  }

  Future<void> _openItemSelectionPage(
    BuildContext context,
    PlannerCubit cubit,
  ) async {
    await Navigator.of(context, rootNavigator: true)
        .push<(ShoppingList?, List<RecipeItem>)>(
      MaterialPageRoute(
        builder: (ctx) => ItemSelectionPage(
          selectText: AppLocalizations.of(ctx)!.addNumberIngredients,
          plans: (cubit.state as LoadedPlannerCubitState).recipePlans,
          title: AppLocalizations.of(ctx)!.addItemTitle,
          shoppingLists: BlocProvider.of<ShoppinglistCubit>(context)
              .state
              .shoppinglists
              .values
              .toList(),
          handleResult: (list, res) async {
            list ??= BlocProvider.of<HouseholdCubit>(context)
                .state
                .household
                .defaultShoppingList;
            if (res.isNotEmpty && list != null) {
              await cubit.addItemsToList(
                list,
                res,
              );
            }

            return (list, res);
          },
        ),
      ),
    );
  }

  Future<void> _addRecipeToSpecificDay(
    BuildContext context,
    PlannerCubit cubit,
    Recipe recipe,
  ) async {
    final slot = await showPlannerAddSheet(
      context,
      recipeName: recipe.name,
      showBreakfast:
          context.read<HouseholdCubit>().state.household.plannerBreakfast ??
              true,
    );
    if (slot != null) {
      await cubit.add(recipe, slot.cookingDate, slot.meal);
    }
  }

  List<Widget> _buildWeekSlivers(
    BuildContext context,
    PlannerCubit cubit,
    LoadedPlannerCubitState state,
    bool showBreakfast,
  ) {
    final loc = AppLocalizations.of(context)!;
    final weekStart = plannerWeekStart(weekOffset);
    final weekEnd = DateTime(
      weekStart.year,
      weekStart.month,
      weekStart.day + 6,
    );
    final unplanned = state.getPlannedWithoutDay();
    final locale = Localizations.localeOf(context).toString();

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              IconButton(
                tooltip: loc.plannerPreviousWeek,
                onPressed: () {
                  setState(() => weekOffset--);
                  cubit.loadNotesFrom(plannerWeekStart(weekOffset));
                },
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${DateFormat.MMMd(locale).format(weekStart)} – '
                      '${DateFormat.MMMd(locale).format(weekEnd)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (weekOffset == 0)
                      Text(
                        loc.plannerThisWeek,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (weekOffset != 0)
                TextButton(
                  onPressed: () => setState(() => weekOffset = 0),
                  child: Text(loc.today),
                ),
              IconButton(
                tooltip: loc.plannerNextWeek,
                onPressed: () => setState(() => weekOffset++),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
      ),
      if (unplanned.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  loc.plannerNoDay,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                for (final plan in unplanned)
                  PlannerDraggableRecipeChip(
                    recipe: plan.recipe,
                    subtitle: plan.yields?.toString(),
                    onPressed: () => _onPlanPressed(context, cubit, plan),
                  ),
              ],
            ),
          ),
        ),
      SliverLayoutBuilder(
        builder: (context, constraints) => SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          sliver: SliverToBoxAdapter(
            child: PlannerWeekView(
              // Fit the grid in what is left of the screen: minus the slivers
              // above, this padding and the one-line drag hint below
              maxHeight: (constraints.viewportMainAxisExtent -
                      constraints.precedingScrollExtent -
                      16 -
                      MediaQuery.textScalerOf(context).scale(20))
                  .clamp(0.0, double.infinity),
              state: state,
              weekStart: weekStart,
              showBreakfast: showBreakfast,
              onPlanPressed: (plan) => _onPlanPressed(context, cubit, plan),
              onNotePressed: (note) => _onNotePressed(context, cubit, note),
              onAddPressed: (cookingDate, meal) async {
                final choice = await showPlannerSlotSheet(
                  context,
                  title: _slotTitle(context, cookingDate, meal),
                  recipes: TransactionHandler.getInstance().runTransaction(
                    TransactionRecipeGetRecipes(household: cubit.household),
                  ),
                  recentTexts: cubit.recentNoteTexts(),
                );
                if (choice?.recipe != null) {
                  await cubit.add(choice!.recipe!, cookingDate, meal);
                } else if (choice?.text != null) {
                  final ok =
                      await cubit.addNote(cookingDate, meal, choice!.text!);
                  _reportFailure(ok);
                }
              },
              onDrop: (data, cookingDate, meal) {
                if (data is RecipePlan) {
                  cubit.move(data, cookingDate, meal);
                } else if (data is PlannerNote) {
                  cubit
                      .updateNote(
                        data.copyWith(cookingDate: cookingDate, meal: meal),
                      )
                      .then((ok) {
                    _reportFailure(ok);
                  });
                } else if (data is Recipe) {
                  // Planning an unplanned recipe replaces its "no day" entry
                  cubit.add(data, cookingDate, meal);
                }
              },
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverToBoxAdapter(
          child: Text(
            loc.plannerDragHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    ];
  }

  String _slotTitle(BuildContext context, DateTime cookingDate, Meal meal) {
    final day = DateTime(cookingDate.year, cookingDate.month, cookingDate.day);
    return '${DateFormat('EEEE d', Localizations.localeOf(context).toString()).format(day)} · '
        '${meal.toLocalizedString(context)}';
  }

  Future<void> _onNotePressed(
    BuildContext context,
    PlannerCubit cubit,
    PlannerNote note,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.storefront_rounded),
              title: Text(
                note.text,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(loc.edit),
              onTap: () => Navigator.of(context).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.event_rounded),
              title: Text(loc.plannerMove),
              onTap: () => Navigator.of(context).pop('move'),
            ),
            ListTile(
              leading: const Icon(Icons.done_rounded),
              title: Text(loc.remove),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'edit':
        final choice = await showPlannerSlotSheet(
          context,
          title: _slotTitle(context, note.cookingDate, note.meal),
          recipes: Future.value(const []),
          recentTexts: cubit.recentNoteTexts(),
          initialText: note.text,
          textOnly: true,
        );
        if (choice?.text != null) {
          final ok = await cubit.updateNote(note.copyWith(text: choice!.text));
          _reportFailure(ok);
        }
      case 'move':
        final slot = await showPlannerAddSheet(
          context,
          recipeName: note.text,
          showBreakfast:
              context.read<HouseholdCubit>().state.household.plannerBreakfast ??
                  true,
          initialDate: note.cookingDate,
          initialMeal: note.meal,
          allowNoDay: false,
        );
        if (slot != null) {
          final ok = await cubit.updateNote(note.copyWith(
            cookingDate: slot.cookingDate ?? note.cookingDate,
            meal: slot.meal,
          ));
          _reportFailure(ok);
        }
      case 'remove':
        final ok = await cubit.removeNote(note);
        _reportFailure(ok);
    }
  }

  /// Text meals and the breakfast setting aren't queued offline: say so
  /// when the server didn't take a change instead of losing it silently.
  void _reportFailure(bool ok) {
    // The page's own context: callers may hold one from a closed sheet
    if (ok || !mounted) return;
    showSnackbar(
      context: context,
      width: null,
      duration: const Duration(seconds: 4),
      content: Text(AppLocalizations.of(context)!.plannerSaveFailed),
    );
  }

  Future<void> _onPlanPressed(
    BuildContext context,
    PlannerCubit cubit,
    RecipePlan plan,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                plan.recipe.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.restaurant_menu_rounded),
              title: Text(loc.plannerOpenRecipe),
              onTap: () => Navigator.of(context).pop('open'),
            ),
            ListTile(
              leading: const Icon(Icons.event_rounded),
              title: Text(loc.plannerMove),
              onTap: () => Navigator.of(context).pop('move'),
            ),
            ListTile(
              leading: const Icon(Icons.done_rounded),
              title: Text(loc.remove),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'open':
        await _openRecipePage(context, cubit, plan.recipe, plan.yields);
      case 'move':
        final slot = await showPlannerAddSheet(
          context,
          recipeName: plan.recipe.name,
          showBreakfast:
              context.read<HouseholdCubit>().state.household.plannerBreakfast ??
                  true,
          initialDate: plan.isWithoutPlannedDay ? null : plan.cookingDate,
          initialMeal: plan.meal,
        );
        if (slot != null) await cubit.move(plan, slot.cookingDate, slot.meal);
      case 'remove':
        await cubit.remove(
          plan.recipe,
          plan.isWithoutPlannedDay ? null : plan.cookingDate,
          plan.meal,
        );
    }
  }
}
