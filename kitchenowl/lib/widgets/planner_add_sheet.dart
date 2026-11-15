import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/kitchenowl.dart';

typedef PlannerSlot = ({DateTime? cookingDate, Meal meal});

/// Asks for the day (or no day) and the meal a recipe is planned for.
///
/// Returns null when dismissed. `cookingDate` is a UTC midnight, the format
/// the planner API stores, or null for "no day".
Future<PlannerSlot?> showPlannerAddSheet(
  BuildContext context, {
  required String recipeName,
  bool showBreakfast = true,
  DateTime? initialDate,
  Meal? initialMeal,
}) {
  return showModalBottomSheet<PlannerSlot>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _PlannerAddSheet(
      recipeName: recipeName,
      showBreakfast: showBreakfast,
      initialDate: initialDate,
      initialMeal: initialMeal,
    ),
  );
}

DateTime _localDay(DateTime d) => DateTime(d.year, d.month, d.day);

class _PlannerAddSheet extends StatefulWidget {
  final String recipeName;
  final bool showBreakfast;
  final DateTime? initialDate;
  final Meal? initialMeal;

  const _PlannerAddSheet({
    required this.recipeName,
    required this.showBreakfast,
    this.initialDate,
    this.initialMeal,
  });

  @override
  State<_PlannerAddSheet> createState() => _PlannerAddSheetState();
}

class _PlannerAddSheetState extends State<_PlannerAddSheet> {
  /// Local midnight of the chosen day, null = no day
  DateTime? date;
  late Meal meal;

  @override
  void initState() {
    super.initState();
    date = _localDay(widget.initialDate ?? DateTime.now());
    meal = widget.initialMeal ?? Meal.suggested();
    if (!widget.showBreakfast && meal == Meal.breakfast) meal = Meal.lunch;
  }

  List<Meal> get meals => [
        if (widget.showBreakfast) Meal.breakfast,
        Meal.lunch,
        Meal.dinner,
        Meal.any,
      ];

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final today = _localDay(DateTime.now());
    final days = List.generate(8, (i) => today.add(Duration(days: i)));
    final customDate =
        date != null && !days.contains(date) ? date : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(loc.plannerAddTitle,
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            widget.recipeName,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 20),
          Text(loc.plannerDay, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(loc.plannerNoDay),
                selected: date == null,
                onSelected: (_) => setState(() => date = null),
              ),
              for (final day in days)
                ChoiceChip(
                  label: Text(day == today
                      ? loc.today
                      : DateFormat('E d').format(day)),
                  selected: date == day,
                  onSelected: (_) => setState(() => date = day),
                ),
              if (customDate != null)
                ChoiceChip(
                  label: Text(DateFormat.yMMMd().format(customDate)),
                  selected: true,
                  onSelected: (_) {},
                ),
              ActionChip(
                avatar: const Icon(Icons.calendar_month_rounded),
                label: Text(loc.plannerOtherDate),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date ?? today,
                    firstDate: DateTime(2000),
                    lastDate: today.add(const Duration(days: 400)),
                  );
                  if (picked != null) {
                    setState(() => date = _localDay(picked));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(loc.plannerMeal, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<Meal>(
            segments: [
              for (final m in meals)
                ButtonSegment(
                  value: m,
                  label: Text(m.toLocalizedString(context)),
                ),
            ],
            selected: {meal},
            showSelectedIcon: false,
            onSelectionChanged:
                date == null ? null : (s) => setState(() => meal = s.first),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(loc.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop<PlannerSlot>((
                  cookingDate: date == null
                      ? null
                      : DateTime.utc(date!.year, date!.month, date!.day),
                  meal: date == null ? Meal.any : meal,
                )),
                child: Text(loc.add),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
