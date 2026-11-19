import 'package:flutter/services.dart';
import 'package:kitchenowl/services/menu_widget.dart';

/// The planned meals as a calendar of the phone (Android only): an account of
/// our own owns a read-only calendar that a sync adapter fills from the menu
/// [MenuWidget] stores (`CalendarSync.kt`). Calendar apps show it like any
/// other calendar.
abstract class PhoneCalendar {
  static const _channel = MethodChannel('kitchenowl/calendar_sync');

  static bool get supported => MenuWidget.supported;

  static Future<bool> isEnabled() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Turning it on asks for the calendar permissions. Returns whether it is on
  /// afterwards (false when the permissions were denied).
  static Future<bool> setEnabled(bool enabled) async {
    if (!supported) return false;
    try {
      if (!enabled) {
        await _channel.invokeMethod('disable');
        return false;
      }
      return await _channel.invokeMethod<bool>('enable') ?? false;
    } catch (_) {
      return false;
    }
  }
}
