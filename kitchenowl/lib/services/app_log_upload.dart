import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:kitchenowl/services/app_log.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Where the logs go. Set at build time, never in git:
/// `--dart-define=KO_LOGS_ENDPOINT=https://… --dart-define=KO_LOGS_TOKEN=…`
/// (`fork/build-apk.sh` reads them from a file next to the signing key).
/// Without them nothing is ever sent and the "Send logs" button is hidden.
class LogUploadConfig {
  const LogUploadConfig({
    required this.endpoint,
    required this.token,
    this.environment = 'production',
  });

  static const fromEnvironment = LogUploadConfig(
    endpoint: String.fromEnvironment('KO_LOGS_ENDPOINT'),
    token: String.fromEnvironment('KO_LOGS_TOKEN'),
    environment: String.fromEnvironment(
      'KO_LOGS_ENVIRONMENT',
      defaultValue: 'production',
    ),
  );

  final String endpoint;
  final String token;
  final String environment;

  bool get enabled => endpoint.isNotEmpty && token.isNotEmpty;

  /// `<endpoint>/v1/logs`, unless the endpoint already is the logs path.
  Uri get logsUri {
    var e = endpoint.trim();
    while (e.endsWith('/')) {
      e = e.substring(0, e.length - 1);
    }
    return Uri.parse(e.endsWith('/v1/logs') ? e : '$e/v1/logs');
  }
}

/// Minimal OTLP/HTTP JSON encoding of logs (no OpenTelemetry SDK).
abstract class OtlpJson {
  static const scopeName = 'kitchenowl.applog';

  static Map<String, Object?> anyValue(Object? v) => switch (v) {
    bool b => {'boolValue': b},
    // int64 is a string in the protobuf JSON mapping.
    int i => {'intValue': i.toString()},
    double d => {'doubleValue': d},
    String s => {'stringValue': s},
    null => {'stringValue': ''},
    Map() || List() => {'stringValue': jsonEncode(v)},
    _ => {'stringValue': v.toString()},
  };

  static List<Map<String, Object?>> attributes(Map<String, Object?> map) => [
    for (final e in map.entries) {'key': e.key, 'value': anyValue(e.value)},
  ];

  static String encodeRecord(
    LogRecord r, {
    Map<String, Object?> extra = const {},
  }) {
    final nanos = '${r.timeMs}000000';
    return jsonEncode({
      'timeUnixNano': nanos,
      'observedTimeUnixNano': nanos,
      'severityNumber': r.level.severityNumber,
      'severityText': r.level.severityText,
      'body': {'stringValue': r.message},
      'attributes': attributes({
        if (r.source != null) 'log.source': r.source,
        ...r.fields,
        if (r.errorType != null) 'exception.type': r.errorType,
        if (r.errorMessage != null) 'exception.message': r.errorMessage,
        if (r.stack != null) 'exception.stacktrace': r.stack,
        ...extra,
      }),
    });
  }

  static String head(Map<String, Object?> resource) =>
      '{"resourceLogs":[{"resource":{"attributes":'
      '${jsonEncode(attributes(resource))}},'
      '"scopeLogs":[{"scope":{"name":"$scopeName"},"logRecords":[';

  static const tail = ']}]}]}';

  static String body(Map<String, Object?> resource, List<String> records) =>
      '${head(resource)}${records.join(',')}$tail';
}

/// A position in the phone's log files: generation and byte offset in it.
@immutable
class LogPosition {
  const LogPosition(this.gen, this.offset);

  final int gen;
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is LogPosition && other.gen == gen && other.offset == offset;

  @override
  int get hashCode => Object.hash(gen, offset);

  @override
  String toString() => 'LogPosition($gen, $offset)';
}

/// Records for one request, and where the stream stands once it is accepted.
class LogChunk<P> {
  LogChunk(this.end);

  final List<String> records = [];
  P end;
  int bytes = 0;
}

