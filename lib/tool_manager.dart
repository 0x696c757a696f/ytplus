import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_directories.dart';
import 'ffmpeg_component.dart';
import 'libmpv_updates.dart';
import 'process_runner.dart';
import 'version_order.dart';
import 'l10n/l10n.dart';

class ToolPaths {
  final String mpv;
  final String ytDlp;
  final String? deno;
  const ToolPaths({required this.mpv, required this.ytDlp, this.deno});
  List<String> get executableDirectories => [
        File(mpv).parent.path,
        File(ytDlp).parent.path,
        if (deno != null) File(deno!).parent.path,
      ];
}

/// Downloads GitHub release assets to versioned directories and checks SHA-256.
class ToolManager {
  final AppDirectories directories;
  final void Function(String) status;
  ToolManager(this.directories, this.status);

  late final Directory root;
  late final LibmpvState libmpv;
  final http.Client _client = http.Client();

  static final _separator = Platform.pathSeparator;

  Future<void> initialize() async {
    root = directories.components;
    await root.create(recursive: true);
    libmpv = LibmpvState(Directory('${root.path}${_separator}mpv'), bundled: _readBundledLibmpv());
    // A newer app release may ship a newer libmpv than an earlier download.
    await libmpv.dropIfOutdated();
  }

  LibmpvBuild? _readBundledLibmpv() {
    final file = File('${File(Platform.resolvedExecutable).parent.path}${_separator}libmpv-version.txt');
    try {
      return file.existsSync() ? LibmpvBuild.fromVersionFile(file.readAsStringSync()) : null;
    } on FileSystemException {
      return null;
    }
  }

  Future<ToolPaths> ensureReady() async {
    if (!Platform.isWindows) throw UnsupportedError('This prototype currently targets Windows x64.');
    // The runner already loaded a downloaded libmpv when one was selected;
    // Dart has to open that same copy.
    final mpv = libmpv.loadedPath ?? _bundledMpv;
    if (!File(mpv).existsSync()) throw StateError('Bundled libmpv-2.dll is missing. Re-download the Lumtub package.');
    if (discover()?.ytDlp.isNotEmpty != true) {
      status(tr('首次启动：安装 yt-dlp…'));
      await _installYtDlp();
    }
    // Deno is needed by some YouTube JavaScript challenge paths. Optional at startup.
    if (discover()?.deno == null) {
      try {
        status(tr('安装 YouTube 解析所需的 Deno…'));
        await _installDeno();
      } catch (e) {
        status(tr('Deno 暂时不可用，可以稍后从工具更新中重试：{0}', [e]));
      }
    }
    final ready = discover();
    if (ready == null || ready.ytDlp.isEmpty) {
      throw StateError('Required components could not be installed.');
    }
    return ToolPaths(mpv: mpv, ytDlp: ready.ytDlp, deno: ready.deno);
  }

  String get _bundledMpv => '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}libmpv-2.dll';

  ToolPaths? discover() {
    if (!root.existsSync()) return null;
    final bundledMpv = libmpv.loadedPath ?? _bundledMpv;
    final mpv = File(bundledMpv).existsSync() ? bundledMpv : null;
    final yt = _findNewest('yt-dlp', 'yt-dlp.exe');
    final deno = _findNewest('deno', 'deno.exe');
    if (mpv == null && yt == null) return null;
    return ToolPaths(mpv: mpv ?? '', ytDlp: yt ?? '', deno: deno);
  }

