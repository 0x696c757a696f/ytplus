import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'live_chat.dart';
import 'process_priority.dart';
import 'process_runner.dart';
import 'native_core.dart';

/// Fetches the read-only chat replay that yt-dlp exposes as the `live_chat`
/// subtitle track. It shares yt-dlp's component, proxy and disk cache with
/// normal video extraction.
class LiveChatRepository {
  LiveChatRepository(
    this.ytDlpPath, {
    this.cacheDirectory,
    this.deno,
    this.proxy,
    Map<String, String>? environment,
  }) : _environment = environment;

  final String ytDlpPath;
  final String? cacheDirectory;
  final String? deno;
  final String? Function()? proxy;
  final Map<String, String>? _environment;

  Directory get directory => Directory(cacheDirectory == null
      ? '${Directory.systemTemp.path}${Platform.pathSeparator}lumtub-live-chat'
      : '${cacheDirectory!}${Platform.pathSeparator}live-chat');

  File fileFor(String videoId) => File('${directory.path}${Platform.pathSeparator}$videoId.live_chat.json');

  List<String> arguments(String videoId) => [
        '--no-warnings',
        '--skip-download',
        '--no-playlist',
        if (cacheDirectory != null) ...['--cache-dir', cacheDirectory!],
        if (proxy?.call() case final value?) ...['--proxy', value],
        if (deno != null) ...['--js-runtimes', 'deno:$deno'],
        '--write-subs',
        '--sub-langs', 'live_chat',
        '--sub-format', 'json',
        '--output', '${directory.path}${Platform.pathSeparator}%(id)s.%(ext)s',
        '--', 'https://www.youtube.com/watch?v=$videoId',
      ];

  /// Downloads and parses a finished stream's chat replay. Videos without
  /// public chat replay leave no output file and return an empty list.
  Future<List<LiveChatMessage>> replay(String videoId) async {
    final file = fileFor(videoId);
    await directory.create(recursive: true);
    try {
      await file.delete();
    } on FileSystemException {
      // No previous replay for this video.
    }
    final result = await runWithTimeout(
      ytDlpPath,
      arguments(videoId),
      timeout: const Duration(minutes: 2),
      environment: _environment,
    );
    if (!await file.exists()) {
      final error = result.stderr.toString().trim();
      if (result.exitCode == 0 || RegExp(r'no subtitles|live chat replay is not available', caseSensitive: false).hasMatch(error)) return const [];
      throw StateError(error.isEmpty ? 'yt-dlp exited with code ${result.exitCode}' : error);
    }
    final contents = await file.readAsString();
    return contents.trim().isEmpty ? const [] : LiveChatMessage.parseLines(contents);
  }

  /// Streams new messages from an active live chat. yt-dlp owns YouTube's
  /// continuation requests and appends each action to the same JSON format
  /// used for recorded replays. Cancelling the subscription stops that run.
  Stream<LiveChatMessage> current(String videoId) async* {
    final file = fileFor(videoId);
    await directory.create(recursive: true);
    try {
      await file.delete();
    } on FileSystemException {
      // The previous managed chat capture did not exist.
    }
    final process = await ProcessTree.start(
      ytDlpPath,
      arguments(videoId),
      environment: _environment,
    );
    lowerPriority(process.pid);
    final errors = StringBuffer();
    final errorSubscription = process.stderr.transform(utf8.decoder).listen(errors.write);
    var running = true;
    var exitCode = 0;
    unawaited(process.exitCode.then((code) {
      exitCode = code;
      running = false;
    }));
    var offset = 0;
    var pending = <int>[];
    var yielded = false;
    try {
      while (running || pending.isNotEmpty) {
        if (await file.exists()) {
          final length = await file.length();
          if (length > offset) {
            final reader = await file.open();
            await reader.setPosition(offset);
            pending.addAll(await reader.read(length - offset));
            await reader.close();
            offset = length;
            final lastLine = pending.lastIndexOf(10);
            if (lastLine >= 0) {
              final lines = utf8.decode(pending.sublist(0, lastLine + 1), allowMalformed: true);
              pending = pending.sublist(lastLine + 1);
              for (final line in const LineSplitter().convert(lines)) {
                for (final message in LiveChatMessage.parseLine(line)) {
                  yielded = true;
                  yield message;
                }
              }
            }
          }
        }
        if (!running) {
          if (pending.isNotEmpty) {
            for (final message in LiveChatMessage.parseLine(utf8.decode(pending, allowMalformed: true))) {
              yielded = true;
              yield message;
            }
            pending = const [];
          }
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      if (!yielded && exitCode != 0) {
        final error = errors.toString().trim();
        throw StateError(error.isEmpty ? 'yt-dlp exited with code $exitCode' : error);
      }
    } finally {
      process.kill();
      await errorSubscription.cancel();
    }
  }
}