/// Complete lines of [bytes] (which start at file offset [baseOffset]), each with the file
/// offset just after its newline. A last line without newline is still being written: left out.
List<(String, int)> completeLines(Uint8List bytes, int baseOffset) {
  final out = <(String, int)>[];
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != 0x0A) continue;
    if (i > start) {
      final line = utf8.decode(
        Uint8List.sublistView(bytes, start, i),
        allowMalformed: true,
      );
      if (line.trim().isNotEmpty) out.add((line, baseOffset + i + 1));
    }
    start = i + 1;
  }
  return out;
}

/// Groups encoded records into requests whose body stays under [maxBytes] (before gzip);
/// [overhead] is the size of the envelope around the records.
List<LogChunk<P>> buildChunks<P>(
  Iterable<(String, P)> encoded, {
  required int maxBytes,
  required int overhead,
}) {
  final chunks = <LogChunk<P>>[];
  LogChunk<P>? current;
  for (final (record, end) in encoded) {
    final size = utf8.encode(record).length + 1; // + the comma
    if (current == null ||
        (current.records.isNotEmpty &&
            overhead + current.bytes + size > maxBytes)) {
      current = LogChunk<P>(end);
      chunks.add(current);
    }
    current.records.add(record);
    current.bytes += size;
    current.end = end;
  }
  return chunks;
}

/// What the uploader remembers between runs (`upload-state.json`, written under the lock).
class UploadState {
  UploadState({
    this.position,
    this.lastSuccessMs,
    this.lastAttemptMs,
    this.lastStatus,
    Map<String, int>? inbox,
  }) : inbox = inbox ?? {};

  /// First byte not yet accepted by the collector.
  LogPosition? position;
  int? lastSuccessMs;
  int? lastAttemptMs;
  String? lastStatus;

  /// Per inbox (e.g. the watch's lines): offset reached in its `.sending` file.
  final Map<String, int> inbox;

  Map<String, Object?> toJson() => {
    if (position != null) 'gen': position!.gen,
    if (position != null) 'offset': position!.offset,
    if (lastSuccessMs != null) 'lastSuccessMs': lastSuccessMs,
    if (lastAttemptMs != null) 'lastAttemptMs': lastAttemptMs,
    if (lastStatus != null) 'lastStatus': lastStatus,
    if (inbox.isNotEmpty) 'inbox': inbox,
  };

  static UploadState fromJson(Map<String, dynamic> json) => UploadState(
    position: json['gen'] is int && json['offset'] is int
        ? LogPosition(json['gen'] as int, json['offset'] as int)
        : null,
    lastSuccessMs: json['lastSuccessMs'] as int?,
    lastAttemptMs: json['lastAttemptMs'] as int?,
    lastStatus: json['lastStatus'] as String?,
    inbox: (json['inbox'] as Map?)?.cast<String, int>(),
  );
}

class UploadResult {
  const UploadResult({
    required this.ok,
    this.skipped = false,
    this.records = 0,
    this.status,
    this.uploadId,
  });

  final bool ok;

  /// Nothing was attempted (not due, disabled, another engine is sending).
  final bool skipped;
  final int records;
  final String? status;
  final String? uploadId;

  @override
  String toString() =>
      'UploadResult(ok: $ok, skipped: $skipped, records: $records, status: $status)';
}

/// Extra facts for the summary record of a manual upload. Features register theirs (the
/// watch, the widget, the calendar); each returns flat key/values, prefixed with its name.
typedef DiagnosticsProvider = Future<Map<String, Object?>> Function();

/// Runs before a manual upload, e.g. asks the watch for its logs and waits for them.
/// Gets the upload id; returns facts for the summary.
typedef BeforeManualUpload = Future<Map<String, Object?>> Function(
  String uploadId,
);

abstract class AppDiagnostics {
  static final _providers = <String, DiagnosticsProvider>{};
  static final _before = <String, BeforeManualUpload>{};