  String? _findNewest(String group, String fileName) {
    final parent = Directory('${root.path}${Platform.pathSeparator}$group');
    if (!parent.existsSync()) return null;
    final dirs = _versions(parent);
    for (final folder in dirs) {
      try {
        for (final item in folder.listSync(recursive: true, followLinks: false)) {
          if (item is File && item.uri.pathSegments.last.toLowerCase() == fileName.toLowerCase()) return item.path;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Usable version folders in [parent], newest first.
  List<Directory> _versions(Directory parent) {
    if (!parent.existsSync()) return const [];
    return parent
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.path.endsWith('.partial') && !File('${d.path}$_separator$_failedMarker').existsSync())
        .toList()
      ..sort((a, b) => compareVersionFolders(a.path, b.path));
  }

  static const _failedMarker = 'failed';
  static const _no7zMarker = 'cannot-extract-7z';

  /// The yt-dlp release tag in use, if any.
  String? get ytDlpVersion => _versionOf(discover()?.ytDlp);

  String? get denoVersion => _versionOf(discover()?.deno);

  String? _versionOf(String? executable) {
    if (executable == null || executable.isEmpty) return null;
    final parts = executable.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
    return parts.length < 2 ? null : parts[parts.length - 2].replaceFirst(RegExp(r'-dir$'), '');
  }

  /// Whether the yt-dlp in use is the single-file build, which the
  /// unpacked one replaces as soon as possible rather than at the next
  /// release.
  bool get _ytDlpIsSingleFile {
    final yt = discover()?.ytDlp;
    if (yt == null || yt.isEmpty) return false;
    return !Directory('${File(yt).parent.path}${_separator}_internal').existsSync();
  }

  /// Whether an older working yt-dlp is installed to go back to.
  bool get canRollBackYtDlp => _versions(Directory('${root.path}${_separator}yt-dlp')).length > 1;

  /// Stops using the newest yt-dlp, for example after a nightly build broke
  /// playback. Takes effect at the next launch, like an update.
  Future<void> rollBackYtDlp() async {
    final versions = _versions(Directory('${root.path}${_separator}yt-dlp'));
    if (versions.length < 2) return;
    await File('${versions.first.path}$_separator$_failedMarker').writeAsString(DateTime.now().toIso8601String());
  }

  Future<void> checkUpdates({bool force = false}) async {
    final stamp = File('${root.path}${Platform.pathSeparator}last_update_check.txt');
    if (!force && !_ytDlpIsSingleFile && await stamp.exists()) {
      final last = DateTime.tryParse((await stamp.readAsString()).trim());
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
    }
    final errors = <String>[];
    for (final task in <(String, Future<void> Function())>[
      ('yt-dlp', _installYtDlp), ('Deno', _installDeno), ('libmpv', _installLibmpv),
      // Never installed by an update check: only kept current once the user has it.
      ('ffmpeg', () => installFfmpeg(onlyIfInstalled: true)),
    ]) {
      try {
        status(tr('检查 {0} 更新…', [task.$1]));
        await task.$2();
      } catch (e) {
        errors.add('${task.$1}: $e');
      }
    }
    if (errors.isEmpty) {
      await stamp.writeAsString(DateTime.now().toIso8601String());
      status(tr('更新检查完成。如有新版，重启应用后启用。'));
    } else {
      status(tr('部分组件更新失败，现有版本不受影响：{0}', [errors.join(' / ')]));
    }
  }

  Future<Map<String, dynamic>> _release(String repository, {String? tag}) async {
    final response = await _client.get(
      Uri.parse('https://api.github.com/repos/$repository/releases/${tag == null ? 'latest' : 'tags/$tag'}'),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Lumtub-Windows/0.1'},
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw HttpException('GitHub API HTTP ${response.statusCode} for $repository');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// The newest download-ffmpeg release of [ffmpegRepository], which also
  /// publishes libmpv releases.
  Future<Map<String, dynamic>> _ffmpegRelease() async {
    final response = await _client.get(
      Uri.parse('https://api.github.com/repos/$ffmpegRepository/releases?per_page=30'),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Lumtub-Windows/0.1'},
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw HttpException('GitHub API HTTP ${response.statusCode} for $ffmpegRepository');
    final releases = jsonDecode(response.body);
    final release = releases is List ? ffmpegRelease(releases) : null;
    if (release == null) throw StateError('No ffmpeg release in $ffmpegRepository');
    return release;
  }

  Map<String, dynamic> _asset(Map<String, dynamic> release, bool Function(String) accept) {
    final raw = release['assets'];
    if (raw is! List) throw const FormatException('GitHub release contains no assets');
    for (final obj in raw) {
      if (obj is Map<String, dynamic> && accept(obj['name']?.toString() ?? '')) return obj;
    }
    throw StateError('Matching release asset not found: ${release['tag_name']}');
  }

  Uri _assetUri(Map<String, dynamic> asset) {
    final uri = Uri.parse(asset['browser_download_url']?.toString() ?? '');
    if (uri.scheme != 'https' || uri.host != 'github.com' || (asset['name']?.toString() ?? '').isEmpty) {
      throw const FormatException('Untrusted GitHub asset URL');
    }
    return uri;
  }

  /// Downloads [asset] into [into] and checks its SHA-256: [sha256Hex] when
  /// given (from the release's checksum file), else the digest GitHub lists.
  Future<File> _downloadVerified(Map<String, dynamic> asset, Directory into, {String? sha256Hex, void Function(int received, int? total)? onProgress}) async {
    final assetName = asset['name']?.toString() ?? '';
    final uri = _assetUri(asset);
    final digest = sha256Hex == null ? asset['digest']?.toString() ?? '' : 'sha256:$sha256Hex';
    if (!RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw StateError('No trusted SHA-256 digest for $assetName');
    }
    await into.create(recursive: true);
    final file = File('${into.path}${Platform.pathSeparator}$assetName');
    if (await file.exists() && (await _sha256(file)) == digest.substring(7).toLowerCase()) return file;
    final temp = File('${file.path}.download');
    if (await temp.exists()) await temp.delete();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'Lumtub-Windows/0.1';
      final result = await _client.send(request).timeout(const Duration(seconds: 30));
      if (result.statusCode != 200) throw HttpException('Download failed: HTTP ${result.statusCode}');
      final sink = temp.openWrite();
      try {
        var received = 0;
        await sink.addStream(result.stream.timeout(const Duration(seconds: 90)).map((chunk) {
          received += chunk.length;
          onProgress?.call(received, result.contentLength);
          return chunk;
        }));
      } finally {
        await sink.close();
      }
      if ((await _sha256(temp)) != digest.substring(7).toLowerCase()) {
        throw const FormatException('SHA-256 verification failed');
      }
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      return file;
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<String> _sha256(File file) async => (await sha256.bind(file.openRead()).first).toString();

  Future<void> _installYtDlp() async {
    final release = await _release('yt-dlp/yt-dlp-nightly-builds');
    final tag = _safeTag(release['tag_name']);
    final group = Directory('${root.path}${_separator}yt-dlp');
    await _removeSingleFileYtDlp(group);
    var dest = Directory('${group.path}$_separator$tag');
    // A version rolled back by the user is not installed again.
    if (await File('${dest.path}$_separator$_failedMarker').exists()) return;
    if (await File('${dest.path}${_separator}yt-dlp.exe').exists()) {
      if (await Directory('${dest.path}${_separator}_internal').exists()) return;
      // The same release as the single-file build in use, unpacked, beside
      // it: the running one cannot be replaced, and the newer name wins.
      dest = Directory('${dest.path}-dir');
      if (await File('${dest.path}$_separator$_failedMarker').exists()) return;
      if (await File('${dest.path}${_separator}yt-dlp.exe').exists()) return;
    }
    status(tr('下载 yt-dlp {0}…', [tag]));
    final partial = Directory('${dest.path}.partial');
    if (await partial.exists()) await partial.delete(recursive: true);
    try {
      final file = await _downloadYtDlp(release, partial);
      // A build that cannot even report its version is never used.
      final check = await runWithTimeout(file.path, ['--version'], timeout: const Duration(seconds: 30));
      if (check.exitCode != 0) throw StateError('yt-dlp $tag failed its self-check');
      await partial.rename(dest.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
    await _prune(group, keep: 3);
  }

  /// The unpacked build (yt-dlp_win.zip). The single-file yt-dlp.exe
  /// unpacks itself to a temp folder on every start, which costs a second
  /// of CPU and a second process for each search or channel page.
  Future<File> _downloadYtDlp(Map<String, dynamic> release, Directory into) async {
    final archive = await _downloadVerified(_asset(release, (name) => name == ytDlpFolderAsset), Directory('${root.path}${_separator}downloads'));
    await into.create(recursive: true);
    await _extractZip(archive, into);
    await archive.delete();
    final exe = File('${into.path}${_separator}yt-dlp.exe');
    if (!await exe.exists()) throw StateError('$ytDlpFolderAsset has no yt-dlp.exe');
    return exe;
  }

  /// Deletes single-file yt-dlp builds once an unpacked one is installed.
  /// One still running stays until the next launch.
  Future<void> _removeSingleFileYtDlp(Directory group) async {
    final versions = _versions(group);
    bool unpacked(Directory d) => Directory('${d.path}${_separator}_internal').existsSync();
    if (!versions.any(unpacked)) return;
    for (final old in versions.where((d) => !unpacked(d))) {
      try {
        await old.delete(recursive: true);
      } on FileSystemException {
        // In use; tried again next time.
      }
    }
  }

  static const ytDlpFolderAsset = 'yt-dlp_win.zip';

  /// Deletes all but the newest [keep] usable versions in [group]; rolled
  /// back versions stay as markers so they are not downloaded again.
  Future<void> _prune(Directory group, {required int keep}) async {
    for (final old in _versions(group).skip(keep)) {
      try {
        await old.delete(recursive: true);
      } on FileSystemException {
        // Still in use by a running process; tried again next time.
      }
    }
  }

  Future<void> _installLibmpv() async {
    final release = await _release('zhongfly/mpv-winbuild');
    final tag = _safeTag(release['tag_name']);
    final build = LibmpvBuild(tag, libmpvVariantForThisProcess());
    final running = libmpv.selected ?? libmpv.current;
    if (running != null && !running.isReplacedBy(build)) return;
    final group = libmpv.directory;
    final no7z = File('${group.path}$_separator$_no7zMarker');
    if (await no7z.exists()) return;
    final dest = Directory('${group.path}$_separator${build.folderName}');
    final dll = File('${dest.path}${_separator}libmpv-2.dll');
    if (libmpv.hasFailed(dll.path)) return;
    if (!await dll.exists()) {
      final names = (release['assets'] as List? ?? const []).whereType<Map>().map((asset) => asset['name']?.toString() ?? '');
      final assetName = libmpvAssetName(names, build.variant);
      if (assetName == null) throw StateError('No libmpv archive for this CPU in $tag');
      status(tr('下载 libmpv {0}…', [build.label]));
      final archive = await _downloadVerified(_asset(release, (name) => name == assetName), Directory('${root.path}${_separator}downloads'));
      final partial = Directory('${dest.path}.partial');
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create(recursive: true);
      try {
        try {
          await _extractZip(archive, partial);
        } on ProcessException {
          // Windows before 11 23H2 has no 7z support in tar.exe; do not
          // download every new release only to fail again.
          await no7z.writeAsString(DateTime.now().toIso8601String());
          throw StateError(tr('此版本 Windows 无法解压 7z，继续使用内置 libmpv'));
        }
        final found = partial.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('${_separator}libmpv-2.dll'));
        if (found.isEmpty) throw StateError('libmpv archive $tag has no libmpv-2.dll');
        await dest.create(recursive: true);
        await found.first.copy(dll.path);
      } finally {
        await partial.delete(recursive: true);
        if (await archive.exists()) await archive.delete();
      }
    }
    await libmpv.select(dll.path);
    // Keep the running copy and the new one; the loaded DLL cannot be deleted.
    for (final old in group.listSync().whereType<Directory>()) {
      if (old.path == dest.path || (libmpv.loadedPath?.startsWith('${old.path}$_separator') ?? false)) continue;
      try {
        await old.delete(recursive: true);
      } on FileSystemException {
        // Locked; tried again next time.
      }
    }
  }

  Future<void> _installDeno() async {
    final release = await _release('denoland/deno');
    final tag = _safeTag(release['tag_name']);
    final dest = Directory('${root.path}${Platform.pathSeparator}deno${Platform.pathSeparator}$tag');
    if (await File('${dest.path}${Platform.pathSeparator}deno.exe').exists()) return;
    status(tr('下载 Deno {0}…', [tag]));
    final asset = _asset(release, (name) => name == 'deno-x86_64-pc-windows-msvc.zip');
    final archive = await _downloadVerified(asset, Directory('${root.path}${Platform.pathSeparator}downloads'));
    final partial = Directory('${dest.path}.partial');
    if (await partial.exists()) await partial.delete(recursive: true);
    await partial.create(recursive: true);
    try {
      await _extractZip(archive, partial);
      if (!await File('${partial.path}${Platform.pathSeparator}deno.exe').exists()) {
        throw StateError('Deno release did not contain deno.exe');
      }
      await dest.parent.create(recursive: true);
      await partial.rename(dest.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    }
  }

  // ffmpeg: optional, installed on demand (see ffmpeg_component.dart).

  /// The folder holding the newest installed ffmpeg and ffprobe, if any.
  String? get ffmpegDirectory {
    final exe = _findNewest('ffmpeg', 'ffmpeg.exe');
    return exe == null ? null : File(exe).parent.path;
  }

  String? get ffmpegVersion => _versionOf(_findNewest('ffmpeg', 'ffmpeg.exe'));

  /// Bytes on disk of the installed ffmpeg, or null without it.
  int? get ffmpegBytes {
    final dir = ffmpegDirectory;
    if (dir == null) return null;
    var total = 0;
    for (final file in Directory(dir).listSync().whereType<File>()) {
      total += file.lengthSync();
    }
    return total;
  }

  /// The download size in bytes the release lists for the ffmpeg archive.
  Future<int?> ffmpegDownloadSize() async {
    final release = await _ffmpegRelease();
    final name = ffmpegAssetName((release['assets'] as List? ?? const []).whereType<Map>().map((a) => a['name']?.toString() ?? ''), libmpvVariantForThisProcess());
    final size = (release['assets'] as List).whereType<Map>().where((a) => a['name'] == name).firstOrNull?['size'];
    return size is int ? size : null;
  }

  /// Installs the newest ffmpeg build unless it is there already. With
  /// [onlyIfInstalled] nothing happens for a user who never installed it.
  Future<void> installFfmpeg({bool onlyIfInstalled = false, void Function(int received, int? total)? onProgress}) async {
    if (onlyIfInstalled && ffmpegDirectory == null) return;
    final release = await _ffmpegRelease();
    final assets = (release['assets'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
    final variant = libmpvVariantForThisProcess();
    final assetName = ffmpegAssetName(assets.map((a) => a['name']?.toString() ?? ''), variant);
    if (assetName == null) throw StateError('No $variant ffmpeg build in the ${release['tag_name']} release');
    final asset = _asset(release, (name) => name == assetName);
    final folder = ffmpegFolderName(assetName, asset['updated_at']?.toString());
    final dest = Directory('${root.path}${_separator}ffmpeg$_separator$folder');
    if (await File('${dest.path}${_separator}ffmpeg.exe').exists()) return;
    status(tr('下载 ffmpeg {0}…', [folder]));
    // The hash comes from the checksum file of the same release, over HTTPS.
    final sums = await _client.get(_assetUri(_asset(release, (name) => name == ffmpegChecksumsAsset)), headers: {'User-Agent': 'Lumtub-Windows/0.1'}).timeout(const Duration(seconds: 30));
    if (sums.statusCode != 200) throw HttpException('Checksum file HTTP ${sums.statusCode}');
    final expected = parseChecksums(sums.body)[assetName];
    if (expected == null) throw StateError('No checksum listed for $assetName');
    final archive = await _downloadVerified(asset, Directory('${root.path}${_separator}downloads'), sha256Hex: expected, onProgress: onProgress);
    final partial = Directory('${dest.path}.partial');
    if (await partial.exists()) await partial.delete(recursive: true);
    await partial.create(recursive: true);
    try {
      final written = await _extractFfmpeg(archive, partial);
      if (!written.contains('ffmpeg.exe') || !written.contains('ffprobe.exe')) throw StateError('ffmpeg archive lacks ffmpeg.exe or ffprobe.exe');
      final check = await runWithTimeout('${partial.path}${_separator}ffmpeg.exe', ['-version'], timeout: const Duration(seconds: 30));
      if (check.exitCode != 0) throw StateError('ffmpeg $folder failed its self-check');
      await partial.rename(dest.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete(recursive: true);
      rethrow;
    } finally {
      if (await archive.exists()) await archive.delete();
    }
    await _prune(Directory('${root.path}${_separator}ffmpeg'), keep: 2);
  }

  /// Deletes every installed ffmpeg.
  Future<void> removeFfmpeg() async {
    final dir = Directory('${root.path}${_separator}ffmpeg');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  String _safeTag(Object? value) {
    final tag = value?.toString() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,100}$').hasMatch(tag)) throw const FormatException('Invalid release tag');
    return tag;
  }

  /// ffmpeg.exe, ffprobe.exe and their DLLs from [archive]; Windows' own
  /// tar.exe takes over for an archive the small reader cannot read (Zip64).
  Future<List<String>> _extractFfmpeg(File archive, Directory into) async {
    try {
      return await extractFfmpegBinaries(archive, into);
    } on FormatException {
      final whole = Directory('${into.path}.all');
      if (await whole.exists()) await whole.delete(recursive: true);
      await whole.create();
      try {
        await _extractZip(archive, whole);
        final written = <String>[];
        await for (final entry in whole.list(recursive: true)) {
          final name = entry.uri.pathSegments.last.toLowerCase();
          if (entry is File && entry.parent.uri.pathSegments.where((s) => s.isNotEmpty).last == 'bin' && (name == 'ffmpeg.exe' || name == 'ffprobe.exe' || name.endsWith('.dll'))) {
            await entry.copy('${into.path}$_separator$name');
            written.add(name);
          }
        }
        return written;
      } finally {
        await whole.delete(recursive: true);
      }
    }
  }

  Future<void> _extractZip(File archive, Directory into) async {
    final result = await Process.run('tar.exe', ['-xf', archive.path, '-C', into.path]);
    if (result.exitCode != 0) {
      throw ProcessException('tar.exe', ['-xf', archive.path, '-C', into.path], result.stderr.toString(), result.exitCode);
    }
  }

  void dispose() => _client.close();
}
