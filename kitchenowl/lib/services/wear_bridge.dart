import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/planner.dart';
import 'package:kitchenowl/models/planner_note.dart';
import 'package:kitchenowl/models/wear_menu.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:kitchenowl/services/app_log_upload.dart';
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
///
/// Logs (fork): the watch hands its log lines over as `/kitchenowl/logs/<uuid>`, which the
/// native side stores for [AppLogUploader]. "Send logs" asks the watch for them first
/// ([_askWatchForLogs]); the watch's own button gets them sent right away (`logsUploadNow`).
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
  static String? _lastMenuKey;
  static DateTime? _lastMenuPublish;

  /// Call once the UI engine runs: lets the native side nudge us when the watch did something.
  static void init() {
    if (!isSupported || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onNativeCall);
    AppDiagnostics.registerBeforeManualUpload('watch', _askWatchForLogs);
    unawaited(processPending());
  }

  static Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'actionsChanged':
        unawaited(processPending());
      case 'watchLogs':
        _watchReplies.add((call.arguments as Map).cast<String, Object?>());
      case 'logsUploadNow':
        // The watch's "Send logs": its lines are in the inbox and upload-now is set.
        unawaited(AppLogUploader.maybeUpload());
    }
  }

  static final _watchReplies =
      StreamController<Map<String, Object?>>.broadcast();

  /// How long "Send logs" waits for the watch's lines.
  static const _watchReplyTimeout = Duration(seconds: 10);

  /// "Send logs" on the phone: asks the watch for its lines and waits a few seconds, so they
  /// go in the same upload. Returns facts for the summary record.
  static Future<Map<String, Object?>> _askWatchForLogs(String uploadId) async {
    if (!isSupported) return const {};
    // Listen before asking: the reply can be quick.
    final reply = _watchReplies.stream
        .firstWhere((r) => r['request_id'] == uploadId)
        .timeout(_watchReplyTimeout);
    try {
      final asked =
          await _channel.invokeMethod<bool>('requestWatchLogs', uploadId) ??
              false;
      if (!asked) {
        reply.ignore();
        return {'connected': false};
      }
      final r = await reply;
      // The watch sends at most a few items back to back: let the others land too.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return {
        'connected': true,
        'replied': true,
        'version': r['version'],
        'lines': r['lines'],
      };
    } on TimeoutException {
      AppLog.warn('The watch did not answer the log request in time');
      return {'connected': true, 'replied': false};
    } finally {
      _channel.invokeMethod('cancelWatchLogs', uploadId).ignore();
    }
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
      AppLog.info('Wear: publish failed', fields: {'reason': e.message});
    }
  }

  /// Publishes the planned menu (`/kitchenowl/menu`) for the watch's menu tile. Cheap to call
  /// on every change: identical content is only sent again after a few minutes.
  static Future<void> publishMenu(
    int householdId,
    List<RecipePlan> plans,
    List<PlannerNote> notes, {
    bool force = false,
  }) async {
    if (!isSupported) return;
    try {
      final now = DateTime.now();
      final menu = WearMenu.build(
        householdId: householdId,
        plans: plans,
        notes: notes,
        now: now,
      );
      final key = WearMenu.contentKey(menu);
      if (!force &&
          key == _lastMenuKey &&
          _lastMenuPublish != null &&
          now.difference(_lastMenuPublish!) < _republishAfter) {
        return;
      }
      _lastMenuKey = key;
      _lastMenuPublish = now;
      await _channel.invokeMethod('publishMenu', WearMenu.encode(menu));
    } on MissingPluginException {
      // No native side.
    } on PlatformException catch (e) {
      AppLog.info('Wear: menu publish failed', fields: {'reason': e.message});
    }
  }

  /// Downloads the plan and publishes it (periodic refresh, or the watch asked).
  static Future<void> _publishMenuFromApi(Household household) async {
    try {
      final api = ApiService.getInstance();
      final now = DateTime.now();
      final (plans, notes) = await (
        api.getPlanned(household),
        api.getPlannerNotes(
          household,
          from: DateTime.utc(
              now.year, now.month, now.day - (now.weekday - DateTime.monday)),
        ),
      ).wait;
      // Offline or the planner is off for this household: keep what the watch has.
      if (plans == null || notes == null) return;
      await publishMenu(household.id, plans, notes, force: true);
    } catch (e, st) {
      AppLog.warn('Wear: menu refresh failed', error: e, stack: st);
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
    } catch (e, st) {
      AppLog.warn('Wear: processing the actions failed', error: e, stack: st);
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
      } catch (e, st) {
        // Keep it: it is tried again at the next nudge or app start.
        AppLog.warn('Wear: could not apply an action',
            error: e, stack: st, fields: {'type': action.type.name});
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
    await _publishMenuFromApi(household);
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
    AppLog.installGlobalHandlers();
    await AppLog.init(source: 'wear_worker');
    await AppLog.mark('wear_worker');
    try {
      final connected = await BackgroundTask.connectHeadless().timeout(
        const Duration(seconds: 40),
        onTimeout: () => false,
      );
      if (connected) {
        _initialized = true;
        // A nudge while we run just makes the loop go once more.
        _channel.setMethodCallHandler(_onNativeCall);
        await processPending(refresh: true)
            .timeout(const Duration(seconds: 40));
      }
    } catch (e, st) {
      AppLog.warn('Wear: headless run failed', error: e, stack: st);
    } finally {
      // Reuses this wake-up: sends only when due (or the watch asked), else returns at once.
      await AppLogUploader.maybeUpload()
          .timeout(const Duration(seconds: 40))
          .catchError((_) => const UploadResult(ok: false));
      try {
        await _channel.invokeMethod('headlessDone');
      } catch (e, st) {
        AppLog.warn('Wear: headlessDone failed', error: e, stack: st);
      }
    }
  }
}

/// Top-level entry point looked up by name from the native side.
@pragma('vm:entry-point')
Future<void> wearActionsMain() => WearBridge.headlessMain();
