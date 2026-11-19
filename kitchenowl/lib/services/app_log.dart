import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel {
  debug(5, 'DEBUG'),
  info(9, 'INFO'),
  warn(13, 'WARN'),
  error(17, 'ERROR');

  const LogLevel(this.severityNumber, this.severityText);

  /// OpenTelemetry severity number of the level's range start.
  final int severityNumber;
  final String severityText;

  static LogLevel parse(String? name) => LogLevel.values.firstWhere(
    (l) => l.name == name,
    orElse: () => LogLevel.info,
  );
}

/// One line of the log file (JSON lines). Short keys: the file is small on purpose.
class LogRecord {
  const LogRecord({
    required this.timeMs,
    required this.level,
    required this.message,
    this.source,
    this.fields = const {},
    this.errorType,
    this.errorMessage,
    this.stack,
  });

  final int timeMs;
  final LogLevel level;
  final String message;

  /// Which engine wrote it: `ui`, `bg` (background fetch), `wear` (watch worker), ...
  final String? source;
  final Map<String, Object?> fields;
  final String? errorType;
  final String? errorMessage;
  final String? stack;

  Map<String, Object?> toJson() => {
    't': timeMs,
    'l': level.name,
    'm': message,
    if (source != null) 'src': source,
    if (fields.isNotEmpty) 'f': fields,
    if (errorType != null) 'et': errorType,
    if (errorMessage != null) 'e': errorMessage,
    if (stack != null) 'st': stack,
  };

  String encode() => jsonEncode(toJson());

  /// Parses a line of the file; a line that is not ours becomes an info record with its text.
  static LogRecord parse(String line, {int? fallbackTimeMs}) {
    try {
      final json = jsonDecode(line);
      if (json is Map<String, dynamic> && json['t'] is int) {
        final f = json['f'];
        return LogRecord(
          timeMs: json['t'] as int,
          level: LogLevel.parse(json['l'] as String?),
          message: json['m']?.toString() ?? '',
          source: json['src'] as String?,
          fields: f is Map ? f.cast<String, Object?>() : const {},
          errorType: json['et'] as String?,
          errorMessage: json['e'] as String?,
          stack: json['st'] as String?,
        );
      }
    } catch (_) {
      // not JSON: kept as text below
    }
    return LogRecord(
      timeMs: fallbackTimeMs ?? DateTime.now().millisecondsSinceEpoch,
      level: LogLevel.info,
      message: line,
    );
  }
}

/// Masks credentials before anything reaches the file: JWTs, `Bearer` headers and
/// `password` / `token` values. Logging code must not pass them in the first place; this is
/// the safety net (an exception text may quote a header or a request).
class LogRedactor {
  static final _jwt = RegExp(
    r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*',
  );
  static final _bearer = RegExp(
    r'(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _secretValue = RegExp(
    r'''(["']?(?:password|passwd|token|refresh_token|access_token|secret|authorization)["']?\s*[:=]\s*)(["']?)[^"'&,\s}]+''',
    caseSensitive: false,
  );

  static String redact(String text) => text
      .replaceAll(_jwt, '<jwt>')
      .replaceAllMapped(_bearer, (m) => '${m[1]} <redacted>')
      .replaceAllMapped(_secretValue, (m) => '${m[1]}${m[2]}<redacted>');

  static final _secretKey = RegExp(
    r'password|passwd|token|secret|authorization|cookie',
    caseSensitive: false,
  );

  /// A field value, masked entirely when its key names a credential.
  static Object? redactField(String key, Object? value) =>
      _secretKey.hasMatch(key) ? '<redacted>' : redactValue(value);

  static Object? redactValue(Object? value) => switch (value) {
    String s => redact(s),
    num() || bool() || null => value,
    _ => redact(value.toString()),
  };
}

/// The log files: `app-<generation>.log`, JSON lines, a new generation when the current one
/// passes [maxFileBytes], at most [keepFiles] kept. Several engines (UI, background fetch,
/// watch worker) append to it in the same process: each append opens, writes and closes the
/// file, and a writer that finds its file full looks for a newer generation first.
class LogFileStore {
  LogFileStore(this.dir, {this.maxFileBytes = 1024 * 1024, this.keepFiles = 2});

