import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_log.dart';
import '../models.dart';
import '../process_priority.dart';
import '../sponsor_block.dart';
import '../video_codec.dart';
import 'download_models.dart';
import 'download_selection.dart';
import '../native_core.dart';

/// Per-call settings the manager reads when a download starts.
class DownloadOptions {
  const DownloadOptions({this.proxy, this.deno, this.cacheDirectory, this.subtitleLanguages, this.autoSubtitles = false});
  /// yt-dlp's `--proxy` value, see `NetworkProxy.ytDlpValue`.
  final String? proxy;
  final String? deno;
  final String? cacheDirectory;
  /// yt-dlp's `--sub-langs`; null saves no subtitles.
  final String? subtitleLanguages;
  /// Also save automatic captions.
  final bool autoSubtitles;
}

typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments, {Map<String, String>? environment});

/// A downloaded video as playback finds it: the file and what the sidecar
/// `.info.json` and the neighbouring subtitle files hold.
class LocalVideo {
  LocalVideo(this.file, this.info, this.subtitles, this.segments);
  final File file;
  final Map<String, dynamic> info;
  final List<File> subtitles;
  final List<SkipSegment> segments;

  /// The subtitle file for the first of [languages] (such as `zh-Hans`)
  /// that has one, else the first file.
  File preferredSubtitle(List<String> languages) {
    for (final language in languages) {
      final match = subtitles.where((f) => f.path.toLowerCase().contains('.${language.trim().toLowerCase()}.')).firstOrNull;
      if (match != null) return match;
    }
    return subtitles.first;
  }

  /// The video codec of the file, from its sidecar; null when unknown.
  VideoCodec? get videoCodec => VideoCodec.of(info['vcodec']);

  /// The sidecar of [media]: the same name with `.info.json`.
  static File sidecarOf(String media) => File('${_base(media)}.info.json');

  static String _base(String media) {
    final dot = media.lastIndexOf('.');
    final slash = media.lastIndexOf(RegExp(r'[\\/]'));
    return dot > slash ? media.substring(0, dot) : media;
  }

