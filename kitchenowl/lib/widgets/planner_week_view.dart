import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kitchenowl/cubits/planner_cubit.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/recipe.dart';

/// Monday (local midnight) of the week `offset` weeks away from today.
DateTime plannerWeekStart(int offset, [DateTime? now]) {
  final today = now ?? DateTime.now();
  // Calendar arithmetic, not Durations: a DST change would shift the hour
  return DateTime(
    today.year,
    today.month,
    today.day - (today.weekday - 1) + 7 * offset,
  );
}

/// What can be dropped on a slot: an already planned recipe (moved) or a
/// recipe from the "no day" strip or the suggestions (added).
typedef PlannerDragData = Object;

/// Weekly calendar of the planner.
///
/// Wide layouts (tablet landscape, desktop) put the days in columns and the
/// meals in rows; narrow ones (phones) put the days in rows and the meals in
/// columns, so the three meals still fit side by side.
class PlannerWeekView extends StatelessWidget {
  final LoadedPlannerCubitState state;
  final DateTime weekStart;
  final bool showBreakfast;
  final void Function(RecipePlan plan) onPlanPressed;
  final void Function(DateTime cookingDate, Meal meal) onAddPressed;
  final void Function(PlannerDragData data, DateTime cookingDate, Meal meal)
      onDrop;

  const PlannerWeekView({
    super.key,
    required this.state,
    required this.weekStart,
    required this.showBreakfast,
    required this.onPlanPressed,
    required this.onAddPressed,
    required this.onDrop,
  });

  static const double wideBreakpoint = 720;

  List<DateTime> get days =>
      List.generate(
        7,
        (i) => DateTime(weekStart.year, weekStart.month, weekStart.day + i),
      );

  /// Plans shown in the "other" row: meal `any`, plus breakfast when hidden.
  Set<Meal> get _otherMeals => {Meal.any, if (!showBreakfast) Meal.breakfast};

  List<Meal> get meals {
    final hasOther = days.any((d) =>
        state.getPlannedOfDateAndMeals(_utc(d), _otherMeals).isNotEmpty);
    return [
      if (showBreakfast) Meal.breakfast,
      Meal.lunch,
      Meal.dinner,
      if (hasOther) Meal.any,
    ];
  }

  static DateTime _utc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

  List<RecipePlan> _plans(DateTime day, Meal meal) =>
      state.getPlannedOfDateAndMeals(
        _utc(day),
        meal == Meal.any ? _otherMeals : {meal},
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= wideBreakpoint
              ? _buildWide(context)
              : _buildNarrow(context),
    );
  }

  Widget _buildWide(BuildContext context) {
    final meals = this.meals;
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 96),
            for (final day in days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _DayHeader(day: day),
                ),
              ),
          ],
        ),
        for (final meal in meals)
          SizedBox(
            height: 176,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 96,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _MealLabel(meal: meal),
                  ),
                ),
                for (final day in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: _Slot(
                        day: day,
                        meal: meal,
                        plans: _plans(day, meal),
                        large: true,
                        onPlanPressed: onPlanPressed,
                        onAddPressed: onAddPressed,
                        onDrop: onDrop,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final meals = this.meals;
    return Column(
      children: [
        Row(
          children: [
            const SizedBox(width: 48),
            for (final meal in meals)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: _MealLabel(meal: meal, compact: true),
                ),
              ),
          ],
        ),
        for (final day in days)
          SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 48, child: _DayHeader(day: day)),
                for (final meal in meals)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: _Slot(
                        day: day,
                        meal: meal,
                        plans: _plans(day, meal),
                        large: false,
                        onPlanPressed: onPlanPressed,
                        onAddPressed: onAddPressed,
                        onDrop: onDrop,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

bool _isToday(DateTime day) {
  final now = DateTime.now();
  return day.year == now.year && day.month == now.month && day.day == now.day;
}

bool _isPast(DateTime day) {
  final now = DateTime.now();
  return day.isBefore(DateTime(now.year, now.month, now.day));
}

class _DayHeader extends StatelessWidget {
  final DateTime day;

  const _DayHeader({required this.day});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final today = _isToday(day);
    return Opacity(
      opacity: _isPast(day) ? .5 : 1,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            DateFormat('E').format(day).toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: today ? scheme.primary : scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 2),
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: today ? scheme.primary : null,
              shape: BoxShape.circle,
            ),
            child: Text(
              day.day.toString(),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: today ? scheme.onPrimary : scheme.onSurface,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MealLabel extends StatelessWidget {
  final Meal meal;
  final bool compact;

  const _MealLabel({required this.meal, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = meal.colors(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: compact ? Alignment.center : null,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!compact) ...[
            Icon(meal.icon, size: 14, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              meal.toLocalizedString(context),
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  final DateTime day;
  final Meal meal;
  final List<RecipePlan> plans;
  final bool large;
  final void Function(RecipePlan plan) onPlanPressed;
  final void Function(DateTime cookingDate, Meal meal) onAddPressed;
  final void Function(PlannerDragData data, DateTime cookingDate, Meal meal)
      onDrop;

  const _Slot({
    required this.day,
    required this.meal,
    required this.plans,
    required this.large,
    required this.onPlanPressed,
    required this.onAddPressed,
    required this.onDrop,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final utc = DateTime.utc(day.year, day.month, day.day);
    return DragTarget<PlannerDragData>(
      onWillAcceptWithDetails: (d) => d.data is RecipePlan || d.data is Recipe,
      onAcceptWithDetails: (d) => onDrop(d.data, utc, meal),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        Widget child;
        if (plans.isEmpty || hovering) {
          child = Material(
            color: hovering ? scheme.primaryContainer.withAlpha(120) : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: hovering ? scheme.primary : scheme.outlineVariant,
                width: hovering ? 2 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onAddPressed(utc, meal),
              child: Center(
                child: Icon(
                  Icons.add_rounded,
                  size: 20,
                  color: hovering ? scheme.primary : scheme.outline,
                  semanticLabel: AppLocalizations.of(context)!.add,
                ),
              ),
            ),
          );
        } else {
          child = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final plan in plans)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: plan == plans.last ? 0 : 4,
                    ),
                    child: _PlanCard(
                      plan: plan,
                      meal: meal == Meal.any ? plan.meal : meal,
                      large: large && plans.length == 1,
                      dense: plans.length > 1,
                      onPressed: () => onPlanPressed(plan),
                    ),
                  ),
                ),
            ],
          );
        }
        return Opacity(opacity: _isPast(day) ? .55 : 1, child: child);
      },
    );
  }
}

