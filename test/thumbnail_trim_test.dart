import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/thumbnail_trim.dart';

void main() {
  late Directory dir;
  final now = DateTime(2026, 1, 1, 12);

  Future<File> make(String name, int size, Duration age) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(List.filled(size, 1));
    await file.setLastModified(now.subtract(age));
    return file;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lumtub-thumb-trim-');
    addTearDown(() => dir.delete(recursive: true));
  });

  test('the cap is 512 MiB unless cacheLimitGb is set', () {
    expect(thumbnailCapBytes(null), 512 * 1024 * 1024);
    expect(thumbnailCapBytes(2), 2 * 1024 * 1024 * 1024);
  });

  test('keeps channel avatars', () async {
    final avatar = await make('avatar_UC1.jpg', 100, const Duration(days: 9));
    final thumb = await make('a.jpg', 100, const Duration(days: 1));
    await trimThumbnails(dir, 50, now: now);
    expect((avatar.existsSync(), thumb.existsSync()), (true, false));
  });

  test('deletes the least recently modified first, only until under the cap', () async {
    final oldest = await make('a.jpg', 100, const Duration(days: 3));
    final older = await make('b.jpg', 100, const Duration(days: 2));
    final old = await make('c.jpg', 100, const Duration(days: 1));
    final newest = await make('d.jpg', 100, const Duration(hours: 1));
    expect(await trimThumbnails(dir, 250, now: now), 200);
    expect([oldest, older, old, newest].map((f) => f.existsSync()), [false, false, true, true]);
    // Already under the cap: nothing happens.
    expect(await trimThumbnails(dir, 250, now: now), 0);
    expect(await trimThumbnails(dir, 200, now: now), 0);
    expect(old.existsSync(), isTrue);
  });

  test('files modified in the last minute are kept even over the cap', () async {
    final stale = await make('a.jpg', 100, const Duration(days: 1));
    final fresh = await make('b.jpg', 100, const Duration(seconds: 20));
    final fresh2 = await make('c.jpg', 100, Duration.zero);
    expect(await trimThumbnails(dir, 0, now: now), 100);
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(fresh2.existsSync(), isTrue);
  });

  test('a missing folder or one holding sub-folders is fine', () async {
    expect(await trimThumbnails(Directory('${dir.path}${Platform.pathSeparator}nope'), 0), 0);
    await Directory('${dir.path}${Platform.pathSeparator}sub').create();
    await make('a.jpg', 10, const Duration(days: 1));
    expect(await trimThumbnails(dir, 0, now: now), 10);
    expect(Directory('${dir.path}${Platform.pathSeparator}sub').existsSync(), isTrue);
  });
}
