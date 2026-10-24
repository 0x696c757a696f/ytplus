import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app_directories.dart';
import 'package:lumtub/cache_manager.dart';
import 'package:lumtub/player_settings.dart';

void main() {
  test('clear removes only Lumtub-managed cache folders', () async {
    final temp = await Directory.systemTemp.createTemp('lumtub-cache-test-');
    addTearDown(() => temp.delete(recursive: true));
    final manager = CacheManager(AppDirectories.at(Directory('${temp.path}${Platform.pathSeparator}app')));
    const settings = PlayerSettings();
    final root = await manager.prepare(settings);
    await File('${root.path}${Platform.pathSeparator}temp${Platform.pathSeparator}download.part').writeAsString('1234');
    final userFile = File('${root.path}${Platform.pathSeparator}do-not-delete.txt');
    await userFile.writeAsString('user file');

    final nested = File('${root.path}${Platform.pathSeparator}yt-dlp${Platform.pathSeparator}youtube-sigfuncs${Platform.pathSeparator}a.json');
    await nested.create(recursive: true);
    await nested.writeAsString('123456');

    expect(await manager.size(settings), 10);
    final result = await manager.clear(settings);

    expect(result, (freed: 10, skipped: 0));
    expect(await manager.size(settings), 0);
    expect(await userFile.readAsString(), 'user file');
    // The managed folders stay, emptied, for processes that use them.
    for (final name in CacheManager.managedFolders) {
      final folder = Directory('${root.path}${Platform.pathSeparator}$name');
      expect(await folder.exists(), isTrue);
      expect(await folder.list().isEmpty, isTrue);
    }
  });

  group('migrate', () {
    late Directory temp;
    late CacheManager manager;
    late PlayerSettings from, to;
    String sub(PlayerSettings s, String name, [String file = '']) => '${manager.rootFor(s).path}${Platform.pathSeparator}$name$file';

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('lumtub-migrate-test-');
      addTearDown(() => temp.delete(recursive: true));
      manager = CacheManager(AppDirectories.at(Directory('${temp.path}${Platform.pathSeparator}app')));
      from = const PlayerSettings();
      to = PlayerSettings(cachePath: '${temp.path}${Platform.pathSeparator}new');
      await manager.prepare(from);
      await File(sub(from, 'thumbnails', '${Platform.pathSeparator}a.jpg')).writeAsString('1234');
      await File(sub(from, 'yt-dlp', '${Platform.pathSeparator}deep${Platform.pathSeparator}b.json')).create(recursive: true);
      await File(sub(from, 'yt-dlp', '${Platform.pathSeparator}deep${Platform.pathSeparator}b.json')).writeAsString('123456');
    });

    test('copies, saves the new location, then deletes the old folders', () async {
      var committed = false;
      await manager.migrate(from, to, commit: () async {
        // Until the setting is saved the old cache is still whole.
        expect(await File(sub(from, 'thumbnails', '${Platform.pathSeparator}a.jpg')).exists(), isTrue);
        committed = true;
      });
      expect(committed, isTrue);
      expect(await File(sub(to, 'thumbnails', '${Platform.pathSeparator}a.jpg')).readAsString(), '1234');
      expect(await File(sub(to, 'yt-dlp', '${Platform.pathSeparator}deep${Platform.pathSeparator}b.json')).readAsString(), '123456');
      expect(await manager.size(from), 0);
      expect(await manager.size(to), 10);
      expect(await Directory(manager.rootFor(to).path).list().map((e) => e.path).where((p) => p.contains('.migrating') || p.contains('.replaced')).toList(), isEmpty);
    });

    test('a failure while saving keeps the old cache and the target as it was', () async {
      final existing = File(sub(to, 'thumbnails', '${Platform.pathSeparator}keep.jpg'));
      await manager.prepare(to);
      await existing.writeAsString('mine');
      await expectLater(manager.migrate(from, to, commit: () async => throw const FileSystemException('disk full')), throwsA(isA<FileSystemException>()));
      expect(await manager.size(from), 10);
      expect(await existing.readAsString(), 'mine');
      expect(await File(sub(to, 'thumbnails', '${Platform.pathSeparator}a.jpg')).exists(), isFalse);
      expect(await manager.size(to), 4);
      expect(await Directory(manager.rootFor(to).path).list().map((e) => e.path).where((p) => p.contains('.migrating') || p.contains('.replaced')).toList(), isEmpty);
    });

    test('a failure while copying leaves the target untouched and the old cache whole', () async {
      await manager.prepare(to);
      final existing = File(sub(to, 'yt-dlp', '${Platform.pathSeparator}keep.json'));
      await existing.writeAsString('mine');
      // A file in the way of yt-dlp's temporary folder fails the copy after thumbnails' succeeded.
      await File(sub(to, 'yt-dlp.migrating-x')).writeAsString('in the way');
      await expectLater(manager.migrate(from, to, tag: 'x'), throwsA(isA<FileSystemException>()));
      expect(await manager.size(from), 10);
      expect(await existing.readAsString(), 'mine');
      expect(await manager.size(to), 4);
      expect(Directory(sub(to, 'thumbnails.migrating-x')).existsSync(), isFalse);
      expect(Directory(sub(to, 'thumbnails')).listSync(), isEmpty);
    });
  });
}
