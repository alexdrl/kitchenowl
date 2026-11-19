import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/shoppinglist.dart';
import 'package:kitchenowl/models/wear_snapshot.dart';
import 'package:kitchenowl/services/background_task.dart';
import 'package:kitchenowl/services/storage/mem_storage.dart';
import 'package:kitchenowl/services/storage/storage.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/shoppinglist.dart';

/// Relays the shopping list to the KitchenOwl Wear OS app and applies what the watch
/// does, over the Wearable Data Layer. The watch has no network access and no token.
///
/// Phone → watch: [publish] puts a [WearSnapshot] on `/kitchenowl/shoppinglist`.
/// Watch → phone: the watch writes `/kitchenowl/actions/<uuid>` items; the native
/// `WearActionsService` (MainActivity.kt) tells us, [processPending] applies them with the
/// normal transactions (so they queue when the phone is offline), deletes them and
/// republishes. Works in the UI engine and in a headless engine ([wearActionsMain]).
class WearBridge {
  static const _channel = MethodChannel('com.tombursch.kitchenowl/wear');

  static const _kLastHousehold = 'lastHouseholdId';
  static const _kWearList = 'wearListId';

  /// Identical lists are not republished more often than this.
  static const _republishAfter = Duration(minutes: 5);

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static bool _initialized = false;
  static bool _processing = false;
  static bool _again = false;
  static String? _lastKey;
  static DateTime? _lastPublish;

  /// Call once the UI engine runs: lets the native side nudge us when the watch did something.
  static void init() {
    if (!isSupported || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'actionsChanged') unawaited(processPending());
    });
    unawaited(processPending());
  }

  /// Publishes [lists] of [household]. Cheap to call on every change of the list:
  /// identical content is only sent again after a few minutes (to refresh its age).
  static Future<void> publish(
    int householdId,
    Iterable<ShoppingList> lists, {
    int? phoneListId,
    bool force = false,
  }) async {
    if (!isSupported) return;
    try {
      final preferred =
          await PreferenceStorage.getInstance().readInt(key: _kWearList);
      final snapshot = WearSnapshot.build(
        householdId: householdId,
        lists: lists,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        preferredListId: preferred,
        fallbackListId: phoneListId,
      );
      if (snapshot == null) return;

      final now = DateTime.now();
      if (!force &&
          snapshot.contentKey == _lastKey &&
          _lastPublish != null &&
          now.difference(_lastPublish!) < _republishAfter) {
        return;
      }
      _lastKey = snapshot.contentKey;
      _lastPublish = now;
      await _channel.invokeMethod('publishSnapshot', snapshot.encode());
    } on MissingPluginException {
      // No native side (tests, other platforms).
    } on PlatformException catch (e) {
      // Play services missing or no watch paired: not an error for the app.
      debugPrint('[WearBridge] publish failed: ${e.message}');
    }
  }

  /// Applies the actions waiting in the Data Layer, then republishes the list.
  /// [refresh] republishes even when there was nothing to apply (periodic refresh).
  static Future<void> processPending({bool refresh = false}) async {
    if (!isSupported) return;
    if (_processing) {
      _again = true;
      return;
    }
    _processing = true;
    try {
      do {
        _again = false;
        await _processOnce(refresh);
      } while (_again);
    } on MissingPluginException {
      // No native side.
    } catch (e) {
      debugPrint('[WearBridge] processing failed: $e');
    } finally {
      _processing = false;
    }
  }

  static Future<void> _processOnce(bool refresh) async {
    final raw =
        await _channel.invokeListMethod<Map>('pendingActions') ?? const [];
    if (raw.isEmpty && !refresh) return;

    final prefs = PreferenceStorage.getInstance();
    final householdId = await prefs.readInt(key: _kLastHousehold);
    // Not logged in (or never opened a household): leave the actions for later.
    if (householdId == null) return;
    final household = Household(id: householdId);

    final pending = <(String, WearAction?)>[];
    for (final entry in raw) {
      pending.add((
        entry['uri'] as String,
        WearAction.tryParse(entry['json'] as String? ?? ''),
      ));
    }
    // In the order the user did them on the watch (remove, then undo = add).
    pending.sort((a, b) =>
        (a.$2?.createdMs ?? 0).compareTo(b.$2?.createdMs ?? 0));

    final done = <String>[];
    for (final (uri, action) in pending) {
      if (action == null) {
        done.add(uri); // garbage: drop it
        continue;
      }
      try {
        await _apply(household, action, prefs);
        done.add(uri);
      } catch (e) {
        // Keep it: it is tried again at the next nudge or app start.
        debugPrint('[WearBridge] could not apply action: $e');
      }
    }
    if (done.isNotEmpty) {
      await _channel.invokeMethod('ackActions', done);
    }

    final lists = await BackgroundTask.refreshShoppingLists(household.id) ??
        await MemStorage.getInstance().readShoppingLists(household);
    if (lists != null) {
      await publish(household.id, lists, force: true);
    }
  }

  static Future<void> _apply(
    Household household,
    WearAction action,
    PreferenceStorage prefs,
  ) async {
    final shoppinglist = ShoppingList(id: action.listId, name: '');
    switch (action.type) {
      case WearActionType.remove:
        // Removing an item that is already gone is a no-op on the server.
        await TransactionHandler.getInstance().runTransaction(
          TransactionShoppingListRemoveItem(
            household: household,
            shoppinglist: shoppinglist,
            item: ShoppinglistItem(id: action.itemId, name: action.itemName!),
            timestamp: action.createdMs > 0
                ? DateTime.fromMillisecondsSinceEpoch(action.createdMs)
                : null,
          ),
        );
      case WearActionType.add:
        // By name: adding an item that is already on the list does nothing.
        await TransactionHandler.getInstance().runTransaction(
          TransactionShoppingListAddItem(
            household: household,
            shoppinglist: shoppinglist,
            item: ItemWithDescription(
              name: action.itemName!,
              description: action.description,
            ),
          ),
        );
      case WearActionType.selectList:
        await prefs.writeInt(key: _kWearList, value: action.listId);
      case WearActionType.refresh:
        break; // the republish after the loop is the refresh
    }
  }

  /// Dart entry point of the headless engine that `WearActionsWorker` starts when the
  /// watch writes an action and the app is not open.
  @pragma('vm:entry-point')
  static Future<void> headlessMain() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final connected = await BackgroundTask.connectHeadless().timeout(
        const Duration(seconds: 40),
        onTimeout: () => false,
      );
      if (connected) {
        _initialized = true;
        // A nudge while we run just makes the loop go once more.
        _channel.setMethodCallHandler((call) async {
          if (call.method == 'actionsChanged') unawaited(processPending());
        });
        await processPending(refresh: true)
            .timeout(const Duration(seconds: 40));
      }
    } catch (e) {
      debugPrint('[WearBridge] headless run failed: $e');
    } finally {
      try {
        await _channel.invokeMethod('headlessDone');
      } catch (_) {}
    }
  }
}

/// Top-level entry point looked up by name from the native side.
@pragma('vm:entry-point')
Future<void> wearActionsMain() => WearBridge.headlessMain();
