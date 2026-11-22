import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/widgets/planner_week_view.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const recipes = [Recipe(name: 'Lentil soup'), Recipe(name: 'Paella')];

  /// Opens the slot sheet and returns a getter for what it popped.
  Future<PlannerSlotChoice? Function()> openSheet(WidgetTester tester) async {
    PlannerSlotChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showPlannerSlotSheet(
                  context,
                  title: 'Tuesday 24 · Dinner',
                  recipes: Future.value(recipes),
                  recentTexts: Future.value(const []),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('empty search shows "New recipe…" that opens the editor',
      (tester) async {
    final result = await openSheet(tester);

    await tester.tap(find.text('New recipe…'));
    await tester.pumpAndSettle();

    final choice = result();
    expect(choice, isA<PlannerSlotNewRecipe>());
    choice as PlannerSlotNewRecipe;
    expect(choice.name, '');
    expect(choice.openEditor, isTrue);
  });

  testWidgets('a search without a match makes a quick recipe', (tester) async {
    final result = await openSheet(tester);

    await tester.enterText(find.byType(TextField), ' Lentil stew ');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create recipe "Lentil stew"'));
    await tester.pumpAndSettle();

    final choice = result();
    expect(choice, isA<PlannerSlotNewRecipe>());
    choice as PlannerSlotNewRecipe;
    expect(choice.name, 'Lentil stew');
    expect(choice.openEditor, isFalse);
  });

  testWidgets('the pencil opens the editor with the search text',
      (tester) async {
    final result = await openSheet(tester);

    await tester.enterText(find.byType(TextField), 'Lentil stew');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit before saving'));
    await tester.pumpAndSettle();

    final choice = result();
    expect(choice, isA<PlannerSlotNewRecipe>());
    choice as PlannerSlotNewRecipe;
    expect(choice.name, 'Lentil stew');
    expect(choice.openEditor, isTrue);
  });

  testWidgets('an exact match hides the create row', (tester) async {
    final result = await openSheet(tester);

    await tester.enterText(find.byType(TextField), 'paella');
    await tester.pumpAndSettle();
    expect(find.textContaining('Create recipe'), findsNothing);

    await tester.tap(find.text('Paella'));
    await tester.pumpAndSettle();

    final choice = result();
    expect(choice, isA<PlannerSlotRecipe>());
    expect((choice as PlannerSlotRecipe).recipe.name, 'Paella');
  });

  testWidgets('a partial match keeps the create row above the matches',
      (tester) async {
    await openSheet(tester);

    await tester.enterText(find.byType(TextField), 'lentil');
    await tester.pumpAndSettle();

    expect(find.text('Create recipe "lentil"'), findsOneWidget);
    expect(find.text('Lentil soup'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Create recipe "lentil"')).dy,
      lessThan(tester.getTopLeft(find.text('Lentil soup')).dy),
    );
  });
}
