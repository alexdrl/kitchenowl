import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:kitchenowl/services/app_log_upload.dart';
import 'package:kitchenowl/services/menu_widget.dart';
import 'package:kitchenowl/services/phone_calendar.dart';

/// Facts about the fork's own features for the summary record of "Send logs": the menu
/// widget, the phone calendar and the watch worker. (The watch itself answers through
/// `WearBridge`.)
void registerForkDiagnostics() {
  if (!AppLog.isSupported) return;

  AppDiagnostics.register('widget', () async {
    final widgets = await HomeWidget.getInstalledWidgets();
    final installed = widgets
        .where(
            (w) => w.androidClassName?.endsWith('MenuWidgetProvider') ?? false)
        .length;
    int? updated;
    try {
      final data = await HomeWidget.getWidgetData<String>(MenuWidget.dataKey);
      updated = data == null ? null : (jsonDecode(data) as Map)['updated'];
    } catch (e) {
      // only a poorer summary
    }
    return {
      'installed': installed,
      'data_updated': updated == null
          ? 'never'
          : DateTime.fromMillisecondsSinceEpoch(updated).toIso8601String(),
    };
  });

  AppDiagnostics.register(
    'calendar',
    () async => {'enabled': await PhoneCalendar.isEnabled()},
  );

  AppDiagnostics.register(
    'wear_worker',
    () async => {
      'last_run':
          AppLog.lastMark('wear_worker')?.toIso8601String() ?? 'never',
    },
  );
}