  final Directory dir;
  final int maxFileBytes;
  final int keepFiles;

  static final _name = RegExp(r'^app-(\d+)\.log$');

  int? _gen;

  File fileFor(int gen) => File('${dir.path}/app-$gen.log');

  /// Existing generations, oldest first.
  List<(int, File)> generations() {
    if (!dir.existsSync()) return const [];
    final out = <(int, File)>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final m = _name.firstMatch(e.uri.pathSegments.last);
      if (m != null) out.add((int.parse(m[1]!), e));
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  int? _newest() {
    final g = generations();
    return g.isEmpty ? null : g.last.$1;
  }

  static int _length(File f) {
    try {
      return f.lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  void append(String text) {
    var gen = _gen ??= _newest() ?? 0;
    if (_length(fileFor(gen)) >= maxFileBytes) {
      while (_length(fileFor(gen)) >= maxFileBytes) {
        final newest = _newest() ?? gen;
        gen = newest > gen ? newest : gen + 1;
      }
      for (final (g, f) in generations()) {
        if (g <= gen - keepFiles) {
          try {
            f.deleteSync();
          } on FileSystemException {
            // another engine deleted it first
          }
        }
      }
    }
    _gen = gen;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    fileFor(gen).writeAsStringSync(text, mode: FileMode.append);
  }

  int get totalBytes => generations().fold(0, (sum, g) => sum + _length(g.$2));
}

/// The app's own log: a small rotating file in the app's directory (2 × 1 MB), sent in
/// batches by [AppLogUploader] (fork only). Works in the UI engine and in headless engines
/// (background fetch, watch worker): call [init] at the start of each.
///
/// Never pass tokens, passwords or request bodies; [LogRedactor] masks the obvious ones.
class AppLog {
  static const _maxMessage = 4000;
  static const _maxStack = 6000;
  static const _maxBuffered = 500;

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static LogFileStore? _store;
  static Directory? _dir;
  static String _source = 'ui';
  static Future<void>? _init;
  static final _buffer = <String>[];
  static Future<void> _chain = Future.value();
  static bool _scheduled = false;
  static bool _suppressCapture = false;
  static bool _handlersInstalled = false;
  static DebugPrintCallback _console = debugPrint;

  /// The log directory, once [init] has run.
  static Directory? get directory => _dir;

  static LogFileStore? get store => _store;

  /// Opens the log directory for this engine. [source] tags every line it writes.
  /// [directory] is for tests. Safe to call more than once.
  static Future<void> init({String source = 'ui', Directory? directory}) {
    _source = source;
    if (!isSupported && directory == null) return Future.value();
    return _init ??= () async {
      try {
        final base = directory ?? await getApplicationSupportDirectory();
        final dir = directory ?? Directory('${base.path}/logs');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _dir = dir;
        _store = LogFileStore(dir);
        _schedule();
      } catch (e) {
        _console('[AppLog] no log directory: $e');
      }
    }();
  }

  /// Captures `debugPrint`, [FlutterError.onError] and [PlatformDispatcher.onError].
  /// They still reach logcat as before.
  static void installGlobalHandlers() {
    if (_handlersInstalled || !isSupported) return;
    _handlersInstalled = true;

    final original = debugPrint;
    _console = original;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth);
      if (message != null && !_suppressCapture) {
        _write(LogLevel.debug, message, toConsole: false);
      }
    };

    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      _write(
        LogLevel.error,
        'Flutter error${details.library != null ? ' in ${details.library}' : ''}',
        error: details.exception,
        stack: details.stack,
        fields: {
          if (details.context != null) 'context': details.context.toString(),
        },
        toConsole: false,
      );
      // presentError prints the long report through debugPrint: not twice in the file.
      _suppressCapture = true;
      try {
        (previousFlutter ?? FlutterError.presentError)(details);
      } finally {
        _suppressCapture = false;
      }
    };

    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _write(LogLevel.error, 'Uncaught error', error: error, stack: stack);
      // false = not handled: the engine still prints it to logcat.
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  static void debug(String message, {Map<String, Object?>? fields}) =>
      _write(LogLevel.debug, message, fields: fields, toConsole: false);

  static void info(String message, {Map<String, Object?>? fields}) =>
      _write(LogLevel.info, message, fields: fields);

  static void warn(
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) => _write(
    LogLevel.warn,
    message,
    error: error,
    stack: stack,
    fields: fields,
  );

  static void error(
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) => _write(
    LogLevel.error,
    message,
    error: error,
    stack: stack,
    fields: fields,
  );

  /// A cache file could not be read, written or deleted. A missing file is just an empty
  /// cache (debug); anything else (bad JSON, I/O) is a warning.
  static void storageFailure(String operation, Object e, StackTrace st) =>
      _write(
        e is PathNotFoundException ? LogLevel.debug : LogLevel.warn,
        'Storage: $operation failed',
        error: e,
        stack: e is PathNotFoundException ? null : st,
        toConsole: e is! PathNotFoundException,
      );

  /// Remembers when [name] last happened (e.g. `background_fetch`), across engines.
  static Future<void> mark(String name) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await File('${dir.path}/mark-$name')
          .writeAsString('${DateTime.now().millisecondsSinceEpoch}');
    } catch (_) {
      // a missing mark only makes the diagnostics poorer
    }
  }

  static DateTime? lastMark(String name) {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final ms = int.tryParse(
        File('${dir.path}/mark-$name').readAsStringSync(),
      );
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Completes once every line written so far is in the file.
  static Future<void> flush() => _chain;

  /// An error since the last upload: the next background run sends the logs even if the
  /// usual interval has not passed (one send, never one per error).
  static File? get urgentFlag =>
      _dir == null ? null : File('${_dir!.path}/upload-urgent');

  static void _write(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
    bool toConsole = true,
  }) {
    if (!isSupported && _dir == null) return;
    try {
      final record = LogRecord(
        timeMs: DateTime.now().millisecondsSinceEpoch,
        level: level,
        message: _cut(LogRedactor.redact(message), _maxMessage),
        source: _source,
        fields: {
          for (final e in (fields ?? const <String, Object?>{}).entries)
            e.key: LogRedactor.redactField(e.key, e.value),
        },
        errorType: error?.runtimeType.toString(),
        errorMessage: error == null
            ? null
            : _cut(LogRedactor.redact(error.toString()), _maxMessage),
        stack: stack == null
            ? null
            : _cut(LogRedactor.redact(stack.toString()), _maxStack),
      );
      if (toConsole) {
        _suppressCapture = true;
        try {
          _console(
            '[${level.severityText}] ${record.message}'
            '${error != null ? ': ${record.errorMessage}' : ''}',
          );
        } finally {
          _suppressCapture = false;
        }
      }
      if (_buffer.length >= _maxBuffered) _buffer.removeAt(0);
      _buffer.add('${record.encode()}\n');
      if (level == LogLevel.error) _markUrgent = true;
      _schedule();
    } catch (_) {
      // logging must never break the app
    }
  }

  static bool _markUrgent = false;

  static void _schedule() {
    final store = _store;
    if (store == null || _scheduled || _buffer.isEmpty) return;
    _scheduled = true;
    _chain = _chain.then((_) async {
      // Lets a burst of lines go out in one append.
      await Future<void>.delayed(Duration.zero);
      _scheduled = false;
      if (_buffer.isEmpty) return;
      final text = _buffer.join();
      _buffer.clear();
      final urgent = _markUrgent;
      _markUrgent = false;
      try {
        store.append(text);
        if (urgent) {
          final flag = urgentFlag;
          if (flag != null && !flag.existsSync()) flag.createSync();
        }
      } catch (e) {
        _console('[AppLog] write failed: $e');
      }
    });
  }

  static String _cut(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  @visibleForTesting
  static Future<void> resetForTest() async {
    await _chain;
    _store = null;
    _dir = null;
    _init = null;
    _buffer.clear();
    _scheduled = false;
    _markUrgent = false;
    _source = 'ui';
  }
}