  static LocalVideo read(File media) {
    var info = <String, dynamic>{};
    try {
      final data = jsonDecode(sidecarOf(media.path).readAsStringSync());
      if (data is Map<String, dynamic>) info = data;
    } catch (_) {
      // No sidecar: the file still plays.
    }
    final base = _base(media.path);
    final name = base.substring(base.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final subtitles = <File>[];
    try {
      for (final entity in media.parent.listSync(followLinks: false)) {
        final file = entity.uri.pathSegments.last;
        if (entity is File && file.startsWith('$name.') && RegExp(r'\.(vtt|srt|ass)$').hasMatch(file)) subtitles.add(entity);
      }
    } on FileSystemException {
      // Played without subtitles.
    }
    subtitles.sort((a, b) => a.path.compareTo(b.path));
    // Downloads made before the rename keep their data under 'ytplus'.
    final raw = ((info['lumtub'] ?? info['ytplus']) as Map?)?['sponsorblock'];
    final segments = <SkipSegment>[
      if (raw is List)
        for (final s in raw.whereType<Map>())
          if (s['start'] is int && s['end'] is int) SkipSegment(Duration(milliseconds: s['start'] as int), Duration(milliseconds: s['end'] as int), '${s['category']}'),
    ];
    return LocalVideo(media, info, subtitles, segments);
  }
}

/// The download queue: runs up to [maxConcurrent] yt-dlp processes, keeps the
/// list in [file] and finds the downloaded files for playback.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.file,
    required this.ytDlpPath,
    required String defaultDirectory,
    this.maxConcurrent = 2,
    ProcessStarter? start,
    this.environment,
    this.options,
    this.ffmpegDirectory,
    this.sponsorSegments,
  })  : _directory = defaultDirectory,
        _start = start ?? ProcessTree.start;

  /// Where the list and the folder setting are saved.
  final File file;
  final String ytDlpPath;
  final int maxConcurrent;
  final ProcessStarter _start;
  final Map<String, String> Function()? environment;
  final DownloadOptions Function()? options;
  /// The folder holding ffmpeg, or null without it.
  final String? Function()? ffmpegDirectory;
  /// SponsorBlock segments to keep with a finished download.
  final Future<List<SkipSegment>> Function(String videoId)? sponsorSegments;

  String _directory;
  DownloadDefaults _defaults = const DownloadDefaults();
  final List<DownloadTask> tasks = [];
  final _active = <String>{};
  final _processes = <String, Process>{};
  final _stopping = <String>{};
  /// Stopped downloads whose files are deleted once the process has exited,
  /// since Windows will not delete a file yt-dlp still has open.
  final _wipe = <String>{};
  DateTime _notified = DateTime(0);

  /// Ticks with download progress, at most twice a second. The manager itself
  /// only notifies when a task is added, removed or changes status, so the
  /// rest of the app is not rebuilt by progress.
  final progress = ValueNotifier<int>(0);
  Timer? _saveTimer;

  /// Where new downloads are saved.
  String get directory => _directory;

  /// What the download dialog chose last, offered again next time.
  DownloadDefaults get defaults => _defaults;

  /// Whether ffmpeg is there to merge video and audio streams.
  bool get canMerge => ffmpegDirectory?.call() != null;

  /// The folder for downloads when none was chosen: Videos\Lumtub.
  static String defaultDirectoryFor(Map<String, String> env, String fallback) {
    final home = env['USERPROFILE'];
    if (home == null || home.trim().isEmpty) return fallback;
    return '$home${Platform.pathSeparator}Videos${Platform.pathSeparator}Lumtub';
  }

  /// The directory holding ffmpeg among [directories] and `PATH`, or null.
  static String? findFfmpeg(Iterable<String> directories, String? path) {
    final name = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    for (final dir in [...directories, ...?path?.split(Platform.isWindows ? ';' : ':')]) {
      if (dir.isNotEmpty && File('$dir${Platform.pathSeparator}$name').existsSync()) return dir;
    }
    return null;
  }

  // Persistence.

  Future<void> load() async {
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is Map) {
        final dir = data['directory']?.toString();
        if (dir != null && dir.isNotEmpty) _directory = dir;
        _defaults = DownloadDefaults.fromJson(data['defaults']);
        for (final raw in data['tasks'] as List? ?? const []) {
          final task = DownloadTask.fromJson(raw);
          if (task == null) continue;
          // What the last run left half done continues.
          if (task.status == DownloadStatus.downloading) task.status = DownloadStatus.queued;
          tasks.add(task);
        }
      }
    } catch (_) {
      // No list yet, or an unreadable one: start empty.
    }
    notifyListeners();
    _pump();
  }

  Future<void> _saving = Future.value();

  /// Completes when every change so far is written, including one still
  /// waiting for its delay.
  Future<void> flush() {
    if (_saveTimer?.isActive ?? false) unawaited(_save());
    return _saving;
  }

  /// Writes are queued so a later state never lands before an earlier one.
  Future<void> _save() {
    _saveTimer?.cancel();
    return _saving = _saving.then((_) => _write());
  }

  /// Saves after a second of quiet, so a burst of changes is one write.
  void _saveSoon() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(seconds: 1), () => unawaited(_save()));
  }

  Future<void> _write() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'directory': _directory, 'defaults': _defaults.toJson(), 'tasks': tasks.map((t) => t.toJson()).toList()}), flush: true);
    } on FileSystemException catch (e) {
      logError('无法保存下载列表', e);
    }
  }

  Future<void> setDirectory(String path) async {
    _directory = path;
    notifyListeners();
    await _save();
  }

  Future<void> setDefaults(DownloadDefaults defaults) async {
    _defaults = defaults;
    await _save();
  }

  // Queue.

  DownloadTask? taskFor(String id) => tasks.where((t) => t.id == id).firstOrNull;

  /// Queues [item]; null when it is already downloaded or in the queue.
  DownloadTask? add(VideoItem item, DownloadQuality quality, {DownloadSelection? selection}) {
    final existing = taskFor(item.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.done && existing.filePath != null && File(existing.filePath!).existsSync()) return null;
      if (existing.active || existing.status == DownloadStatus.paused) return null;
      tasks.remove(existing);
    }
    final task = DownloadTask(item: item, quality: quality, directory: _directory, selection: selection);
    tasks.insert(0, task);
    _changed();
    return task;
  }

  void pause(String id) {
    final task = taskFor(id);
    if (task == null || !task.active) return;
    task.status = DownloadStatus.paused;
    task.speed = null;
    _stop(id);
    _changed();
  }

  void resume(String id) {
    final task = taskFor(id);
    if (task == null || task.status != DownloadStatus.paused) return;
    task.status = DownloadStatus.queued;
    _changed();
  }

  /// Stops [id] and drops what was downloaded so far.
  void cancel(String id) {
    final task = taskFor(id);
    if (task == null || !(task.active || task.status == DownloadStatus.paused)) return;
    task.status = DownloadStatus.cancelled;
    task.speed = null;
    unawaited(_wipeAfterStop(task));
    _changed();
  }

  void retry(String id) {
    final task = taskFor(id);
    if (task == null || (task.status != DownloadStatus.failed && task.status != DownloadStatus.cancelled)) return;
    task.status = DownloadStatus.queued;
    task.error = null;
    task.downloaded = 0;
    task.total = null;
    _changed();
  }

  /// Removes [id] from the list, and its files from disk when [deleteFiles].
  Future<void> remove(String id, {bool deleteFiles = false}) async {
    final task = taskFor(id);
    if (task == null) return;
    tasks.remove(task);
    _stop(id);
    _changed();
    if (deleteFiles) await _wipeAfterStop(task);
  }

  Future<void> _wipeAfterStop(DownloadTask task) async {
    if (_active.contains(task.id)) {
      _stop(task.id);
      _wipe.add(task.id);
    } else {
      await _deleteFiles(task);
    }
  }

  void _stop(String id) {
    final process = _processes[id];
    if (process == null) return;
    _stopping.add(id);
    process.kill();
  }

  void _changed() {
    notifyListeners();
    _saveSoon();
    _pump();
  }

  /// Starts queued tasks while there are free places.
  void _pump() {
    for (final task in tasks.reversed.toList()) {
      if (_active.length >= maxConcurrent) return;
      if (task.status != DownloadStatus.queued || _active.contains(task.id)) continue;
      _active.add(task.id);
      task.status = DownloadStatus.downloading;
      unawaited(_run(task));
    }
  }

  /// yt-dlp's arguments for [task].
  List<String> arguments(DownloadTask task) {
    final o = options?.call() ?? const DownloadOptions();
    final ffmpeg = ffmpegDirectory?.call();
    final selection = task.selection;
    final audio = selection?.audioOnly ?? task.quality.audioOnly;
    return [
      '--no-warnings',
      '--newline',
      '--progress',
      '--no-simulate',
      '--no-playlist',
      '--windows-filenames',
      '--extractor-retries', '3',
      '--retries', '10',
      '--fragment-retries', '10',
      if (o.cacheDirectory != null) ...['--cache-dir', o.cacheDirectory!],
      if (o.deno != null) ...['--js-runtimes', 'deno:${o.deno!}'],
      if (o.proxy != null) ...['--proxy', o.proxy!],
      '--paths', task.directory,
      '-o', '%(title).80B [%(id)s].%(ext)s',
      '--progress-template', DownloadProgress.progressTemplate,
      '--print', DownloadProgress.filePrint,
      '--write-info-json',
      '--format', selection?.format(merge: ffmpeg != null) ?? task.quality.format(merge: ffmpeg != null),
      // The container was chosen with the streams; the streams are copied,
      // never re-encoded. Otherwise MP4 plays everywhere and MKV takes the
      // codecs MP4 cannot hold.
      if (selection != null)
        ...selection.containerArguments(merge: ffmpeg != null)
      else if (ffmpeg != null && !audio)
        ...['--merge-output-format', 'mp4/mkv'],
      if (ffmpeg != null) ...['--ffmpeg-location', ffmpeg],
      if (!audio && o.subtitleLanguages != null) ...[
        '--write-subs',
        if (o.autoSubtitles) '--write-auto-subs',
        '--sub-langs', o.subtitleLanguages!,
        '--sub-format', 'vtt/best',
        '--sleep-subtitles', '1',
        // A subtitle YouTube refuses (429) is skipped, not the whole video.
        '--ignore-errors',
      ],
      '--', task.item.url,
    ];
  }

  Future<void> _run(DownloadTask task) async {
    final id = task.id;
    String? printed;
    final errors = <String>[];
    int exitCode;
    try {
      await Directory(task.directory).create(recursive: true);
      final env = {
        ...?environment?.call(),
        // So that titles in the printed path survive the pipe on Windows.
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
      };
      final process = await _start(ytDlpPath, arguments(task), environment: env);
      _processes[id] = process;
      lowerPriority(process.pid);
      // A pause that came while the process was starting.
      if (task.status != DownloadStatus.downloading) _stop(id);
      void line(String text) {
        final progress = DownloadProgress.parse(text);
        if (progress != null) {
          _progress(task, progress);
          return;
        }
        final path = DownloadProgress.parseFile(text);
        if (path != null) {
          printed = path;
        } else if (text.trim().isNotEmpty) {
          errors.add(text.trim());
          if (errors.length > 20) errors.removeAt(0);
        }
      }

      final decoder = const Utf8Decoder(allowMalformed: true);
      final done = [
        process.stdout.transform(decoder).transform(const LineSplitter()).forEach(line),
        process.stderr.transform(decoder).transform(const LineSplitter()).forEach(line),
      ];
      exitCode = await process.exitCode;
      await Future.wait(done);
    } catch (e) {
      errors.add('$e');
      exitCode = -1;
    }
    _processes.remove(id);
    if (_stopping.remove(id)) {
      // Paused, cancelled or removed: the status was set by the caller.
    } else if (exitCode == 0) {
      await _finish(task, printed);
    } else {
      task.status = DownloadStatus.failed;
      task.speed = null;
      task.error = errors.lastWhere((e) => e.startsWith('ERROR'), orElse: () => errors.isEmpty ? 'yt-dlp exited with code $exitCode' : errors.last);
    }
    if (_wipe.remove(id)) await _deleteFiles(task);
    _active.remove(id);
    _changed();
  }

  void _progress(DownloadTask task, DownloadProgress p) {
    task.downloaded = p.downloaded;
    task.total = p.total;
    task.speed = p.speed;
    task.eta = p.eta;
    // Twice a second is plenty for the page.
    final now = DateTime.now();
    if (p.finished || now.difference(_notified) >= const Duration(milliseconds: 500)) {
      _notified = now;
      progress.value++;
    }
  }

  Future<void> _finish(DownloadTask task, String? printed) async {
    var path = printed;
    if (path == null || !File(path).existsSync()) path = _findMedia(task);
    if (path == null) {
      task.status = DownloadStatus.failed;
      task.error = 'The downloaded file was not found';
      return;
    }
    task.filePath = path;
    task.status = DownloadStatus.done;
    task.speed = null;
    task.eta = null;
    task.downloaded = task.total ?? task.downloaded;
    try {
      await _writeSidecar(task, path);
    } catch (e) {
      logError('无法保存 ${task.id} 的离线信息', e);
    }
  }

  static const _sidecarKeys = [
    'id', 'title', 'channel', 'uploader', 'channel_url', 'channel_id', 'upload_date', 'view_count', 'like_count', 'description', 'duration', 'chapters', 'webpage_url', 'vcodec',
  ];

  /// Cuts yt-dlp's `.info.json` down to what the watch page shows (its
  /// format list is large and its addresses expire) and adds the
  /// SponsorBlock segments, so playback can restore both offline.
  Future<void> _writeSidecar(DownloadTask task, String media) async {
    final sidecar = LocalVideo.sidecarOf(media);
    var full = <String, dynamic>{};
    if (sidecar.existsSync()) {
      final data = jsonDecode(await sidecar.readAsString());
      if (data is Map<String, dynamic>) full = data;
    }
    List<SkipSegment> segments = const [];
    try {
      segments = await sponsorSegments?.call(task.id) ?? const [];
    } catch (_) {
      // Playback skips nothing offline then.
    }
    await sidecar.writeAsString(jsonEncode({
      for (final key in _sidecarKeys)
        if (full[key] != null) key: full[key],
      'lumtub': {
        'sponsorblock': [for (final s in segments) {'start': s.start.inMilliseconds, 'end': s.end.inMilliseconds, 'category': s.category}],
      },
    }), flush: true);
  }

  /// The media file of [task] in its folder, by the `[id]` in its name.
  String? _findMedia(DownloadTask task) {
    try {
      for (final entity in Directory(task.directory).listSync(followLinks: false)) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.contains('[${task.id}]') && RegExp(r'\.(mp4|m4a|webm|mkv|mp3|opus)$').hasMatch(name)) return entity.path;
      }
    } on FileSystemException {
      // Not found.
    }
    return null;
  }

  /// Every file Lumtub wrote for [task]: the video, partial data, sidecar
  /// and subtitles, which all carry the video id in their name.
  Future<void> _deleteFiles(DownloadTask task) async {
    try {
      final dir = Directory(task.directory);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File && entity.uri.pathSegments.last.contains('[${task.id}]')) {
          try {
            await entity.delete();
          } on FileSystemException {
            // Still in use; left for the user.
          }
        }
      }
    } on FileSystemException {
      // Nothing to delete.
    }
  }

  // Playback.

  /// The downloaded [id] when its file is still there.
  LocalVideo? localVideo(String id) {
    final task = taskFor(id);
    final path = task?.filePath;
    if (task == null || task.status != DownloadStatus.done || path == null) return null;
    final media = File(path);
    return media.existsSync() ? LocalVideo.read(media) : null;
  }

  @override
  void dispose() {
    for (final process in _processes.values) {
      process.kill();
    }
    _saveTimer?.cancel();
    progress.dispose();
    super.dispose();
  }
}
