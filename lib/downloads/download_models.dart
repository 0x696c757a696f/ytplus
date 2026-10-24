import '../l10n/l10n.dart';
import '../models.dart';
import 'download_selection.dart';

/// What to download. Without ffmpeg yt-dlp cannot merge a video stream with
/// an audio stream, so the video qualities then take the best single-file
/// (progressive) format, which on YouTube is usually 360p.
enum DownloadQuality {
  best('最高画质', null),
  p1080('1080p', 1080),
  p720('720p', 720),
  audio('仅音频（m4a）', null, audioOnly: true);

  const DownloadQuality(this._label, this.maxHeight, {this.audioOnly = false});
  final String _label;
  String get label => tr(_label);
  /// The tallest video to take, or null for the best there is.
  final int? maxHeight;
  final bool audioOnly;

  /// yt-dlp's `--format`. [merge]: ffmpeg is available to join streams.
  String format({required bool merge}) {
    if (audioOnly) return 'ba[ext=m4a]/ba';
    final h = maxHeight == null ? '' : '[height<=$maxHeight]';
    if (!merge) return h.isEmpty ? 'b[ext=mp4]/b' : 'b$h[ext=mp4]/b$h/b[ext=mp4]/b';
    // The best streams whatever their codec (AV1, VP9, Opus); the container
    // is chosen to fit them.
    return h.isEmpty ? 'bv*+ba/b' : 'bv*$h+ba/b$h/b';
  }
}

enum DownloadStatus { queued, downloading, paused, done, failed, cancelled }

/// One progress line of yt-dlp, printed with [progressTemplate].
class DownloadProgress {
  const DownloadProgress({this.downloaded = 0, this.total, this.speed, this.eta, this.finished = false});
  final int downloaded;
  final int? total;
  /// Bytes per second.
  final double? speed;
  final int? eta;
  /// The current stream is complete (a video may have several).
  final bool finished;

  double? get fraction => total == null || total == 0 ? null : (downloaded / total!).clamp(0.0, 1.0);

  static const progressTemplate =
      'download:lumtub|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s';

  /// Prefix of the line that names the finished file.
  static const filePrefix = 'lumtub-file|';
  static const filePrint = 'after_move:$filePrefix%(filepath)s';

  /// The progress in [line], or null for any other output.
  static DownloadProgress? parse(String line) {
    if (!line.startsWith('lumtub|')) return null;
    final parts = line.trim().split('|');
    if (parts.length < 7) return null;
    num? number(String s) => s == 'NA' || s.isEmpty ? null : num.tryParse(s);
    final total = number(parts[3]) ?? number(parts[4]);
    return DownloadProgress(
      downloaded: number(parts[2])?.toInt() ?? 0,
      total: total?.toInt(),
      speed: number(parts[5])?.toDouble(),
      eta: number(parts[6])?.toInt(),
      finished: parts[1] == 'finished',
    );
  }

  /// The path in a [filePrint] line, or null.
  static String? parseFile(String line) {
    if (!line.startsWith(filePrefix)) return null;
    final path = line.substring(filePrefix.length).trim();
    return path.isEmpty ? null : path;
  }
}

class DownloadTask {
  DownloadTask({
    required this.item,
    required this.quality,
    required this.directory,
    this.selection,
    this.status = DownloadStatus.queued,
    this.filePath,
    this.error,
    DateTime? added,
  }) : added = added ?? DateTime.now();

  final VideoItem item;
  /// The simple choice; for a task with a [selection] only whether it is audio.
  final DownloadQuality quality;
  /// The formats picked in the download dialog; null for a task added with
  /// just a [quality], such as one saved by an earlier version.
  final DownloadSelection? selection;
  /// The folder it is saved in, as chosen when it was added.
  final String directory;
  DownloadStatus status;
  String? filePath;
  String? error;
  final DateTime added;

  // Live values, not saved.
  int downloaded = 0;
  int? total;
  double? speed;
  int? eta;

  String get id => item.id;

  double? get fraction => total == null || total == 0 ? null : (downloaded / total!).clamp(0.0, 1.0);

  /// The quality or selection as the downloads list shows it.
  String get qualityLabel => selection?.label ?? quality.label;

  bool get active => status == DownloadStatus.queued || status == DownloadStatus.downloading;

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'quality': quality.name,
        if (selection != null) 'selection': selection!.toJson(),
        'directory': directory,
        'status': status.name,
        if (filePath != null) 'file': filePath,
        if (error != null) 'error': error,
        'added': added.toIso8601String(),
      };

  static DownloadTask? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final item = VideoItem.fromJson(Map<String, dynamic>.from(raw['item'] as Map));
      final directory = raw['directory']?.toString() ?? '';
      if (item.id.isEmpty || directory.isEmpty) return null;
      final selection = DownloadSelection.fromJson(raw['selection']);
      return DownloadTask(
        item: item,
        quality: DownloadQuality.values.where((q) => q.name == raw['quality']).firstOrNull ?? DownloadQuality.best,
        selection: selection,
        directory: directory,
        status: DownloadStatus.values.where((s) => s.name == raw['status']).firstOrNull ?? DownloadStatus.failed,
        filePath: raw['file']?.toString(),
        error: raw['error']?.toString(),
        added: DateTime.tryParse(raw['added']?.toString() ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}