  static void register(String name, DiagnosticsProvider provider) =>
      _providers[name] = provider;

  static void registerBeforeManualUpload(
    String name,
    BeforeManualUpload hook,
  ) => _before[name] = hook;

  static Future<Map<String, Object?>> _run(
    Map<String, Future<Map<String, Object?>> Function()> calls,
    Duration timeout,
  ) async {
    final out = <String, Object?>{};
    await Future.wait(
      calls.entries.map((e) async {
        try {
          final values = await e.value().timeout(timeout);
          values.forEach((k, v) => out['${e.key}.$k'] = v);
        } catch (err) {
          out['${e.key}.error'] = err.toString();
        }
      }),
    );
    return out;
  }

  static Future<Map<String, Object?>> beforeManualUpload(String uploadId) =>
      _run({
        for (final e in _before.entries) e.key: () => e.value(uploadId),
      }, const Duration(seconds: 15));

  static Future<Map<String, Object?>> collect() =>
      _run({..._providers, ..._core}, const Duration(seconds: 5));

  static const _system = MethodChannel('com.tombursch.kitchenowl/diagnostics');

  static final Map<String, DiagnosticsProvider> _core = {
    'app': () async {
      final info = await PackageInfo.fromPlatform();
      return {'version': info.version, 'build': info.buildNumber};
    },
    'system': () async {
      final map = await _system.invokeMapMethod<String, Object?>('snapshot');
      return map ?? const {};
    },
    'background_fetch': () async {
      final last = AppLog.lastMark('background_fetch');
      return {'last_run': last?.toIso8601String() ?? 'never'};
    },
    'logs': () async {
      final dir = AppLog.directory;
      final state = dir == null ? null : AppLogUploader.readState(dir);
      return {
        'bytes': AppLog.store?.totalBytes ?? 0,
        'last_upload': state?.lastSuccessMs == null
            ? 'never'
            : DateTime.fromMillisecondsSinceEpoch(state!.lastSuccessMs!)
                  .toIso8601String(),
        if (state?.lastStatus != null) 'last_status': state!.lastStatus,
      };
    },
  };
}

/// Sends the log files to an OpenTelemetry collector (OTLP/HTTP, JSON + gzip), fork only.
///
/// Battery first: it never wakes the phone itself. The existing background fetch calls
/// [maybeUpload], which sends at most every [interval] (sooner once after an error), only
/// what is new since the last accepted request, in requests of at most [maxBodyBytes].
/// The position only moves when the collector answers 2xx.
///
/// Besides the phone's files it sends the inboxes `inbox-<service>.jsonl` that native code
/// fills (the watch's lines, relayed over the Data Layer) under their own `service.name`.
class AppLogUploader {
  AppLogUploader({
    required this.dir,
    required this.config,
    required this.resource,
    http.Client Function()? client,
    DateTime Function()? now,
    this.inboxSettle = const Duration(milliseconds: 300),
  }) : _client = client ?? http.Client.new,
       _now = now ?? DateTime.now;

  static const interval = Duration(hours: 6);
  static const retryAfterFailure = Duration(hours: 1);
  static const maxBodyBytes = 1024 * 1024;
  static const maxRequestsPerRun = 8;
  static const _lockStale = Duration(minutes: 3);

  final Directory dir;
  final LogUploadConfig config;

  /// Resource attributes of the phone's own records.
  final Future<Map<String, Object?>> Function() resource;
  final http.Client Function() _client;
  final DateTime Function() _now;

  /// Wait after taking an inbox, so a native write that already opened it lands first.
  final Duration inboxSettle;

  static final _inboxName = RegExp(r'^inbox-(.+)\.jsonl$');

  /// The uploader of this engine, or null when logs are off (web, no config, no init).
  static AppLogUploader? get shared {
    final dir = AppLog.directory;
    const config = LogUploadConfig.fromEnvironment;
    if (dir == null || !config.enabled) return null;
    return _shared ??= AppLogUploader(
      dir: dir,
      config: config,
      resource: () => _phoneResource(config),
    );
  }

