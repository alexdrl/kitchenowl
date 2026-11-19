import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:kitchenowl/services/app_log_upload.dart';

const _config = LogUploadConfig(
  endpoint: 'https://otel.example.test/',
  token: 'secret-token',
  environment: 'test',
);

/// Recent enough for Loki (records older than 6 days are not sent).
final _base = DateTime.now().millisecondsSinceEpoch;

String _line(int i, {String level = 'info', String msg = 'm', int? at}) =>
    '${jsonEncode({'t': (at ?? _base) + i, 'l': level, 'm': '$msg$i'})}\n';

/// A collector double: records every request and answers with [status] (or per call).
class _Collector {
  _Collector([this.status = 200]);

  int status;
  final requests = <http.Request>[];

  List<Map<String, dynamic>> get bodies => requests
      .map(
        (r) =>
            jsonDecode(utf8.decode(gzip.decode(r.bodyBytes)))
                as Map<String, dynamic>,
      )
      .toList();

  List<Map<String, dynamic>> get records => [
    for (final body in bodies)
      for (final rl in body['resourceLogs'] as List)
        for (final sl in rl['scopeLogs'] as List)
          ...(sl['logRecords'] as List).cast<Map<String, dynamic>>(),
  ];

  http.Client client() => MockClient((request) async {
    requests.add(request);
    return http.Response('{}', status);
  });
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('applog'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppLogUploader uploader(_Collector c, {DateTime? now}) => AppLogUploader(
    dir: dir,
    config: _config,
    resource: () async => {
      'service.name': 'kitchenowl-android',
      'service.version': '0.8.1-fork.16',
    },
    client: c.client,
    now: now == null ? null : () => now,
    inboxSettle: Duration.zero,
  );

  group('config', () {
    test('logs path is appended once', () {
      expect(_config.logsUri.toString(), 'https://otel.example.test/v1/logs');
      const full = LogUploadConfig(
        endpoint: 'https://otel.example.test/v1/logs',
        token: 't',
      );
      expect(full.logsUri.toString(), 'https://otel.example.test/v1/logs');
      expect(const LogUploadConfig(endpoint: '', token: 't').enabled, isFalse);
    });
  });

  test('upload ids are 6 unambiguous characters; the instance id is kept', () {
    for (var i = 0; i < 50; i++) {
      expect(
        AppLogUploader.newUploadId(),
        matches(RegExp(r'^[abcdefghjkmnpqrstuvwxyz23456789]{6}$')),
      );
    }
    final id = AppLogUploader.instanceId(dir);
    expect(id, hasLength(32));
    expect(AppLogUploader.instanceId(dir), id);
  });

  group('OTLP JSON', () {
    test(
      'a record has nanosecond time, severity, body and typed attributes',
      () {
        final json = jsonDecode(
          OtlpJson.encodeRecord(
            const LogRecord(
              timeMs: 1700000000123,
              level: LogLevel.warn,
              message: 'Storage: readUser failed',
              source: 'bg',
              fields: {'count': 3, 'ok': false, 'ratio': 0.5, 'name': 'x'},
              errorType: 'FormatException',
              errorMessage: 'bad json',
              stack: '#0 main',
            ),
            extra: {'upload.id': 'ab12cd'},
          ),
        ) as Map<String, dynamic>;

        expect(json['timeUnixNano'], '1700000000123000000');
        expect(json['severityNumber'], 13);
        expect(json['severityText'], 'WARN');
        expect(json['body'], {'stringValue': 'Storage: readUser failed'});
        final attrs = {
          for (final a in json['attributes'] as List) a['key']: a['value'],
        };
        expect(attrs['log.source'], {'stringValue': 'bg'});
        expect(attrs['count'], {'intValue': '3'});
        expect(attrs['ok'], {'boolValue': false});
        expect(attrs['ratio'], {'doubleValue': 0.5});
        expect(attrs['exception.type'], {'stringValue': 'FormatException'});
        expect(attrs['exception.message'], {'stringValue': 'bad json'});
        expect(attrs['exception.stacktrace'], {'stringValue': '#0 main'});
        expect(attrs['upload.id'], {'stringValue': 'ab12cd'});
      },
    );

    test('the envelope is valid OTLP with the resource attributes', () {
      final body = jsonDecode(
        OtlpJson.body(
          {'service.name': 'kitchenowl-android'},
          [
            OtlpJson.encodeRecord(
              const LogRecord(timeMs: 1, level: LogLevel.info, message: 'a'),
            ),
          ],
        ),
      ) as Map<String, dynamic>;
      final rl = (body['resourceLogs'] as List).single as Map;
      expect((rl['resource'] as Map)['attributes'], [
        {
          'key': 'service.name',
          'value': {'stringValue': 'kitchenowl-android'},
        },
      ]);
      final sl = (rl['scopeLogs'] as List).single as Map;
      expect((sl['scope'] as Map)['name'], OtlpJson.scopeName);
      expect((sl['logRecords'] as List), hasLength(1));
    });

    test('a line that is not JSON is sent as text', () {
      final r = LogRecord.parse('plain text', fallbackTimeMs: 5);
      expect(r.message, 'plain text');
      expect(r.level, LogLevel.info);
      expect(r.timeMs, 5);
    });
  });

  group('chunking', () {
    test('only complete lines, with the offset after each newline', () {
      final bytes = Uint8List.fromList(utf8.encode('ab\ncd\nef'));
      expect(completeLines(bytes, 100), [('ab', 103), ('cd', 106)]);
    });

    test('multi-byte characters keep byte offsets', () {
      final bytes = Uint8List.fromList(utf8.encode('ñandú\nx\n'));
      expect(completeLines(bytes, 0), [('ñandú', 8), ('x', 10)]);
    });

    test('requests stay under the limit and each ends at its last record', () {
      final items = [for (var i = 0; i < 10; i++) ('x' * 99, i)];
      final chunks = buildChunks(items, maxBytes: 350, overhead: 50);
      // 100 bytes per record (with the comma): 3 per request.
      expect(chunks.map((c) => c.records.length), [3, 3, 3, 1]);
      expect(chunks.map((c) => c.end), [2, 5, 8, 9]);
      for (final c in chunks) {
        expect(c.bytes + 50, lessThanOrEqualTo(350));
      }
    });

    test('a record larger than the limit still goes, alone', () {
      final chunks = buildChunks(
        [('a', 0), ('b' * 500, 1), ('c', 2)],
        maxBytes: 100,
        overhead: 10,
      );
      expect(chunks.map((c) => c.end), [0, 1, 2]);
    });
  });

  group('log files', () {
    test('rotates past the size and keeps two generations', () {
      final store = LogFileStore(dir, maxFileBytes: 100, keepFiles: 2);
      for (var i = 0; i < 12; i++) {
        store.append(_line(i)); // ~50 bytes each
      }
      final gens = store.generations().map((g) => g.$1).toList();
      expect(gens, hasLength(2));
      expect(gens.last, greaterThan(gens.first));
      for (final (_, f) in store.generations()) {
        expect(f.lengthSync(), lessThan(200));
      }
    });

    test('a second writer with a stale generation follows the rotation', () {
      final a = LogFileStore(dir, maxFileBytes: 70);
      final b = LogFileStore(dir, maxFileBytes: 70);
      a.append(_line(0));
      b.append(_line(1));
      a.append(_line(2)); // full: a moves to generation 1
      b.append(_line(3)); // b finds its file full and generation 1 there
      expect(LogFileStore(dir).generations().map((g) => g.$1), [0, 1]);
      expect(
        File('${dir.path}/app-1.log').readAsStringSync(),
        '${_line(2)}${_line(3)}',
      );
    });
  });

  group('upload', () {
    test('sends everything once, then only what is new', () async {
      final store = LogFileStore(dir);
      store.append(_line(1) + _line(2));
      final c = _Collector();

      var r = await uploader(c).run(force: true);
      expect(r.ok, isTrue);
      expect(r.records, 2);
      expect(
        c.requests.single.url.toString(),
        'https://otel.example.test/v1/logs',
      );
      expect(c.requests.single.headers['Authorization'], 'Bearer secret-token');
      expect(c.requests.single.headers['Content-Encoding'], 'gzip');
      final res = (c.bodies.single['resourceLogs'] as List).single;
      expect(
        (res['resource']['attributes'] as List).map((a) => a['key']).toList(),
        containsAll(['service.name', 'service.version']),
      );

      store.append(_line(3) + _line(4).replaceAll('\n', '')); // 4 is partial
      r = await uploader(c).run(force: true);
      expect(r.records, 1);
      expect(c.records.last['body'], {'stringValue': 'm3'});

      // The rest of line 4 arrives.
      store.append('\n');
      r = await uploader(c).run(force: true);
      expect(r.records, 1);
      expect(c.records.last['body'], {'stringValue': 'm4'});
    });

    test('the position only moves on a 2xx', () async {
      LogFileStore(dir).append(_line(1));
      final c = _Collector(401);
      final r = await uploader(c).run(force: true);
      expect(r.ok, isFalse);
      expect(r.status, 'HTTP 401');
      expect(AppLogUploader.readState(dir).position, isNull);

      c.status = 202;
      final again = await uploader(c).run(force: true);
      expect(again.ok, isTrue);
      expect(again.records, 1);
      expect(c.requests, hasLength(2));
      expect(
        AppLogUploader.readState(dir).position,
        LogPosition(0, _line(1).length),
      );
    });

    test('a failure stops before the next request', () async {
      final store = LogFileStore(dir);
      final big = 'x' * 4000;
      for (var i = 0; i < 600; i++) {
        store.append(_line(i, msg: big)); // ~2.4 MB → several requests
      }
      var calls = 0;
      final failing = AppLogUploader(
        dir: dir,
        config: _config,
        resource: () async => {},
        client: () => MockClient((req) async {
          calls++;
          // Every request stays under 1 MB before gzip.
          expect(
            gzip.decode(req.bodyBytes).length,
            lessThanOrEqualTo(AppLogUploader.maxBodyBytes),
          );
          return http.Response('', calls == 1 ? 200 : 503);
        }),
      );
      final r = await failing.run(force: true);
      expect(r.ok, isFalse);
      expect(calls, 2);
      final pos = AppLogUploader.readState(dir).position!;
      expect(pos.offset, greaterThan(0));
      expect(r.records, greaterThan(0));
    });

    test('a rotated-away position restarts at the oldest file left', () async {
      final store = LogFileStore(dir, maxFileBytes: 60, keepFiles: 2);
      store.append(_line(1));
      final c = _Collector();
      await uploader(c).run(force: true);
      for (var i = 2; i < 6; i++) {
        store.append(_line(i)); // rotates generation 0 away
      }
      final r = await uploader(c).run(force: true);
      final oldest = store.generations().first.$1;
      expect(oldest, greaterThan(0));
      expect(r.ok, isTrue);
      expect(c.records.last['body'], {'stringValue': 'm5'});
    });

    test('not due: waits the interval unless an error was logged', () async {
      final now = DateTime(2030, 1, 1, 12);
      LogFileStore(dir).append(_line(1, at: now.millisecondsSinceEpoch));
      final c = _Collector();
      expect((await uploader(c, now: now).run()).ok, isTrue);
      expect(c.requests, hasLength(1));

      LogFileStore(dir).append(_line(2, at: now.millisecondsSinceEpoch));
      final later = now.add(const Duration(hours: 1));
      expect((await uploader(c, now: later).run()).skipped, isTrue);

      // An error since: one early send at the next background run.
      File('${dir.path}/upload-urgent').createSync();
      final r = await uploader(
        c,
        now: later.add(const Duration(minutes: 1)),
      ).run();
      expect(r.skipped, isFalse);
      expect(c.requests, hasLength(2));
      expect(File('${dir.path}/upload-urgent').existsSync(), isFalse);

      LogFileStore(dir).append(_line(3, at: now.millisecondsSinceEpoch));
      final sixHoursLater = later.add(const Duration(hours: 6, minutes: 1));
      expect((await uploader(c, now: sixHoursLater).run()).skipped, isFalse);
    });

    test('after a failure the background retry waits an hour', () async {
      final now = DateTime(2030, 1, 1, 12);
      LogFileStore(dir).append(_line(1, at: now.millisecondsSinceEpoch));
      final c = _Collector(500);
      await uploader(c, now: now).run();
      final r = await uploader(
        c,
        now: now.add(const Duration(minutes: 30)),
      ).run();
      expect(r.skipped, isTrue);
      expect(c.requests, hasLength(1));
    });

    test('records too old for Loki are skipped, and passed', () async {
      final store = LogFileStore(dir);
      final old = DateTime.now()
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      store.append(_line(1, at: old) + _line(2) + _line(3, at: old));
      final c = _Collector();
      final r = await uploader(c).run(force: true);
      expect(r.records, 1);
      expect(c.records.single['body'], {'stringValue': 'm2'});
      // The position is past the old last line: nothing is sent again.
      final again = await uploader(c).run(force: true);
      expect(again.records, 0);
      expect(c.requests, hasLength(1));
    });

    test('extra attributes (upload.id) go on every record', () async {
      LogFileStore(dir).append(_line(1) + _line(2));
      final c = _Collector();
      await uploader(c).run(force: true, extra: {'upload.id': 'ab12cd'});
      for (final r in c.records) {
        expect(
          r['attributes'],
          anyElement(
            equals({
              'key': 'upload.id',
              'value': {'stringValue': 'ab12cd'},
            }),
          ),
        );
      }
    });

    test('an inbox goes under its own service, then is deleted', () async {
      File('${dir.path}/inbox-kitchenowl-wear.jsonl')
          .writeAsStringSync(_line(1, msg: 'watch') + _line(2, msg: 'watch'));
      File('${dir.path}/inbox-kitchenowl-wear.resource.json').writeAsStringSync(
        jsonEncode({
          'service.name': 'kitchenowl-wear',
          'service.version': '0.8.1-fork.16',
          'device.model.name': 'SM-R960',
        }),
      );
      final c = _Collector();
      final r = await uploader(c).run(force: true);
      expect(r.records, 2);
      final res = (c.bodies.single['resourceLogs'] as List).single;
      final attrs = {
        for (final a in res['resource']['attributes'] as List)
          a['key']: a['value']['stringValue'],
      };
      expect(attrs['service.name'], 'kitchenowl-wear');
      expect(attrs['device.model.name'], 'SM-R960');
      expect(attrs['deployment.environment'], 'test');
      expect(
        dir.listSync().map((e) => e.uri.pathSegments.last),
        isNot(contains(startsWith('inbox-kitchenowl-wear.s'))),
      );
      expect(
        File('${dir.path}/inbox-kitchenowl-wear.jsonl').existsSync(),
        isFalse,
      );
    });

    test('a failed inbox is kept and resent, not lost', () async {
      File('${dir.path}/inbox-kitchenowl-wear.jsonl')
          .writeAsStringSync(_line(1, msg: 'watch'));
      final c = _Collector(500);
      await uploader(c).run(force: true);
      expect(
        File('${dir.path}/inbox-kitchenowl-wear.sending.jsonl').existsSync(),
        isTrue,
      );
      // New lines arrive meanwhile in a fresh inbox.
      File('${dir.path}/inbox-kitchenowl-wear.jsonl')
          .writeAsStringSync(_line(2, msg: 'watch'));
      c.status = 200;
      await uploader(c).run(force: true);
      // The .sending file went first; the new inbox waits for the next run.
      expect(c.records.last['body'], {'stringValue': 'watch1'});
      await uploader(c).run(force: true);
      expect(c.records.last['body'], {'stringValue': 'watch2'});
    });

    test('another engine holding the lock: skipped', () async {
      LogFileStore(dir).append(_line(1));
      File('${dir.path}/upload.lock').createSync();
      final c = _Collector();
      final r = await uploader(c).run(force: true);
      expect(r.skipped, isTrue);
      expect(c.requests, isEmpty);
    });
  });

  group('AppLog', () {
    tearDown(AppLog.resetForTest);

    test('writes JSON lines with level, source and redacted secrets', () async {
      await AppLog.init(source: 'bg', directory: dir);
      AppLog.warn(
        'refresh failed for Bearer abc.def',
        error: Exception(
          'token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl',
        ),
        fields: {'password': 'hunter2', 'list': 7},
      );
      AppLog.error('boom');
      await AppLog.flush();

      final text = File('${dir.path}/app-0.log').readAsStringSync();
      expect(text, isNot(contains('hunter2')));
      expect(text, isNot(contains('eyJhbGci')));
      expect(text, isNot(contains('abc.def')));
      final lines = const LineSplitter().convert(text);
      expect(lines, hasLength(2));
      final first = LogRecord.parse(lines.first);
      expect(first.level, LogLevel.warn);
      expect(first.source, 'bg');
      expect(first.fields['list'], 7);
      expect(first.errorType, '_Exception');
      // The error asks for an early upload.
      expect(File('${dir.path}/upload-urgent').existsSync(), isTrue);
    });

    test('a missing cache file is only a debug line', () async {
      await AppLog.init(directory: dir);
      AppLog.storageFailure(
        'readUser',
        const PathNotFoundException('/x', OSError('missing', 2)),
        StackTrace.current,
      );
      AppLog.storageFailure(
        'readUser',
        const FormatException('bad'),
        StackTrace.current,
      );
      await AppLog.flush();
      final lines = const LineSplitter()
          .convert(File('${dir.path}/app-0.log').readAsStringSync())
          .map(LogRecord.parse)
          .toList();
      expect(lines.map((l) => l.level), [LogLevel.debug, LogLevel.warn]);
      expect(File('${dir.path}/upload-urgent').existsSync(), isFalse);
    });
  });
}
