import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'downloads/download_models.dart';

/// The on-demand ffmpeg component: yt-dlp needs ffmpeg and ffprobe to merge a
/// video stream with an audio stream. Lumtub builds its own in
/// https://github.com/0x696c757a696f/lumtub-media-builds (download-ffmpeg):
/// LGPL, static, with no codec libraries or hardware decoding, only what
/// merging and repackaging need, for x86-64, x86-64-v3 and ARM64. Each
/// archive's BUILD.txt names the FFmpeg source it was built from.

const ffmpegRepository = '0x696c757a696f/lumtub-media-builds';
/// Releases of [ffmpegRepository] holding download builds; the others hold
/// libmpv.
const ffmpegReleasePrefix = 'ffmpeg-';
const ffmpegChecksumsAsset = 'sha256.txt';

/// The newest published download-ffmpeg release among [releases], as the
/// GitHub API lists them (newest first).
Map<String, dynamic>? ffmpegRelease(Iterable<Object?> releases) {
  for (final release in releases) {
    if (release is! Map<String, dynamic> || release['draft'] == true || release['prerelease'] == true) continue;
    if ((release['tag_name']?.toString() ?? '').startsWith(ffmpegReleasePrefix)) return release;
  }
  return null;
}

/// The archive for [variant] (`x86_64`, `x86_64-v3` or `aarch64`, as
/// libmpvVariantForThisProcess names it) among the release's asset [names],
/// such as `ffmpeg-download-x86_64-v3-n8.1.3.zip`.
String? ffmpegAssetName(Iterable<String> names, String variant) {
  final pattern = RegExp('^ffmpeg-download-${RegExp.escape(variant)}-n\\d+\\.\\d+(?:\\.\\d+)?\\.zip\$');
  for (final name in names) {
    if (pattern.hasMatch(name)) return name;
  }
  return null;
}

/// The folder name for a build: its version from [assetName] and the date
/// the asset was [updatedAt] (ISO 8601), such as `n7.1-20261021`. A date in
/// the name makes newer builds sort last.
String ffmpegFolderName(String assetName, String? updatedAt) {
  final version = RegExp(r'-(n\d+\.\d+(?:\.\d+)?|master)(?:-|\.zip$)').firstMatch(assetName)?[1] ?? 'unknown';
  final date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(updatedAt ?? '');
  return date == null ? version : '$version-${date[1]}${date[2]}${date[3]}';
}

/// The hashes in a `sha256sum` style file: "HASH  NAME" or
/// "HASH *NAME" per line, by lowercase hash and file name.
Map<String, String> parseChecksums(String text) {
  final line = RegExp(r'^([a-fA-F0-9]{64})[ \t]+\*?(.+?)\s*$');
  return {
    for (final raw in const LineSplitter().convert(text))
      if (line.firstMatch(raw) case final match?) match[2]!: match[1]!.toLowerCase(),
  };
}

/// What to do when a download is started.
enum FfmpegChoice {
  /// Merge video and audio: ffmpeg is there.
  merge,
  /// Download the single-file format.
  singleFile,
  /// Ask whether to install ffmpeg first.
  ask,
}

/// Whether a download of [quality] merges, goes single-file or asks first.
FfmpegChoice ffmpegChoiceFor(DownloadQuality quality, {required bool installed, required bool declined}) {
  if (quality.audioOnly) return FfmpegChoice.singleFile;
  if (installed) return FfmpegChoice.merge;
  return declined ? FfmpegChoice.singleFile : FfmpegChoice.ask;
}

/// CRC-32 (zip) of [data], continuing from [crc].
int crc32(List<int> data, [int crc = 0]) {
  crc ^= 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// Writes `ffmpeg.exe`, `ffprobe.exe` and any DLLs of the zip [archive],
/// at its top or in `bin/`, into [into], flat, and nothing else (no ffplay, headers, docs). Returns the names written. Throws a
/// [FormatException] for a damaged archive or a failed CRC check.
Future<List<String>> extractFfmpegBinaries(File archive, Directory into) async {
  final wanted = RegExp(r'^(?:[^/]+/)?(?:bin/)?((?:ffmpeg|ffprobe)\.exe|[A-Za-z0-9_+-][A-Za-z0-9._+-]*\.dll)$', caseSensitive: false);
  final raf = await archive.open();
  try {
    final length = await raf.length();
    final tailStart = length > 65557 ? length - 65557 : 0;
    await raf.setPosition(tailStart);
    final tail = await raf.read(length - tailStart);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 5 && tail[i + 3] == 6) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('Not a zip archive');
    final end = ByteData.sublistView(tail, eocd);
    final count = end.getUint16(10, Endian.little);
    final dirSize = end.getUint32(12, Endian.little);
    final dirOffset = end.getUint32(16, Endian.little);
    if (count == 0xFFFF || dirSize == 0xFFFFFFFF || dirOffset == 0xFFFFFFFF) throw const FormatException('Zip64 is not supported');
    await raf.setPosition(dirOffset);
    final directory = ByteData.sublistView(await raf.read(dirSize));
    final bytes = directory.buffer.asUint8List(directory.offsetInBytes, directory.lengthInBytes);
    final written = <String>[];
    var p = 0;
    for (var i = 0; i < count; i++) {
      if (p + 46 > directory.lengthInBytes || directory.getUint32(p, Endian.little) != 0x02014b50) throw const FormatException('Damaged zip directory');
      final method = directory.getUint16(p + 10, Endian.little);
      final crc = directory.getUint32(p + 16, Endian.little);
      final packed = directory.getUint32(p + 20, Endian.little);
      final size = directory.getUint32(p + 24, Endian.little);
      final nameLength = directory.getUint16(p + 28, Endian.little);
      final skip = nameLength + directory.getUint16(p + 30, Endian.little) + directory.getUint16(p + 32, Endian.little);
      final offset = directory.getUint32(p + 42, Endian.little);
      final name = utf8.decode(bytes.sublist(p + 46, p + 46 + nameLength), allowMalformed: true).replaceAll('\\', '/');
      p += 46 + skip;
      final match = wanted.firstMatch(name);
      if (match == null) continue;
      await raf.setPosition(offset);
      final local = ByteData.sublistView(await raf.read(30));
      if (local.getUint32(0, Endian.little) != 0x04034b50) throw const FormatException('Damaged zip entry');
      final start = offset + 30 + local.getUint16(26, Endian.little) + local.getUint16(28, Endian.little);
      if (method != 0 && method != 8) throw FormatException('Unsupported zip compression $method');
      final target = File('${into.path}${Platform.pathSeparator}${match[1]!}');
      var checksum = 0;
      var total = 0;
      final sink = target.openWrite();
      try {
        Stream<List<int>> data = archive.openRead(start, start + packed);
        if (method == 8) data = data.transform(ZLibDecoder(raw: true));
        await for (final chunk in data) {
          checksum = crc32(chunk, checksum);
          total += chunk.length;
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      if (total != size || checksum != crc) {
        await target.delete();
        throw FormatException('Zip entry $name is damaged');
      }
      written.add(target.uri.pathSegments.last);
    }
    return written;
  } finally {
    await raf.close();
  }
}