  static AppLogUploader? _shared;

  static bool get isConfigured =>
      AppLog.isSupported && LogUploadConfig.fromEnvironment.enabled;

  /// Called by the background fetch (UI and headless). Never throws.
  static Future<UploadResult> maybeUpload() async {
    final uploader = shared;
    if (uploader == null) {
      return const UploadResult(ok: false, skipped: true, status: 'disabled');
    }
    try {
      return await uploader.run();
    } catch (e, st) {
      AppLog.warn('Log upload failed', error: e, stack: st);
      return UploadResult(ok: false, status: e.toString());
    }
  }

  /// The "Send logs" button: asks the features for their facts (the watch for its logs),
  /// writes a summary record and sends everything new right away, tagged with a short
  /// `upload.id` to find it in Loki.
  static Future<UploadResult> sendNow() async {
    final uploader = shared;
    if (uploader == null) {
      return const UploadResult(ok: false, status: 'disabled');
    }
    final id = newUploadId();
    try {
      final before = await AppDiagnostics.beforeManualUpload(id);
      final facts = await AppDiagnostics.collect();
      AppLog.info(
        'Diagnostics summary',
        fields: {'upload.id': id, ...facts, ...before},
      );
      await AppLog.flush();
      final result = await uploader.run(force: true, extra: {'upload.id': id});
      return UploadResult(
        ok: result.ok,
        records: result.records,
        status: result.status,
        uploadId: id,
      );
    } catch (e, st) {
      AppLog.warn('Manual log upload failed', error: e, stack: st);
      return UploadResult(ok: false, status: e.toString(), uploadId: id);
    }
  }

  static String newUploadId() {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }

  static File _stateFile(Directory dir) =>
      File('${dir.path}/upload-state.json');

  static UploadState readState(Directory dir) {
    try {
      final json = jsonDecode(_stateFile(dir).readAsStringSync());
      if (json is Map<String, dynamic>) return UploadState.fromJson(json);
    } catch (_) {
      // first run, or a broken file: start over
    }
    return UploadState();
  }