class _PlanCard extends StatelessWidget {
  final RecipePlan plan;
  final Meal meal;
  final bool large;
  final bool dense;
  final VoidCallback onPressed;

  const _PlanCard({
    required this.plan,
    required this.meal,
    required this.large,
    required this.dense,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = meal.colors(context);
    final yields = plan.yields ?? plan.recipe.yields;
    final card = Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (large)
              Expanded(
                child: plan.recipe.image != null &&
                        plan.recipe.image!.isNotEmpty
                    ? Image(
                        image: getImageProvider(
                          context,
                          plan.recipe.image!,
                          maxWidth: 256,
                        ),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Icon(Icons.restaurant_rounded, color: fg),
                      )
                    : Icon(Icons.restaurant_rounded, color: fg),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(8, dense ? 4 : 6, 8, 0),
              child: Text(
                plan.recipe.name,
                maxLines: dense ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: fg, height: 1.2),
              ),
            ),
            if (!large) const Spacer(),
            if (!dense && yields > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                child: Row(
                  children: [
                    Icon(Icons.people_alt_outlined, size: 12, color: fg),
                    const SizedBox(width: 4),
                    Text(
                      yields.toString(),
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: fg),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    return LongPressDraggable<PlannerDragData>(
      data: plan,
      feedback: _DragFeedback(name: plan.recipe.name, color: bg, textColor: fg),
      childWhenDragging: Opacity(opacity: .3, child: card),
      child: card,
    );
  }
}

class _DragFeedback extends StatelessWidget {
  final String name;
  final Color color;
  final Color textColor;

  const _DragFeedback({
    required this.name,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: color,
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: textColor),
          ),
        ),
      ),
    );
  }
}

/// A recipe chip that can be tapped or long-pressed and dragged onto a slot.
class PlannerDraggableRecipeChip extends StatelessWidget {
  final Recipe recipe;
  final String? subtitle;
  final VoidCallback onPressed;

  const PlannerDraggableRecipeChip({
    super.key,
    required this.recipe,
    this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chip = ActionChip(
      label: Text(
        subtitle == null ? recipe.name : '${recipe.name} · $subtitle',
      ),
      onPressed: onPressed,
    );
    return LongPressDraggable<PlannerDragData>(
      data: recipe,
      feedback: _DragFeedback(
        name: recipe.name,
        color: scheme.secondaryContainer,
        textColor: scheme.onSecondaryContainer,
      ),
      childWhenDragging: Opacity(opacity: .3, child: chip),
      child: chip,
    );
  }
}

/// Bottom sheet listing the household's recipes with a search field.
Future<Recipe?> showPlannerRecipePicker(
  BuildContext context,
  Future<List<Recipe>> recipes,
) {
  return showModalBottomSheet<Recipe>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .7,
      minChildSize: .4,
      builder: (context, controller) =>
          _RecipePicker(recipes: recipes, controller: controller),
    ),
  );
}

class _RecipePicker extends StatefulWidget {
  final Future<List<Recipe>> recipes;
  final ScrollController controller;

  const _RecipePicker({required this.recipes, required this.controller});

  @override
  State<_RecipePicker> createState() => _RecipePickerState();
}

class _RecipePickerState extends State<_RecipePicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: loc.plannerPickRecipe,
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Recipe>>(
            future: widget.recipes,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final recipes = snapshot.data!
                  .where((r) => r.name.toLowerCase().contains(query))
                  .toList();
              if (recipes.isEmpty) {
                return Center(child: Text(loc.recipeEmptySearch));
              }
              return ListView.builder(
                controller: widget.controller,
                itemCount: recipes.length,
                itemBuilder: (context, i) => ListTile(
                  leading: const Icon(Icons.restaurant_rounded),
                  title: Text(recipes[i].name),
                  onTap: () => Navigator.of(context).pop(recipes[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
