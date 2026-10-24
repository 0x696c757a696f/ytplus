import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/process_runner.dart';
import 'package:lumtub/version_order.dart';

void main() {
  test('collects output and the exit code', () async {
    if (Platform.isWindows) return;
    final result = await runWithTimeout('sh', ['-c', 'echo ok; echo bad >&2; exit 3'], timeout: const Duration(seconds: 5));
    expect(result.exitCode, 3);
    expect(result.stdout, 'ok\n');
    expect(result.stderr, 'bad\n');
  });

  test('kills a process that outlives the timeout', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_runner');
    addTearDown(() => dir.delete(recursive: true));
    final pidFile = File('${dir.path}/pid');
    // exec keeps the shell's pid, so the recorded one is the process killed.
    final script = 'echo \$\$ > ${pidFile.path}; exec sleep 30';
    int? started;
    await expectLater(
      runWithTimeout('sh', ['-c', script], timeout: const Duration(milliseconds: 500), onStart: (p) => started = p.pid),
      throwsA(isA<TimeoutException>()),
    );
    final pid = int.parse(pidFile.readAsStringSync().trim());
    expect(pid, started);
    // Signal 0 only checks that the process exists.
    for (var i = 0; i < 20 && (await Process.run('kill', ['-0', '$pid'])).exitCode == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect((await Process.run('kill', ['-0', '$pid'])).exitCode, isNot(0));
  });

  group('version folder order', () {
    List<String> sorted(List<String> names) => [...names]..sort(compareVersionFolders);

    test('compares numbers, not text', () {
      expect(sorted(['2026.9.30', '2026.10.21', '2026.10.9', '2025.12.1']), ['2026.10.21', '2026.10.9', '2026.9.30', '2025.12.1']);
      expect(sorted(['/r/yt-dlp/2026.10.10.99', '/r/yt-dlp/2026.10.10.233141']).first, '/r/yt-dlp/2026.10.10.233141');
      expect(sorted(['v2.9.0', 'v2.10.1', 'v2.10.0']), ['v2.10.1', 'v2.10.0', 'v2.9.0']);
    });

    test('an unpacked build sorts above the same release', () {
      expect(sorted(['2026.10.10.233141', '2026.10.10.233141-dir', '2026.10.11.1']), ['2026.10.11.1', '2026.10.10.233141-dir', '2026.10.10.233141']);
    });

    test('libmpv folders order by release, then AVX2 build', () {
      expect(
        sorted(['20261018-x86_64', '20261018-x86_64-v3', '20261101-x86_64', '20260930-x86_64-v3']),
        ['20261101-x86_64', '20261018-x86_64-v3', '20261018-x86_64', '20260930-x86_64-v3'],
      );
    });

    test('names that do not parse come last, in a stable order', () {
      expect(sorted(['zzz', '2026.1.1', 'aaa']), ['2026.1.1', 'zzz', 'aaa']);
      expect(sorted(['aaa', 'zzz', '2026.1.1']), ['2026.1.1', 'zzz', 'aaa']);
    });
  });
}