  void _writeState(UploadState state) {
    final file = _stateFile(dir);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(state.toJson()));
    tmp.renameSync(file.path);
  }

  File get _urgentFlag => File('${dir.path}/upload-urgent');

  /// Written by native code when the watch's "Send logs" button asks for an upload now.
  File get _nowFlag => File('${dir.path}/upload-now');

  File get _lock => File('${dir.path}/upload.lock');

  bool _takeLock() {
    try {
      _lock.createSync(exclusive: true);
      return true;
    } on FileSystemException {
      try {
        final age = _now().difference(_lock.lastModifiedSync());
        if (age > _lockStale) {
          _lock.deleteSync();
          _lock.createSync(exclusive: true);
          return true;
        }
      } on FileSystemException {
        // lost a race with another engine
      }
      return false;
    }
  }

  void _releaseLock() {
    try {
      _lock.deleteSync();
    } on FileSystemException {
      // already gone
    }
  }

  /// One upload run. [force] skips the interval (the button); [extra] goes on every record.
  Future<UploadResult> run({
    bool force = false,
    Map<String, Object?> extra = const {},
  }) async {
    final start = _now();
    var state = readState(dir);
    final flagged = _urgentFlag.existsSync() || _nowFlag.existsSync();
    if (!force) {
      final last = state.lastSuccessMs;
      final failedRecently =
          state.lastAttemptMs != null &&
          state.lastAttemptMs != state.lastSuccessMs &&
          start.millisecondsSinceEpoch - state.lastAttemptMs! <
              retryAfterFailure.inMilliseconds;
      final due =
          last == null ||
          start.millisecondsSinceEpoch - last >= interval.inMilliseconds;
      if (failedRecently || !(due || flagged)) {
        return const UploadResult(ok: true, skipped: true, status: 'not due');
      }
    }
    if (!_takeLock()) {
      return const UploadResult(ok: false, skipped: true, status: 'busy');
    }
    final client = _client();
    var sent = 0;
    var requests = 0;
    String? failure;
    try {
      // Re-read under the lock: another engine may have just sent.
      state = readState(dir);
      state.lastAttemptMs = start.millisecondsSinceEpoch;

      final phone = await resource();
      final (n1, r1, f1) = await _sendPhone(
        client,
        state,
        phone,
        extra,
        requests,
      );
      sent += n1;
      requests = r1;
      failure = f1;

      if (failure == null) {
        for (final name in _inboxes()) {
          final (n, r, f) = await _sendInbox(
            client,
            state,
            name,
            extra,
            requests,
          );
          sent += n;
          requests = r;
          failure = f;
          if (failure != null) break;
        }
      }

      if (failure == null) {
        state.lastSuccessMs = start.millisecondsSinceEpoch;
        state.lastAttemptMs = state.lastSuccessMs;
        state.lastStatus = 'ok';
        for (final flag in [_urgentFlag, _nowFlag]) {
          try {
            // Not a flag set while we were sending: that one is for the next run.
            if (!flag.lastModifiedSync().isAfter(start)) flag.deleteSync();
          } on FileSystemException {
            // not there
          }
        }
      } else {
        state.lastStatus = failure;
      }
      _writeState(state);
    } finally {
      client.close();
      _releaseLock();
    }
    return UploadResult(ok: failure == null, records: sent, status: failure);
  }

  Iterable<(String, LogPosition)> _phoneLines(UploadState state) sync* {
    final store = LogFileStore(dir);
    final gens = store.generations();
    if (gens.isEmpty) return;
    var start = state.position ?? LogPosition(gens.first.$1, 0);
    if (!gens.any((g) => g.$1 == start.gen)) {
      // Its file was rotated away (or the files started over): the oldest one left.
      final newer = gens.where((g) => g.$1 > start.gen);
      start = LogPosition(newer.isEmpty ? gens.first.$1 : newer.first.$1, 0);
    }
    for (final (gen, file) in gens) {
      if (gen < start.gen) continue;
      var offset = gen == start.gen ? start.offset : 0;
      var bytes = _readFrom(file, offset);
      if (bytes == null) {
        // Shorter than our position: the file was replaced. Read it whole.
        offset = 0;
        bytes = _readFrom(file, 0)!;
      }
      for (final (line, end) in completeLines(bytes, offset)) {
        yield (line, LogPosition(gen, end));
      }
    }
  }

  /// The bytes of [file] from [offset] on; null when the file is shorter than that.
  static Uint8List? _readFrom(File file, int offset) {
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      if (offset > length) return null;
      raf.setPositionSync(offset);
      return raf.readSync(length - offset);
    } finally {
      raf.closeSync();
    }
  }

  Future<(int, int, String?)> _sendPhone(
    http.Client client,
    UploadState state,
    Map<String, Object?> resource,
    Map<String, Object?> extra,
    int requests,
  ) async {
    final encoded = _phoneLines(state).map(
      (e) => (OtlpJson.encodeRecord(LogRecord.parse(e.$1), extra: extra), e.$2),
    );
    final head = OtlpJson.head(resource);
    final chunks = buildChunks(
      encoded,
      maxBytes: maxBodyBytes,
      overhead: utf8.encode(head).length + OtlpJson.tail.length,
    );
    var sent = 0;
    for (final chunk in chunks) {
      if (requests >= maxRequestsPerRun) break;
      requests++;
      final failure = await _post(client, head, chunk.records);
      if (failure != null) return (sent, requests, failure);
      sent += chunk.records.length;
      state.position = chunk.end;
      _writeState(state);
    }
    return (sent, requests, null);
  }

  Iterable<String> _inboxes() sync* {
    final names = <String>{};
    for (final e in dir.listSync()) {
      final name = e.uri.pathSegments.last;
      final m = _inboxName.firstMatch(name);
      if (m != null) names.add(m[1]!.replaceAll(RegExp(r'\.sending$'), ''));
    }
    yield* names;
  }

  File _inboxFile(String name) => File('${dir.path}/inbox-$name.jsonl');

  File _sendingFile(String name) =>
      File('${dir.path}/inbox-$name.sending.jsonl');

  Map<String, Object?> _inboxResource(String name) {
    final out = <String, Object?>{'service.name': name};
    try {
      final json = jsonDecode(
        File('${dir.path}/inbox-$name.resource.json').readAsStringSync(),
      );
      if (json is Map) out.addAll(json.cast<String, Object?>());
    } catch (_) {
      // no resource file: just the name
    }
    out['deployment.environment'] = config.environment;
    return out;
  }

  /// Sends one inbox: it is renamed to `.sending` first, so the native side starts a new
  /// file meanwhile; the offset in `.sending` moves with each accepted request.
  Future<(int, int, String?)> _sendInbox(
    http.Client client,
    UploadState state,
    String name,
    Map<String, Object?> extra,
    int requests,
  ) async {
    final sending = _sendingFile(name);
    if (!sending.existsSync()) {
      final inbox = _inboxFile(name);
      if (!inbox.existsSync()) return (0, requests, null);
      inbox.renameSync(sending.path);
      state.inbox[name] = 0;
      _writeState(state);
      await Future<void>.delayed(inboxSettle);
    }
    final offset = state.inbox[name] ?? 0;
    final bytes = _readFrom(sending, offset) ?? Uint8List(0);
    final head = OtlpJson.head(_inboxResource(name));
    final chunks = buildChunks(
      completeLines(bytes, offset).map(
        (e) =>
            (OtlpJson.encodeRecord(LogRecord.parse(e.$1), extra: extra), e.$2),
      ),
      maxBytes: maxBodyBytes,
      overhead: utf8.encode(head).length + OtlpJson.tail.length,
    );
    var sent = 0;
    for (final chunk in chunks) {
      if (requests >= maxRequestsPerRun) {
        return (sent, requests, null);
      }
      requests++;
      final failure = await _post(client, head, chunk.records);
      if (failure != null) return (sent, requests, failure);
      sent += chunk.records.length;
      state.inbox[name] = chunk.end;
      _writeState(state);
    }
    // All of it accepted.
    sending.deleteSync();
    state.inbox.remove(name);
    _writeState(state);
    return (sent, requests, null);
  }

  /// Null when the collector accepted the request, else a short reason.
  Future<String?> _post(
    http.Client client,
    String head,
    List<String> records,
  ) async {
    final body = gzip.encode(
      utf8.encode('$head${records.join(',')}${OtlpJson.tail}'),
    );
    try {
      final response = await client
          .post(
            config.logsUri,
            headers: {
              'Content-Type': 'application/json',
              'Content-Encoding': 'gzip',
              'Authorization': 'Bearer ${config.token}',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      return 'HTTP ${response.statusCode}';
    } catch (e) {
      return LogRedactor.redact(e.toString());
    }
  }

  static Future<Map<String, Object?>> _phoneResource(
    LogUploadConfig config,
  ) async {
    final out = <String, Object?>{
      'service.name': 'kitchenowl-android',
      'deployment.environment': config.environment,
      'os.name': 'Android',
    };
    try {
      final info = await PackageInfo.fromPlatform();
      out['service.version'] = info.version;
      out['app.build'] = info.buildNumber;
    } catch (_) {
      // unknown version: still worth sending
    }
    try {
      final device = await DeviceInfoPlugin().androidInfo;
      out['device.model.name'] = device.model;
      out['device.manufacturer'] = device.manufacturer;
      out['os.version'] = device.version.release;
    } catch (_) {
      // not Android, or the plugin is missing in this engine
    }
    return out;
  }
}
