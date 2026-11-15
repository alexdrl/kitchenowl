import 'package:kitchenowl/enums/meal_enum.dart';
import 'package:kitchenowl/models/model.dart';

/// A meal planned as free text instead of a recipe, e.g. "Dinner at X".
class PlannerNote extends Model {
  final int? id;

  /// UTC midnight of the planned day, like [RecipePlan.cookingDate]
  final DateTime cookingDate;
  final Meal meal;
  final String text;

  const PlannerNote({
    this.id,
    required this.cookingDate,
    this.meal = Meal.any,
    required this.text,
  });

  factory PlannerNote.fromJson(Map<String, dynamic> map) {
    final date =
        DateTime.fromMillisecondsSinceEpoch(map['cooking_date'], isUtc: true);
    return PlannerNote(
      id: map['id'],
      cookingDate: DateTime.utc(date.year, date.month, date.day),
      meal: Meal.parse(map['meal']),
      text: map['text'] ?? '',
    );
  }

  PlannerNote copyWith({DateTime? cookingDate, Meal? meal, String? text}) =>
      PlannerNote(
        id: id,
        cookingDate: cookingDate ?? this.cookingDate,
        meal: meal ?? this.meal,
        text: text ?? this.text,
      );

  @override
  List<Object?> get props => [id, cookingDate, meal, text];

  @override
  Map<String, dynamic> toJson() => {
        'cooking_date': cookingDate.millisecondsSinceEpoch,
        'meal': meal.name,
        'text': text,
      };

  @override
  Map<String, dynamic> toJsonWithId() => toJson()..addAll({'id': id});
}
