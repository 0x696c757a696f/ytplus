import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/live_chat_repository.dart';

void main() {
  test('uses the configured cache and yt-dlp conventions for replay', () {
    final repository = LiveChatRepository(
      'yt-dlp.exe',
      cacheDirectory: 'C:${Platform.pathSeparator}cache',
      deno: 'C:${Platform.pathSeparator}tools${Platform.pathSeparator}deno.exe',
      proxy: () => 'http://127.0.0.1:7890',
    );
    expect(repository.fileFor('abcdefghijk').path, endsWith('cache${Platform.pathSeparator}live-chat${Platform.pathSeparator}abcdefghijk.live_chat.json'));
    expect(repository.arguments('abcdefghijk'), containsAllInOrder([
      '--skip-download',
      '--no-playlist',
      '--cache-dir', 'C:${Platform.pathSeparator}cache',
      '--proxy', 'http://127.0.0.1:7890',
      '--js-runtimes', 'deno:C:${Platform.pathSeparator}tools${Platform.pathSeparator}deno.exe',
      '--write-subs',
      '--sub-langs', 'live_chat',
      '--sub-format', 'json',
      '--output', 'C:${Platform.pathSeparator}cache${Platform.pathSeparator}live-chat${Platform.pathSeparator}%(id)s.%(ext)s',
      '--', 'https://www.youtube.com/watch?v=abcdefghijk',
    ]));
  });
}
