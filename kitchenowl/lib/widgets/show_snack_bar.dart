import 'package:material_ui/material_ui.dart';

ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackbar({
  required BuildContext context,
  SnackBarAction? action,
  required Widget content,
  Duration? duration,
  double? width = 180,

  /// Null keeps the default: a snack bar with an [action] stays until the
  /// user closes it. False closes it after [duration] also with an action.
  bool? persist,
}) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        action: action,
        persist: persist,
        content: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyLarge!,
          textAlign: action == null ? TextAlign.center : null,
          child: content,
        ),
        duration: duration ?? const Duration(milliseconds: 1500),
        width: width,
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.none,
        backgroundColor: Theme.of(context).cardColor,
      ),
    );
