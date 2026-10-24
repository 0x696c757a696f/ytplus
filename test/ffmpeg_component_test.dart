import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/downloads/download_models.dart';
import 'package:lumtub/ffmpeg_component.dart';

/// A zip with [entries] (name -> bytes), deflated, written the way zip tools do.
Uint8List _zip(Map<String, List<int>> entries, {bool corruptCrc = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  entries.forEach((name, data) {
    final packed = ZLibCodec(raw: true).encode(data);
    final nameBytes = utf8.encode(name);
    final crc = crc32(data) ^ (corruptCrc ? 1 : 0);
    ByteData header(int size) => ByteData(size);
    final local = header(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, 8, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, data.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    final offset = out.length;
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(packed);
    final entry = header(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, 8, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(entry.buffer.asUint8List())
      ..add(nameBytes);
    count++;
  });
  final dirOffset = out.length;
  out.add(central.toBytes());
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, dirOffset, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  test('picks the archive for this CPU from the newest download release', () {
    const names = [
      'sha256.txt',
      'ffmpeg-download-x86_64-n8.1.3.zip',
      'ffmpeg-download-x86_64-v3-n8.1.3.zip',
      'ffmpeg-download-aarch64-n8.1.3.zip',
      'mpv-dev-x86_64-20261024-git-abc.7z',
    ];
    expect(ffmpegAssetName(names, 'x86_64'), 'ffmpeg-download-x86_64-n8.1.3.zip');
    expect(ffmpegAssetName(names, 'x86_64-v3'), 'ffmpeg-download-x86_64-v3-n8.1.3.zip');
    expect(ffmpegAssetName(names, 'aarch64'), 'ffmpeg-download-aarch64-n8.1.3.zip');
    expect(ffmpegAssetName(names.where((n) => !n.contains('aarch64')), 'aarch64'), isNull);

    final release = ffmpegRelease([
      {'tag_name': 'ffmpeg-n8.2-20261101-9', 'draft': true},
      {'tag_name': '2026-10-24-abc', 'draft': false},
      {'tag_name': 'ffmpeg-n8.1.3-20261024-3', 'draft': false, 'prerelease': false},
      {'tag_name': 'ffmpeg-n8.1.2-20261001-1', 'draft': false},
    ]);
    expect(release?['tag_name'], 'ffmpeg-n8.1.3-20261024-3');
    expect(ffmpegRelease(const [{'tag_name': '2026-10-24-abc'}]), isNull);
  });

  test('folder names carry the version and the asset date', () {
    expect(ffmpegFolderName('ffmpeg-n7.1-latest-win64-lgpl-shared-7.1.zip', '2026-10-21T03:04:05Z'), 'n7.1-20261021');
    expect(ffmpegFolderName('ffmpeg-master-latest-win64-lgpl-shared.zip', null), 'master');
    expect(ffmpegFolderName('ffmpeg-download-x86_64-v3-n8.1.3.zip', '2026-10-24T11:00:00Z'), 'n8.1.3-20261024');
  });

  test('parses checksum files', () {
    final hash = 'A' * 64;
    final other = 'b' * 64;
    final sums = parseChecksums('$hash *ffmpeg-a.zip\r\n$other  ffmpeg b.zip\nnot a line\n${'c' * 63} short.zip\n');
    expect(sums, {'ffmpeg-a.zip': 'a' * 64, 'ffmpeg b.zip': other});
  });

  test('crc32 matches the zip standard', () {
    expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    expect(crc32(utf8.encode('6789'), crc32(utf8.encode('12345'))), 0xCBF43926);
  });

  group('extraction', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('lumtub_ffmpeg'));
    tearDown(() => temp.deleteSync(recursive: true));

    final exe = List<int>.generate(5000, (i) => i % 251);

    test('keeps only ffmpeg, ffprobe and the DLLs from bin/', () async {
      final archive = File('${temp.path}/ffmpeg.zip')
        ..writeAsBytesSync(_zip({
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/bin/ffmpeg.exe': exe,
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/bin/ffprobe.exe': [1, 2, 3],
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/bin/ffplay.exe': [9, 9],
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/bin/avcodec-61.dll': utf8.encode('dll'),
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/bin/readme.txt': [4],
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/lib/avcodec.lib': [5],
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/include/libavcodec/avcodec.h': [6],
          'ffmpeg-n7.1-latest-win64-lgpl-shared-7.1/LICENSE.txt': [7],
          '../bin/evil.dll/../../x': [8],
        }));
      final out = Directory('${temp.path}/out')..createSync();
      final written = await extractFfmpegBinaries(archive, out);
      expect(written.toSet(), {'ffmpeg.exe', 'ffprobe.exe', 'avcodec-61.dll'});
      expect(out.listSync().map((e) => e.uri.pathSegments.last).toSet(), {'ffmpeg.exe', 'ffprobe.exe', 'avcodec-61.dll'});
      expect(File('${out.path}/ffmpeg.exe').readAsBytesSync(), exe);
      expect(File('${out.path}/ffprobe.exe').readAsBytesSync(), [1, 2, 3]);
    });

    test('reads the flat download-ffmpeg archive', () async {
      final archive = File('${temp.path}/flat.zip')
        ..writeAsBytesSync(_zip({'ffmpeg.exe': exe, 'ffprobe.exe': [1], 'BUILD.txt': [2], 'COPYING.LGPLv2.1': [3]}));
      final out = Directory('${temp.path}/out')..createSync();
      expect((await extractFfmpegBinaries(archive, out)).toSet(), {'ffmpeg.exe', 'ffprobe.exe'});
    });

    test('refuses a damaged entry and a file that is not a zip', () async {
      final bad = File('${temp.path}/bad.zip')..writeAsBytesSync(_zip({'x/bin/ffmpeg.exe': exe}, corruptCrc: true));
      final out = Directory('${temp.path}/out')..createSync();
      await expectLater(extractFfmpegBinaries(bad, out), throwsFormatException);
      expect(out.listSync(), isEmpty);
      final junk = File('${temp.path}/junk.zip')..writeAsBytesSync(List.filled(100, 7));
      await expectLater(extractFfmpegBinaries(junk, out), throwsFormatException);
    });
  });

  test('a checksum mismatch is detected by comparing against the listed hash', () {
    // ToolManager compares the SHA-256 of the download with this value and
    // deletes the file on a mismatch; here the parsing side is covered.
    final data = utf8.encode('archive');
    final good = sha256.convert(data).toString();
    final sums = parseChecksums('$good  a.zip\n${'0' * 64}  b.zip\n');
    expect(sums['a.zip'], good);
    expect(sums['b.zip'], isNot(good));
    expect(sums['c.zip'], isNull);
  });

  group('on-demand decision', () {
    test('missing asks, declined goes single-file, installed merges', () {
      expect(ffmpegChoiceFor(DownloadQuality.best, installed: false, declined: false), FfmpegChoice.ask);
      expect(ffmpegChoiceFor(DownloadQuality.p720, installed: false, declined: false), FfmpegChoice.ask);
      expect(ffmpegChoiceFor(DownloadQuality.best, installed: false, declined: true), FfmpegChoice.singleFile);
      expect(ffmpegChoiceFor(DownloadQuality.best, installed: true, declined: false), FfmpegChoice.merge);
      expect(ffmpegChoiceFor(DownloadQuality.best, installed: true, declined: true), FfmpegChoice.merge);
    });

    test('audio never needs ffmpeg', () {
      expect(ffmpegChoiceFor(DownloadQuality.audio, installed: false, declined: false), FfmpegChoice.singleFile);
    });

    test('the decline choice is remembered in the preferences', () {
      expect(const AppPreferences().skipFfmpegPrompt, isFalse);
      final saved = AppPreferences.fromJson(const AppPreferences().copyWith(skipFfmpegPrompt: true).toJson());
      expect(saved.skipFfmpegPrompt, isTrue);
    });
  });
}
