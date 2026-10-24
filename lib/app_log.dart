import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The app version, set by the release build with `--dart-define`.
const appVersion = String.fromEnvironment('LUMTUB_VERSION', defaultValue: '开发版');

/// A small plain-text log in the app's `logs` folder, for diagnosing problems
/// on other people's computers. It stays on this computer and never contains
/// tokens or signed stream addresses.
class AppLog {
  AppLog(this.file, {int size = 0}) : _size = size;
  final File file;

  /// Bytes in [file], counted as lines are appended.
  int _size;

  /// The log of this run; null until [open] succeeds, and logging is then a
  /// no-op.
  static AppLog? current;

  static const maxBytes = 1024 * 1024;

  /// Starts the log, keeping the previous one as `lumtub.old.log` once it
  /// grows past [maxBytes].
  static Future<AppLog?> open(Directory directory) async {
    try {
      await directory.create(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}lumtub.log');
      if (await file.exists() && await file.length() > maxBytes) {
        final previous = File('${directory.path}${Platform.pathSeparator}lumtub.old.log');
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
      }
      return current = AppLog(file, size: await file.exists() ? await file.length() : 0);
    } on FileSystemException {
      return null;
    }
  }

  static const flushDelay = Duration(milliseconds: 200);

  final _pending = StringBuffer();
  Timer? _timer;
  /// Appends run one after another, so lines stay in order.
  Future<void> _writes = Future.value();

  /// Queues a line; lines are written together shortly after, or at once
  /// for errors, without blocking the caller.
  void write(String level, String message) {
    _pending.write('${DateTime.now().toIso8601String()} $level ${redact(message)}\n');
    if (level.trim() == 'ERROR') {
      unawaited(flush());
    } else {
      _timer ??= Timer(flushDelay, () => unawaited(flush()));
    }
  }

  /// Completes once every line written so far is on disk; call it before
  /// the app exits.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isNotEmpty) {
      final text = _pending.toString();
      _pending.clear();
      _writes = _writes.then((_) async {
        try {
          await file.writeAsString(text, mode: FileMode.append, flush: true);
          _size += utf8.encode(text).length;
          // A long session rotates too, not only the next start.
          if (_size > maxBytes) {
            final previous = File('${file.parent.path}${Platform.pathSeparator}lumtub.old.log');
            if (await previous.exists()) await previous.delete();
            await file.rename(previous.path);
            _size = 0;
          }
        } on FileSystemException {
          // A full or locked disk must not break playback.
        }
      });
    }
    return _writes;
  }

  static final _secrets = [
    // OAuth values in queries, forms and JSON.
    RegExp(r'''((?:access_token|refresh_token|id_token|client_secret|code|token)["']?\s*[:=]\s*["']?)[^\s&"',}]+''', caseSensitive: false),
    RegExp(r'(Bearer\s+)\S+', caseSensitive: false),
  ];
  // Stream addresses are signed for one viewer and expire; the host is
  // enough to tell what failed.
  static final _streamUrl = RegExp(r'https?://([\w.-]*googlevideo\.com)/\S*');

  static String redact(String message) {
    var text = message.replaceAllMapped(_streamUrl, (m) => 'https://${m[1]}/…');
    for (final pattern in _secrets) {
      text = text.replaceAllMapped(pattern, (m) => '${m[1]}***');
    }
    return text;
  }
}

void logInfo(String message) => AppLog.current?.write('INFO ', message);

void logError(String message, [Object? error, StackTrace? stack]) => AppLog.current?.write(
      'ERROR',
      [message, if (error != null) '$error', if (stack != null) '$stack'].join('\n'),
    );
