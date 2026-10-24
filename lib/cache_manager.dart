import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_directories.dart';
import 'player_settings.dart';

/// Manages only folders created by Lumtub. A selected parent folder is never
/// deleted or scanned as if it belonged to the application.
class CacheManager {
  static const managedFolders = {'thumbnails', 'temp', 'yt-dlp', 'mpv'};
  final AppDirectories directories;
  CacheManager(this.directories);

  Directory rootFor(PlayerSettings settings) => settings.cachePath == null
      ? directories.cache
      : Directory(settings.cachePath!);

  Future<Directory> prepare(PlayerSettings settings) async {
    final root = rootFor(settings);
    await root.create(recursive: true);
    for (final name in managedFolders) {
      await Directory('${root.path}${Platform.pathSeparator}$name').create(recursive: true);
    }
    return root;
  }

  Future<int> size(PlayerSettings settings) async {
    var bytes = 0;
    final root = rootFor(settings);
    for (final name in managedFolders) {
      final child = Directory('${root.path}${Platform.pathSeparator}$name');
      if (!await child.exists()) continue;
      await for (final item in child.list(recursive: true, followLinks: false)) {
        if (item is File) bytes += await item.length();
      }
    }
    return bytes;
  }

  /// Deletes what is inside the managed folders, keeping the folders. A
  /// file in use, such as one yt-dlp or Deno holds in `temp` while a search
  /// runs, is skipped rather than stopping the rest. Returns the bytes freed
  /// and how many files were left.
  Future<({int freed, int skipped})> clear(PlayerSettings settings) async {
    final root = await prepare(settings);
    var freed = 0;
    var skipped = 0;
    for (final name in managedFolders) {
      final child = Directory('${root.path}${Platform.pathSeparator}$name');
      if (!await child.exists()) continue;
      final entries = await child.list(recursive: true, followLinks: false).toList();
      // Files first, then folders from the deepest, so emptied ones go too.
      for (final file in entries.whereType<File>()) {
        try {
          final length = await file.length();
          await file.delete();
          freed += length;
        } on FileSystemException {
          skipped++;
        }
      }
      final folders = entries.whereType<Directory>().toList()..sort((a, b) => b.path.length.compareTo(a.path.length));
      for (final folder in folders) {
        try {
          await folder.delete();
        } on FileSystemException {
          // Still holds a skipped file, or is some process's working folder.
        }
      }
    }
    return (freed: freed, skipped: skipped);
  }

  /// Moves the managed folders from [from]'s location to [to]'s without
  /// ever losing the old copy: each is copied into a temporary folder next to
  /// its destination and checked (file count and sizes), then put in place;
  /// [commit] (saving the new location) runs; only then is the old folder
  /// emptied. If anything fails, or [commit] throws, the old folders stay as
  /// they were, whatever was already in [to] is restored, and the error is
  /// rethrown.
  Future<void> migrate(PlayerSettings from, PlayerSettings to, {Future<void> Function()? commit, @visibleForTesting String? tag}) async {
    final oldRoot = await prepare(from);
    final newRoot = await prepare(to);
    tag ??= '${DateTime.now().microsecondsSinceEpoch}';
    String at(Directory root, String name, [String suffix = '']) => '${root.path}${Platform.pathSeparator}$name$suffix';
    final names = [
      for (final name in managedFolders)
        if (at(oldRoot, name) != at(newRoot, name) && await Directory(at(oldRoot, name)).exists()) name,
    ];
    final staged = <String, Directory>{};
    final backups = <String, Directory>{};
    final placed = <String>[];
    Future<void> discard(Directory directory) async {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } on FileSystemException {
        // A leftover `.migrating`/`.replaced` folder is harmless.
      }
    }

    try {
      for (final name in names) {
        final source = Directory(at(oldRoot, name));
        final temp = staged[name] = Directory(at(newRoot, name, '.migrating-$tag'));
        await _copyDirectory(source, temp);
        final (expected, actual) = (await _inventory(source), await _inventory(temp));
        if (!_sameInventory(expected, actual)) throw FileSystemException('Copied cache does not match the original', source.path);
      }
      for (final name in names) {
        final destination = Directory(at(newRoot, name));
        if (await destination.exists()) {
          final backup = backups[name] = Directory(at(newRoot, name, '.replaced-$tag'));
          await destination.rename(backup.path);
        }
        await staged[name]!.rename(destination.path);
        placed.add(name);
      }
      await commit?.call();
    } catch (_) {
      for (final name in placed.reversed) {
        await discard(Directory(at(newRoot, name)));
        final backup = backups[name];
        if (backup != null) await backup.rename(at(newRoot, name));
      }
      for (final name in names) {
        if (!placed.contains(name)) {
          final backup = backups[name];
          if (backup != null && await backup.exists() && !await Directory(at(newRoot, name)).exists()) await backup.rename(at(newRoot, name));
        }
        await discard(staged[name] ?? Directory(at(newRoot, name, '.migrating-$tag')));
      }
      rethrow;
    }
    for (final name in names) {
      final backup = backups[name];
      if (backup != null) await discard(backup);
      // The old location is no longer used; a file still held open is left behind.
      await discard(Directory(at(oldRoot, name)));
    }
  }

  /// Relative path -> size of every file under [directory].
  Future<Map<String, int>> _inventory(Directory directory) async {
    final found = <String, int>{};
    await for (final item in directory.list(recursive: true, followLinks: false)) {
      if (item is File) found[item.path.substring(directory.path.length)] = await item.length();
    }
    return found;
  }

  bool _sameInventory(Map<String, int> a, Map<String, int> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final item in from.list(recursive: true, followLinks: false)) {
      final relative = item.path.substring(from.path.length).replaceFirst(RegExp(r'^[\\/]'), '');
      final destination = '${to.path}${Platform.pathSeparator}$relative';
      if (item is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (item is File) {
        await File(destination).parent.create(recursive: true);
        await item.copy(destination);
      }
    }
  }
}
