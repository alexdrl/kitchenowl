import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/item_icons.dart';
import 'package:kitchenowl/models/category.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/shoppinglist.dart';
import 'package:kitchenowl/models/wear_snapshot.dart';

ShoppingList _list(int id, String name, List<ShoppinglistItem> items) =>
    ShoppingList(id: id, name: name, items: items);

void main() {
  const dairy = Category(id: 1, name: 'Dairy', ordering: 1);
  const veg = Category(id: 2, name: 'Vegetables', ordering: 2);

  final items = [
    const ShoppinglistItem(id: 4, name: 'Bread'),
    const ShoppinglistItem(id: 3, name: 'Tomatoes', category: veg),
    const ShoppinglistItem(
        id: 1, name: 'Milk', description: '2 l', category: dairy),
    const ShoppinglistItem(id: 2, name: 'apples', category: veg),
    const ShoppinglistItem(id: 5, name: 'Butter', category: dairy),
  ];

  group('WearSnapshot.build', () {
    test('sorts like the category view, uncategorized last', () {
      final s = WearSnapshot.build(
        householdId: 9,
        lists: [_list(7, 'Groceries', items)],
        nowMs: 1000,
      )!;

      expect(s.items.map((e) => e.name),
          ['Butter', 'Milk', 'apples', 'Tomatoes', 'Bread']);
      expect(s.items.map((e) => e.category),
          ['Dairy', 'Dairy', 'Vegetables', 'Vegetables', null]);
      expect(s.items[1].description, '2 l');
      expect(s.householdId, 9);
      expect(s.updatedMs, 1000);
    });

    test('list choice: watch choice, then phone list, then the first', () {
      final lists = [_list(7, 'A', []), _list(8, 'B', []), _list(9, 'C', [])];
      int pick({int? preferred, int? fallback}) => WearSnapshot.build(
            householdId: 1,
            lists: lists,
            nowMs: 0,
            preferredListId: preferred,
            fallbackListId: fallback,
          )!
              .listId;

      expect(pick(preferred: 9, fallback: 8), 9);
      expect(pick(preferred: 42, fallback: 8), 8); // watch list was deleted
      expect(pick(), 7);
      final s = WearSnapshot.build(householdId: 1, lists: lists, nowMs: 0)!;
      expect(s.lists.map((e) => e.name), ['A', 'B', 'C']);
    });

    test('no lists, no snapshot', () {
      expect(WearSnapshot.build(householdId: 1, lists: [], nowMs: 0), isNull);
    });

    test('items carry the code point of their icon in the Items font', () {
      final s = WearSnapshot.build(
        householdId: 1,
        lists: [
          _list(7, 'A', [
            const ShoppinglistItem(id: 1, name: 'Apple', icon: 'apple'),
            const ShoppinglistItem(id: 2, name: 'Custom'),
            const ShoppinglistItem(id: 3, name: 'Unknown', icon: 'no_such'),
          ])
        ],
        nowMs: 0,
      )!;

      expect(s.items.map((e) => e.icon), [ItemIcons.apple.codePoint, null, null]);
      // survives the JSON, and is left out when there is none
      final json = jsonDecode(s.encode());
      expect(json['items'][0]['icon'], ItemIcons.apple.codePoint);
      expect(json['items'][1].containsKey('icon'), isFalse);
      expect(WearSnapshot.fromJson(json).items.first.icon,
          ItemIcons.apple.codePoint);
    });

    test('items without id are left out (the watch cannot address them)', () {
      final s = WearSnapshot.build(
        householdId: 1,
        lists: [
          _list(7, 'A', [
            const ShoppinglistItem(name: 'No id'),
            const ShoppinglistItem(id: 1, name: 'With id'),
          ])
        ],
        nowMs: 0,
      )!;
      expect(s.items.map((e) => e.name), ['With id']);
    });
  });

  group('JSON', () {
    test('round trip', () {
      final s = WearSnapshot.build(
        householdId: 9,
        lists: [
          _list(7, 'Groceries', items),
          _list(8, 'DIY', []),
        ],
        nowMs: 1700000000000,
      )!;

      final back = WearSnapshot.fromJson(jsonDecode(s.encode()));
      expect(back.toJson(), s.toJson());
      expect(back.lists.length, 2);
      expect(back.items.first.name, 'Butter');
    });

    test('has the documented shape', () {
      final s = WearSnapshot.build(
        householdId: 9,
        lists: [
          _list(7, 'Groceries', [
            const ShoppinglistItem(
                id: 1, name: 'Milk', description: '2 l', category: dairy),
          ])
        ],
        nowMs: 5,
      )!;

      expect(jsonDecode(s.encode()), {
        'version': 1,
        'household_id': 9,
        'list_id': 7,
        'list_name': 'Groceries',
        'updated_ms': 5,
        'lists': [
          {'id': 7, 'name': 'Groceries'}
        ],
        'items': [
          {'id': 1, 'name': 'Milk', 'description': '2 l', 'category': 'Dairy'}
        ],
      });
    });

    test('content key ignores the time only', () {
      final a = WearSnapshot.build(
          householdId: 1, lists: [_list(7, 'A', items)], nowMs: 1)!;
      final b = WearSnapshot.build(
          householdId: 1, lists: [_list(7, 'A', items)], nowMs: 999)!;
      final c = WearSnapshot.build(
          householdId: 1, lists: [_list(7, 'A', items.sublist(1))], nowMs: 1)!;
      expect(a.contentKey, b.contentKey);
      expect(a.contentKey, isNot(c.contentKey));
    });

    test('a huge list is cut to fit the Data Layer limit', () {
      final many = List.generate(
        4000,
        (i) => ShoppinglistItem(
          id: i + 1,
          name: 'Item number $i with a rather long name',
          description: 'some description',
          category: dairy,
        ),
      );
      final s = WearSnapshot.build(
          householdId: 1, lists: [_list(7, 'Big', many)], nowMs: 1)!;
      final text = s.encode();

      expect(utf8.encode(text).length, lessThanOrEqualTo(WearSnapshot.maxBytes));
      final back = WearSnapshot.fromJson(jsonDecode(text));
      expect(back.items, isNotEmpty);
      expect(back.items.length, lessThan(4000));
      // the first items are the ones kept
      expect(back.items.first.id, s.items.first.id);
    });
  });

  group('WearAction.tryParse', () {
    test('remove', () {
      final a = WearAction.tryParse(jsonEncode({
        'type': 'remove',
        'list_id': 7,
        'item_id': 3,
        'item_name': 'Milk',
        'description': '2 l',
        'created_ms': 1700000000123,
      }))!;
      expect(a.type, WearActionType.remove);
      expect(a.listId, 7);
      expect(a.itemId, 3);
      expect(a.itemName, 'Milk');
      expect(a.createdMs, 1700000000123);
    });

    test('add, refresh and select_list', () {
      final add = WearAction.tryParse(jsonEncode({
        'type': 'add',
        'list_id': 7,
        'item_name': 'Milk',
        'description': '2 l',
      }))!;
      expect(add.type, WearActionType.add);
      expect(add.description, '2 l');
      expect(add.itemId, isNull);

      expect(
        WearAction.tryParse(jsonEncode({'type': 'refresh', 'list_id': 7}))!
            .type,
        WearActionType.refresh,
      );
      expect(
        WearAction.tryParse(jsonEncode({'type': 'select_list', 'list_id': 8}))!
            .type,
        WearActionType.selectList,
      );
    });

    test('garbage is rejected', () {
      expect(WearAction.tryParse('not json'), isNull);
      expect(WearAction.tryParse('[]'), isNull);
      expect(WearAction.tryParse(jsonEncode({'type': 'explode', 'list_id': 1})),
          isNull);
      expect(WearAction.tryParse(jsonEncode({'type': 'refresh'})), isNull);
      // remove/add need a name
      expect(
          WearAction.tryParse(
              jsonEncode({'type': 'remove', 'list_id': 1, 'item_id': 2})),
          isNull);
    });
  });
}
