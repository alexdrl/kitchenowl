import 'package:kitchenowl/config.dart';
import 'package:kitchenowl/cubits/auth_cubit.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/shoppinglist.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:kitchenowl/services/app_log_upload.dart';
import 'package:kitchenowl/services/storage/mem_storage.dart';
import 'package:kitchenowl/services/storage/storage.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/shoppinglist.dart';
import 'package:package_info_plus/package_info_plus.dart';

class BackgroundTask {
  /// The background fetch of the open app, plus the log upload (which has no wake-up of its own).
  static Future<void> runWithLogs(AuthCubit authCubit) =>
      _withLogs(() => run(authCubit));

  /// The headless background fetch, plus the log upload.
  static Future<void> runHeadlessWithLogs() async {
    AppLog.installGlobalHandlers();
    await AppLog.init(source: 'bg');
    await _withLogs(runHeadless);
  }

  static Future<void> _withLogs(Future<void> Function() work) async {
    await AppLog.mark('background_fetch');
    Future<void> logged() async {
      try {
        await work();
      } catch (e, st) {
        AppLog.warn('Background fetch failed', error: e, stack: st);
        rethrow;
      }
    }

    await Future.wait([logged(), AppLogUploader.maybeUpload()]);
  }

  static Future<void> run(AuthCubit authCubit) async {
    if (authCubit.getUser() != null) {
      await Future.wait([
        TransactionHandler.getInstance().runOpenTransactions(),
        PreferenceStorage.getInstance()
            .readInt(key: 'lastHouseholdId')
            .then((id) async {
          if (id != null)
            await TransactionHandler.getInstance().runTransaction(
                TransactionShoppingListGet(household: Household(id: id)));
        }),
      ]);
    }
  }

  static Future<void> runHeadless() async {
    if (!await connectHeadless()) return;

    await Future.wait([
      TransactionHandler.getInstance().runOpenTransactions(),
      _refreshShoppingLists(PreferenceStorage.getInstance()),
    ]);
  }

  /// Connects [ApiService] without a UI: server URL from the preferences, refresh token
  /// from the secure storage, and the handlers that keep a rotated token. Shared by every
  /// headless entry point (background fetch, Wear OS actions).
  /// Returns false when offline mode is forced or there is no valid login.
  static Future<bool> connectHeadless() async {
    final preferenceStorage = PreferenceStorage.getInstance();
    final forcedOfflineMode =
        await preferenceStorage.readBool(key: 'forcedOfflineMode') ?? false;
    if (forcedOfflineMode) return false;

    Config.packageInfo = PackageInfo.fromPlatform();
    final url =
        await preferenceStorage.read(key: 'URL') ?? Config.defaultServer;
    final secureStorage = SecureStorage.getInstance();
    final token = await secureStorage.read(key: 'TOKEN');

    ApiService.setTokenRotationHandler(
      (token) => secureStorage.write(key: 'TOKEN', value: token),
    );
    ApiService.setTokenBeforeReauthHandler((token) {
      if (token == null) return Future.value(token);
      return secureStorage.read(key: 'TOKEN').then((value) => value ?? token);
    });

    await ApiService.connectTo(url, refreshToken: token);

    return ApiService.getInstance().isAuthenticated();
  }

  /// Fetches the lists of [householdId] and stores them in the cache; null when offline.
  static Future<List<ShoppingList>?> refreshShoppingLists(int householdId) =>
      _fetchShoppingLists(PreferenceStorage.getInstance(), householdId);

  static Future<void> _refreshShoppingLists(
    PreferenceStorage preferenceStorage,
  ) async {
    final householdId = await preferenceStorage.readInt(key: 'lastHouseholdId');
    if (householdId == null) return;

    // Not published to the watch from here: this engine (created by the
    // background_fetch plugin) has no Wear channel. WearRefreshWorker does that.
    await _fetchShoppingLists(preferenceStorage, householdId);
  }

  static Future<List<ShoppingList>?> _fetchShoppingLists(
    PreferenceStorage preferenceStorage,
    int householdId,
  ) async {
    final recentItemsCount =
        await preferenceStorage.readInt(key: 'recentItemsCount') ?? 9;
    final household = Household(id: householdId);
    final shoppingLists = await ApiService.getInstance().getShoppingLists(
      household,
      recentItemlimit: recentItemsCount + 3,
    );
    if (shoppingLists != null) {
      await MemStorage.getInstance()
          .writeShoppingLists(household, shoppingLists);
    }

    return shoppingLists;
  }
}
