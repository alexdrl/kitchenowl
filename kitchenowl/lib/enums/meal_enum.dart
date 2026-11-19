import 'package:material_ui/material_ui.dart';
import 'package:kitchenowl/kitchenowl.dart';

/// Moment of the day a planned recipe is cooked for.
///
/// `any` is what older clients (and plans made before meals existed) use.
enum Meal {
  breakfast,
  lunch,
  dinner,
  any;

  static Meal parse(String? value) => Meal.values.firstWhere(
        (e) => e.name == value,
        orElse: () => Meal.any,
      );

  /// Sensible default for the add sheet: lunch until 4 pm, then dinner.
  static Meal suggested([DateTime? now]) =>
      (now ?? DateTime.now()).hour < 16 ? Meal.lunch : Meal.dinner;

  String toLocalizedString(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return switch (this) {
      Meal.breakfast => loc.mealBreakfast,
      Meal.lunch => loc.mealLunch,
      Meal.dinner => loc.mealDinner,
      Meal.any => loc.mealOther,
    };
  }

  IconData get icon => switch (this) {
        Meal.breakfast => Icons.free_breakfast_rounded,
        Meal.lunch => Icons.wb_sunny_rounded,
        Meal.dinner => Icons.nightlight_round,
        Meal.any => Icons.restaurant_rounded,
      };

  /// Background and foreground used for this meal in the week view.
  (Color, Color) colors(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (this) {
      Meal.breakfast => dark
          ? (const Color(0xFF653E00), const Color(0xFFFFDDB8))
          : (const Color(0xFFFFDDB8), const Color(0xFF2A1700)),
      Meal.lunch => (scheme.primaryContainer, scheme.onPrimaryContainer),
      Meal.dinner => dark
          ? (const Color(0xFF2F4578), const Color(0xFFD6E3FF))
          : (const Color(0xFFD6E3FF), const Color(0xFF001B3E)),
      Meal.any => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
    };
  }
}
