import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:kitchenowl/helpers/url_launcher.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart' as ul;

Future<void> showPlannerCalendarSheet(
  BuildContext context,
  Household household,
) =>
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => PlannerCalendarSheet(household: household),
    );

/// Shares the household's planner as a calendar feed (iCalendar). The
/// calendar app polls the link itself: iOS through the system subscription,
/// Android through ICSx⁵ (which writes it into the system calendar that
/// Samsung Calendar and Google Calendar show) or Google Calendar on the web.
class PlannerCalendarSheet extends StatefulWidget {
  final Household household;

  const PlannerCalendarSheet({super.key, required this.household});

  @override
  State<PlannerCalendarSheet> createState() => _PlannerCalendarSheetState();
}

class _PlannerCalendarSheetState extends State<PlannerCalendarSheet> {
  static final Uri _icsx5 = Uri.parse('https://icsx5.bitfire.at/');

  bool _loading = true;
  Uri? _feed;
  bool _canOpenWebcal = true;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool rotate = false}) async {
    setState(() => _loading = true);
    final api = ApiService.getInstance();
    final path = rotate
        ? await api.rotatePlannerCalendar(widget.household)
        : await api.getPlannerCalendarPath(widget.household, create: true);
    Uri? feed;
    if (path != null && path.isNotEmpty) {
      feed = Uri.parse(api.serverUrl + path);
      // Meal times are local times: tell the server whose
      final zone = await _localTimezone();
      if (zone != null) {
        feed = feed.replace(
          queryParameters: {...feed.queryParameters, 'tz': zone},
        );
      }
    }
    final canOpen = feed == null || !_isAndroid
        ? true
        : await ul.canLaunchUrl(_webcal(feed));
    if (!mounted) return;
    setState(() {
      _loading = false;
      _feed = feed;
      _canOpenWebcal = canOpen;
    });
    if (feed == null) {
      showSnackbar(
        context: context,
        content: Text(AppLocalizations.of(context)!.error),
      );
    }
  }

  static Future<String?> _localTimezone() async {
    try {
      return await FlutterTimezone.getLocalTimezone();
    } catch (e, st) {
      AppLog.warn('Reading the local time zone failed', error: e, stack: st);
      return null;
    }
  }

  /// webcal:// is what calendar apps register for; webcals:// tells the
  /// ones that know it (ICSx⁵) to keep HTTPS.
  static Uri _webcal(Uri feed) => feed.replace(
        scheme: feed.isScheme('https') && !kIsWeb && Platform.isAndroid
            ? 'webcals'
            : 'webcal',
      );

  Future<void> _openInCalendarApp(Uri feed) async {
    bool opened;
    try {
      opened = await ul.launchUrl(
        _webcal(feed),
        mode: ul.LaunchMode.externalNonBrowserApplication,
      );
    } catch (e, st) {
      AppLog.warn('Opening the calendar feed in an app failed',
          error: e, stack: st);
      opened = false;
    }
    if (!opened && mounted) {
      showSnackbar(
        context: context,
        content: Text(AppLocalizations.of(context)!.plannerCalendarOpenFailed),
      );
    }
  }

  Future<void> _addToGoogle(Uri feed) => openUrl(
        context,
        Uri.https('calendar.google.com', '/calendar/render', {
          'cid': feed.toString(),
        }).toString(),
      );

  Future<void> _copy(Uri feed) async {
    await Clipboard.setData(ClipboardData(text: feed.toString()));
    if (!mounted) return;
    showSnackbar(
      context: context,
      content: Text(AppLocalizations.of(context)!.copied),
    );
  }

  Future<void> _newLink() async {
    final loc = AppLocalizations.of(context)!;
    final confirmed = await askForConfirmation(
      context: context,
      title: Text(loc.plannerCalendarNewLink),
      content: Text(loc.plannerCalendarNewLinkInfo),
      confirmText: loc.plannerCalendarNewLink,
    );
    if (confirmed) await _load(rotate: true);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final feed = _feed;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                loc.plannerCalendar,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(loc.plannerCalendarInfo),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (feed != null) ...[
              if (_canOpenWebcal)
                ListTile(
                  leading: const Icon(Icons.event_available_rounded),
                  title: Text(loc.plannerCalendarOpen),
                  subtitle: _isAndroid
                      ? Text(loc.plannerCalendarOpenAndroid)
                      : null,
                  onTap: () => _openInCalendarApp(feed),
                )
              else
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: Text(loc.plannerCalendarGetIcsx5),
                  subtitle: Text(loc.plannerCalendarGetIcsx5Info),
                  onTap: () => openUrl(context, _icsx5.toString()),
                ),
              ListTile(
                leading: const Icon(Icons.calendar_month_rounded),
                title: Text(loc.plannerCalendarGoogle),
                subtitle: Text(loc.plannerCalendarGoogleInfo),
                onTap: () => _addToGoogle(feed),
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: Text(loc.plannerCalendarCopy),
                subtitle: Text(
                  '${feed.origin}${feed.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _copy(feed),
              ),
              ListTile(
                leading: const Icon(Icons.autorenew_rounded),
                title: Text(loc.plannerCalendarNewLink),
                subtitle: Text(loc.plannerCalendarNewLinkInfo),
                onTap: _newLink,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
