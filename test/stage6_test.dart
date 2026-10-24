import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app_log.dart';
import 'package:lumtub/playback_recovery.dart';
import 'package:lumtub/ui/player_stats.dart';

void main() {
  group('log', () {
    test('hides tokens and signed stream addresses', () {
      const line = 'POST code=4/0Ab-secret&code_verifier=x refresh_token=1//abc '
          '{"access_token": "ya29.zzz"} Authorization: Bearer ya29.qqq '
          'Failed to open https://rr3---sn-abc.googlevideo.com/videoplayback?expire=1&sig=ABC';
      final redacted = AppLog.redact(line);
      for (final secret in ['4/0Ab-secret', '1//abc', 'ya29.zzz', 'ya29.qqq', 'sig=ABC', 'expire=1']) {
        expect(redacted, isNot(contains(secret)));
      }
      expect(redacted, contains('rr3---sn-abc.googlevideo.com'));
      expect(AppLog.redact('播放失败 dQw4w9WgXcQ'), '播放失败 dQw4w9WgXcQ');
    });

    test('appends lines and rotates a large log', () async {
      final dir = await Directory.systemTemp.createTemp('lumtub_log');
      addTearDown(() => dir.delete(recursive: true));
      final log = (await AppLog.open(dir))!;
      log.write('INFO ', '第一行');
      log.write('ERROR', 'refresh_token=secret');
      await log.flush();
      final text = await log.file.readAsString();
      expect(text, contains('INFO  第一行'));
      expect(text, contains('refresh_token=***'));
      await log.file.writeAsBytes(List.filled(AppLog.maxBytes + 1, 65));
      await AppLog.open(dir);
      expect(await File('${dir.path}/lumtub.old.log').exists(), isTrue);
      expect(await File('${dir.path}/lumtub.log').exists(), isFalse);
      AppLog.current = null;
    });

    test('rotates during a long session once the file passes the limit', () async {
      final dir = await Directory.systemTemp.createTemp('lumtub_log');
      addTearDown(() => dir.delete(recursive: true));
      final log = (await AppLog.open(dir))!;
      log.write('INFO ', 'x' * 1000);
      await log.flush();
      expect(await File('${dir.path}/lumtub.old.log').exists(), isFalse);
      for (var i = 0; i < 1100; i++) {
        log.write('INFO ', 'y' * 1000);
      }
      await log.flush();
      expect(await File('${dir.path}/lumtub.old.log').exists(), isTrue);
      expect(await File('${dir.path}/lumtub.log').exists(), isFalse);
      log.write('INFO ', 'after');
      await log.flush();
      expect(await log.file.readAsLines(), hasLength(1));
      AppLog.current = null;
    });

    test('batches lines in order and flushes pending ones on demand', () async {
      final dir = await Directory.systemTemp.createTemp('lumtub_log');
      addTearDown(() => dir.delete(recursive: true));
      final log = (await AppLog.open(dir))!;
      for (var i = 0; i < 50; i++) {
        log.write(i == 25 ? 'ERROR' : 'INFO ', 'line $i');
      }
      await log.flush();
      final lines = await log.file.readAsLines();
      expect(lines, hasLength(50));
      for (var i = 0; i < 50; i++) {
        expect(lines[i], endsWith(' line $i'));
      }
      expect(lines[3], contains('INFO  line 3'));
      // Without an explicit flush the timer writes them.
      log.write('INFO ', 'later');
      await Future<void>.delayed(AppLog.flushDelay + const Duration(milliseconds: 300));
      expect(await log.file.readAsLines(), hasLength(51));
      AppLog.current = null;
    });
  });

  group('playback recovery', () {
    test('allows a few attempts per window, then gives up', () {
      var now = DateTime(2026);
      final recovery = PlaybackRecovery(clock: () => now);
      expect([for (var i = 0; i < 4; i++) recovery.tryAttempt()], [true, true, true, false]);
      now = now.add(const Duration(minutes: 3));
      expect(recovery.tryAttempt(), isTrue);
      recovery.reset();
      expect(recovery.tryAttempt(), isTrue);
    });

    test('tells an early end from a real one', () {
      const duration = Duration(minutes: 10);
      expect(PlaybackRecovery.endedEarly(const Duration(minutes: 4), duration), isTrue);
      expect(PlaybackRecovery.endedEarly(const Duration(minutes: 9, seconds: 57), duration), isFalse);
      expect(PlaybackRecovery.endedEarly(Duration.zero, duration), isFalse);
      expect(PlaybackRecovery.endedEarly(const Duration(seconds: 5), const Duration(seconds: 20)), isFalse);
    });

    test('recovers from stream errors only', () {
      expect(PlaybackRecovery.isNetworkError('Failed to open https://rr1.googlevideo.com/x'), isTrue);
      expect(PlaybackRecovery.isNetworkError('HTTP error 403 Forbidden'), isTrue);
      expect(PlaybackRecovery.isNetworkError('tcp: Connection reset by peer'), isTrue);
      expect(PlaybackRecovery.isNetworkError('Can not open external file subs.vtt'), isFalse);
      expect(PlaybackRecovery.isNetworkError('Cannot find filter lavfi'), isFalse);
    });
  });

  test('formats player statistics', () {
    final rows = Map.fromEntries(statsRows({
      'video-codec': 'vp9',
      'hwdec-current': 'd3d11va',
      'video-params/w': '1920',
      'video-params/h': '1080',
      'container-fps': '59.940',
      'estimated-vf-fps': '59.94',
      'frame-drop-count': '0',
      'decoder-frame-drop-count': '2',
      'vo-delayed-frame-count': '5',
      'avsync': '-0.0123',
      'display-fps': '60',
      'video-bitrate': '2512000',
      'demuxer-cache-duration': '31.37',
      'cache-speed': '3145728',
    }).map((row) => MapEntry(row.$1, row.$2)));
    expect(rows['分辨率'], '1920x1080');
    expect(rows['解码'], '硬件 d3d11va');
    expect(rows['帧率'], '59.94 / 源 59.940');
    expect(rows['丢帧'], '输出 0 · 解码 2 · 延迟 5');
    expect(rows['音画偏差'], '-12 ms · 显示 60 Hz');
    expect(rows['码率'], '视频 2512 kbps · 音频 —');
    expect(rows['缓冲'], '31.4 秒');
    expect(rows['下载速度'], '3.0 MB/s');
    expect(Map.fromEntries(statsRows({'hwdec-current': 'no'}).map((r) => MapEntry(r.$1, r.$2)))['解码'], '软件解码');
  });
}
