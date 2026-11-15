import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kitchenowl/cubits/planner_cubit.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
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

/// What can be dropped on a slot: an already planned recipe or a text note
/// (moved) or a recipe from the "no day" strip or the suggestions (added).
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
  final void Function(PlannerNote note) onNotePressed;
  final void Function(DateTime cookingDate, Meal meal) onAddPressed;
  final void Function(PlannerDragData data, DateTime cookingDate, Meal meal)
      onDrop;

  const PlannerWeekView({
    super.key,
    required this.state,
    required this.weekStart,
    required this.showBreakfast,
    required this.onPlanPressed,
    required this.onNotePressed,
    required this.onAddPressed,
    required this.onDrop,
    this.maxHeight,
  });

  /// Height left on screen for the wide grid (header included). Rows shrink
  /// to fit it, down to a minimum; null keeps the full row height.
  final double? maxHeight;

  static const double wideBreakpoint = 720;
  static const double _headerHeight = 58;
  static const double _maxRow = 176;
  static const double _minRow = 104;
  static const double _emptyRow = 64;

  bool _isEmptyRow(Meal meal) =>
      days.every((d) => _plans(d, meal).isEmpty && _notes(d, meal).isEmpty);

  /// Row heights for the wide grid. When the rows don't fit at full height,
  /// rows with nothing planned this week (often breakfast) get compact and
  /// leave their space to the rest.
  List<double> _rowHeights(List<Meal> meals) {
    if (maxHeight == null) return [for (final _ in meals) _maxRow];
    final available = maxHeight! - _headerHeight;
    if (available >= _maxRow * meals.length) {
      return [for (final _ in meals) _maxRow];
    }
    final empty = [for (final m in meals) _isEmptyRow(m)];
    final emptyCount = empty.where((e) => e).length;
    if (emptyCount == 0 || emptyCount == meals.length) {
      final min = emptyCount == 0 ? _minRow : _emptyRow;
      final h = (available / meals.length).clamp(min, _maxRow);
      return [for (final _ in meals) h];
    }
    final full = ((available - emptyCount * _emptyRow) /
            (meals.length - emptyCount))
        .clamp(_minRow, _maxRow);
    return [for (final e in empty) e ? _emptyRow : full];
  }

  List<DateTime> get days =>
      List.generate(
        7,
        (i) => DateTime(weekStart.year, weekStart.month, weekStart.day + i),
      );

  /// Plans shown in the "other" row: meal `any`, plus breakfast when hidden.
  Set<Meal> get _otherMeals => {Meal.any, if (!showBreakfast) Meal.breakfast};

  List<Meal> get meals {
    final hasOther = days.any((d) =>
        state.getPlannedOfDateAndMeals(_utc(d), _otherMeals).isNotEmpty ||
        state.getNotesOfDateAndMeals(_utc(d), _otherMeals).isNotEmpty);
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

  List<PlannerNote> _notes(DateTime day, Meal meal) =>
      state.getNotesOfDateAndMeals(
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
    final heights = _rowHeights(meals);
    return Column(
      children: [
        SizedBox(
          height: _headerHeight,
          child: Row(
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
        ),
        for (final (i, meal) in meals.indexed)
          SizedBox(
            height: heights[i],
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
                        notes: _notes(day, meal),
                        large: true,
                        onPlanPressed: onPlanPressed,
                        onNotePressed: onNotePressed,
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
                        notes: _notes(day, meal),
                        large: false,
                        onPlanPressed: onPlanPressed,
                        onNotePressed: onNotePressed,
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
            DateFormat('E', Localizations.localeOf(context).toString()).format(day).toUpperCase(),
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
  final List<PlannerNote> notes;
  final bool large;
  final void Function(RecipePlan plan) onPlanPressed;
  final void Function(PlannerNote note) onNotePressed;
  final void Function(DateTime cookingDate, Meal meal) onAddPressed;
  final void Function(PlannerDragData data, DateTime cookingDate, Meal meal)
      onDrop;

  const _Slot({
    required this.day,
    required this.meal,
    required this.plans,
    required this.notes,
    required this.large,
    required this.onPlanPressed,
    required this.onNotePressed,
    required this.onAddPressed,
    required this.onDrop,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final utc = DateTime.utc(day.year, day.month, day.day);
    return DragTarget<PlannerDragData>(
      onWillAcceptWithDetails: (d) =>
          d.data is RecipePlan || d.data is Recipe || d.data is PlannerNote,
      onAcceptWithDetails: (d) => onDrop(d.data, utc, meal),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        Widget child;
        final count = plans.length + notes.length;
        if (count == 0 || hovering) {
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
                      bottom: plan == plans.last && notes.isEmpty ? 0 : 4,
                    ),
                    child: _PlanCard(
                      plan: plan,
                      meal: meal == Meal.any ? plan.meal : meal,
                      large: large && count == 1,
                      dense: count > 1,
                      onPressed: () => onPlanPressed(plan),
                    ),
                  ),
                ),
              for (final note in notes)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: note == notes.last ? 0 : 4,
                    ),
                    child: _NoteCard(
                      note: note,
                      meal: meal == Meal.any ? note.meal : meal,
                      large: large && count == 1,
                      dense: count > 1,
                      onPressed: () => onNotePressed(note),
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

class _NoteCard extends StatelessWidget {
  final PlannerNote note;
  final Meal meal;
  final bool large;
  final bool dense;
  final VoidCallback onPressed;

  const _NoteCard({
    required this.note,
    required this.meal,
    required this.large,
    required this.dense,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = meal.colors(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Text(
      note.text,
      maxLines: dense ? 1 : (large ? 4 : 2),
      overflow: TextOverflow.ellipsis,
      textAlign: large ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: fg,
            fontStyle: FontStyle.italic,
            height: 1.2,
          ),
    );
    final card = Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: bg, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: dense ? 2 : 6),
          child: dense
              ? Row(
                  children: [
                    Icon(Icons.storefront_rounded, size: 12, color: fg),
                    const SizedBox(width: 4),
                    Expanded(child: text),
                  ],
                )
              : Column(
                  mainAxisAlignment: large
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: large
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.storefront_rounded,
                        size: large ? 24 : 16, color: fg),
                    if (large) const SizedBox(height: 8),
                    Flexible(child: text),
                  ],
                ),
        ),
      ),
    );
    return LongPressDraggable<PlannerDragData>(
      data: note,
      feedback: _DragFeedback(name: note.text, color: bg, textColor: fg),
      childWhenDragging: Opacity(opacity: .3, child: card),
      child: card,
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

/// What the user chose for an empty slot: a recipe, or a free text.
typedef PlannerSlotChoice = ({Recipe? recipe, String? text});

/// Bottom sheet for an empty slot: pick a recipe (searchable) or write a
/// text meal such as "Dinner at X".
Future<PlannerSlotChoice?> showPlannerSlotSheet(
  BuildContext context, {
  required String title,
  required Future<List<Recipe>> recipes,
  required Future<List<String>> recentTexts,
  String? initialText,
  bool textOnly = false,
}) {
  return showModalBottomSheet<PlannerSlotChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .75,
      minChildSize: .4,
      builder: (context, controller) => _SlotSheet(
        title: title,
        recipes: recipes,
        recentTexts: recentTexts,
        controller: controller,
        initialText: initialText,
        textOnly: textOnly,
      ),
    ),
  );
}

class _SlotSheet extends StatefulWidget {
  final String title;
  final Future<List<Recipe>> recipes;
  final Future<List<String>> recentTexts;
  final ScrollController controller;
  final String? initialText;
  final bool textOnly;

  const _SlotSheet({
    required this.title,
    required this.recipes,
    required this.recentTexts,
    required this.controller,
    this.initialText,
    this.textOnly = false,
  });

  @override
  State<_SlotSheet> createState() => _SlotSheetState();
}

class _SlotSheetState extends State<_SlotSheet> {
  late bool textMode = widget.textOnly || widget.initialText != null;
  String query = '';
  late final TextEditingController textController =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  void _submitText([String? value]) {
    final text = (value ?? textController.text).trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop<PlannerSlotChoice>((recipe: null, text: text));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          if (!widget.textOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    icon: const Icon(Icons.restaurant_menu_rounded),
                    label: Text(loc.plannerRecipe),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: const Icon(Icons.edit_note_rounded),
                    label: Text(loc.plannerText),
                  ),
                ],
                selected: {textMode},
                onSelectionChanged: (s) => setState(() => textMode = s.first),
              ),
            ),
          Expanded(child: textMode ? _buildText(context) : _buildRecipes(context)),
        ],
      ),
    );
  }

  Widget _buildText(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final defaults = [
      loc.plannerNoteEatingOut,
      loc.plannerNoteLeftovers,
      loc.plannerNoteTakeaway,
    ];
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        TextField(
          controller: textController,
          autofocus: true,
          maxLength: 256,
          textInputAction: TextInputAction.done,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: loc.plannerNoteHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: _submitText,
        ),
        const SizedBox(height: 8),
        Text(
          loc.plannerRecentNotes,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<String>>(
          future: widget.recentTexts,
          builder: (context, snapshot) {
            final texts = <String>{...?snapshot.data, ...defaults}.toList();
            return Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final t in texts)
                  ActionChip(
                    label: Text(t),
                    onPressed: () => setState(() {
                      textController.text = t;
                      textController.selection =
                          TextSelection.collapsed(offset: t.length);
                    }),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Text(
          loc.plannerNoteInfo,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(loc.cancel),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder(
              valueListenable: textController,
              builder: (context, value, _) => FilledButton(
                onPressed: value.text.trim().isEmpty ? null : _submitText,
                child: Text(
                  widget.initialText != null ? loc.save : loc.add,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildRecipes(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
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
                  onTap: () => Navigator.of(context).pop<PlannerSlotChoice>(
                    (recipe: recipes[i], text: null),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
