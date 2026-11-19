import 'dart:convert';

import 'package:kitchenowl/helpers/item_name.dart';
import 'package:kitchenowl/models/shoppinglist.dart';

/// What the phone publishes for the Wear OS app at `/kitchenowl/shoppinglist`
/// (Wearable Data Layer, UTF-8 JSON). The watch app has no network access and no
/// token: this is all it knows. Parsed by `PhoneSnapshot` in kitchenowl/android/wear.
///
/// ```json
/// {"version":1,"household_id":1,"list_id":7,"list_name":"Shopping list",
///  "updated_ms":1700000000000,"lists":[{"id":7,"name":"Shopping list"}],
///  "items":[{"id":3,"name":"Milk","description":"2 l","category":"Dairy"}]}
/// ```
///
/// Items are sorted like the app's category view: categories by their ordering,
/// items by name, uncategorized last.
class WearSnapshot {
  static const int version = 1;

  /// The Data Layer allows 100 KB per item; stay well below.
  static const int maxBytes = 90 * 1024;

  final int householdId;
  final int listId;
  final String listName;
  final int updatedMs;
  final List<WearListRef> lists;
  final List<WearItem> items;

  const WearSnapshot({
    required this.householdId,
    required this.listId,
    required this.listName,
    required this.updatedMs,
    required this.lists,
    required this.items,
  });

  /// Picks the list to show: [preferredListId] (chosen on the watch), else
  /// [fallbackListId] (the one open on the phone), else the first one.
  /// Returns null when there is no list at all.
  static WearSnapshot? build({
    required int householdId,
    required Iterable<ShoppingList> lists,
    required int nowMs,
    int? preferredListId,
    int? fallbackListId,
  }) {
    final all = lists.where((l) => l.id != null).toList();
    if (all.isEmpty) return null;
    final list = all.where((l) => l.id == preferredListId).firstOrNull ??
        all.where((l) => l.id == fallbackListId).firstOrNull ??
        all.first;

    final sorted = List.of(list.items)
      ..sort((a, b) {
        final ca = a.category;
        final cb = b.category;
        if ((ca == null) != (cb == null)) return ca == null ? 1 : -1;
        if (ca != null && cb != null) {
          final byOrdering = ca.ordering.compareTo(cb.ordering);
          if (byOrdering != 0) return byOrdering;
          final byCategory = ca.name.compareTo(cb.name);
          if (byCategory != 0) return byCategory;
        }
        return compareItemNames(a.name, b.name);
      });

    return WearSnapshot(
      householdId: householdId,
      listId: list.id!,
      listName: list.name,
      updatedMs: nowMs,
      lists: all.map((l) => WearListRef(l.id!, l.name)).toList(),
      items: sorted
          .where((e) => e.id != null)
          .map((e) => WearItem(
                id: e.id!,
                name: e.name,
                description: e.description,
                category: e.category?.name,
              ))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'household_id': householdId,
        'list_id': listId,
        'list_name': listName,
        'updated_ms': updatedMs,
        'lists': lists.map((e) => e.toJson()).toList(),
        'items': items.map((e) => e.toJson()).toList(),
      };

  factory WearSnapshot.fromJson(Map<String, dynamic> map) => WearSnapshot(
        householdId: map['household_id'] as int,
        listId: map['list_id'] as int,
        listName: map['list_name'] as String? ?? '',
        updatedMs: map['updated_ms'] as int? ?? 0,
        lists: List.from(map['lists'] ?? const [])
            .map((e) => WearListRef.fromJson(e))
            .toList(),
        items: List.from(map['items'] ?? const [])
            .map((e) => WearItem.fromJson(e))
            .toList(),
      );

  /// The JSON for the Data Layer. Too long lists lose their last items (the ones
  /// of the last categories) rather than failing the whole publish.
  String encode() {
    var current = this;
    var text = jsonEncode(current.toJson());
    while (utf8.encode(text).length > maxBytes && current.items.isNotEmpty) {
      final keep = (current.items.length * 0.8).floor();
      current = WearSnapshot(
        householdId: householdId,
        listId: listId,
        listName: listName,
        updatedMs: updatedMs,
        lists: lists,
        items: current.items.sublist(0, keep),
      );
      text = jsonEncode(current.toJson());
    }
    return text;
  }

  /// The same snapshot apart from the time: used to skip identical republishes.
  String get contentKey => jsonEncode((toJson()..remove('updated_ms')));
}

class WearListRef {
  final int id;
  final String name;

  const WearListRef(this.id, this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory WearListRef.fromJson(Map<String, dynamic> map) =>
      WearListRef(map['id'] as int, map['name'] as String? ?? '');
}

class WearItem {
  final int id;
  final String name;
  final String description;
  final String? category;

  const WearItem({
    required this.id,
    required this.name,
    this.description = '',
    this.category,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'category': category,
      };

  factory WearItem.fromJson(Map<String, dynamic> map) => WearItem(
        id: map['id'] as int,
        name: map['name'] as String,
        description: map['description'] as String? ?? '',
        category: map['category'] as String?,
      );
}

enum WearActionType {
  remove,
  add,
  refresh,
  selectList;

  static WearActionType? parse(String? value) => switch (value) {
        'remove' => remove,
        'add' => add,
        'refresh' => refresh,
        'select_list' => selectList,
        _ => null,
      };
}

/// An action the watch wrote to `/kitchenowl/actions/<uuid>`.
/// `{type: remove|add|refresh|select_list, item_id?, item_name?, description?,
///   list_id, created_ms}`
class WearAction {
  final WearActionType type;
  final int listId;
  final int? itemId;
  final String? itemName;
  final String description;

  /// When the user did it on the watch; actions are applied in this order.
  final int createdMs;

  const WearAction({
    required this.type,
    required this.listId,
    this.itemId,
    this.itemName,
    this.description = '',
    this.createdMs = 0,
  });

  /// Null for anything that is not a valid action (it is then dropped).
  static WearAction? tryParse(String text) {
    try {
      final map = jsonDecode(text);
      if (map is! Map<String, dynamic>) return null;
      final type = WearActionType.parse(map['type'] as String?);
      final listId = map['list_id'];
      if (type == null || listId is! int) return null;
      final itemName = map['item_name'] as String?;
      final itemId = map['item_id'];
      if ((type == WearActionType.remove || type == WearActionType.add) &&
          (itemName == null || itemName.isEmpty)) {
        return null;
      }

      return WearAction(
        type: type,
        listId: listId,
        itemId: itemId is int ? itemId : null,
        itemName: itemName,
        description: map['description'] as String? ?? '',
        createdMs: map['created_ms'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}
