import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/downloads/download_formats.dart';
import 'package:lumtub/downloads/download_manager.dart';
import 'package:lumtub/downloads/download_models.dart';
import 'package:lumtub/downloads/download_selection.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/download_dialog.dart';
import 'package:lumtub/video_codec.dart';

Map<String, dynamic> v(String id, String vcodec, int height, String ext, {double fps = 30, double tbr = 1000, int? size, String? range}) => {
      'format_id': id, 'vcodec': vcodec, 'acodec': 'none', 'height': height, 'fps': fps, 'ext': ext, 'tbr': tbr, 'url': 'http://x/$id', 'protocol': 'https',
      if (size != null) 'filesize': size,
      if (range != null) 'dynamic_range': range,
    };
Map<String, dynamic> a(String id, String acodec, String ext, double abr, {int? size, Map<String, dynamic>? extra}) =>
    {'format_id': id, 'vcodec': 'none', 'acodec': acodec, 'ext': ext, 'abr': abr, 'url': 'http://x/$id', 'protocol': 'https', if (size != null) 'filesize_approx': size, ...?extra};

Map<String, dynamic> info() => {
      'formats': [
        {'format_id': 'sb0', 'ext': 'mhtml', 'vcodec': 'none', 'acodec': 'none', 'url': 'http://x/sb', 'protocol': 'mhtml'},
        {'format_id': 'nourl', 'vcodec': 'avc1.4d401f', 'acodec': 'none', 'height': 720, 'ext': 'mp4'},
        {'format_id': '18', 'vcodec': 'avc1.42001E', 'acodec': 'mp4a.40.2', 'height': 360, 'ext': 'mp4', 'url': 'http://x/18', 'protocol': 'https'},
        v('401', 'av01.0.12M.08', 2160, 'mp4', tbr: 9000, size: 900000000),
        v('400', 'av01.0.08M.08', 1440, 'mp4', tbr: 5000),
        v('313', 'vp09.00.51.08', 2160, 'webm', tbr: 8000, size: 800000000),
        v('271', 'vp9', 1440, 'webm', tbr: 5000),
        v('248', 'vp09.00.40.08', 1080, 'webm', tbr: 2500, size: 600000000),
        v('303', 'vp09.00.40.08', 1080, 'webm', fps: 60, tbr: 3500, size: 700000000),
        v('137', 'avc1.640028', 1080, 'mp4', tbr: 4000, size: 650000000),
        v('136', 'avc1.4d401f', 720, 'mp4', tbr: 2000),
        a('140', 'mp4a.40.2', 'm4a', 129.5, size: 10000000),
        a('251', 'opus', 'webm', 130, size: 11000000),
        a('251-drc', 'opus', 'webm', 130),
        a('139', 'mp4a.40.5', 'm4a', 48),
      ],
    };

DownloadFormats parsed({bool av1 = true}) {
  final data = info();
  if (!av1) (data['formats'] as List).removeWhere((f) => (f as Map)['vcodec'].toString().startsWith('av01'));
  return DownloadFormats.parse(data);
}

void main() {
  group('parsing', () {
    test('keeps video-only and audio-only formats with an address', () {
      final f = parsed();
      expect(f.video.map((e) => e.id), ['401', '400', '313', '271', '248', '303', '137', '136']);
      expect(f.audio.map((e) => e.id), ['140', '251', '139']);
      expect(f.video.firstWhere((e) => e.id == '313').codec, VideoCodec.vp9);
      expect(f.video.firstWhere((e) => e.id == '271').codec, VideoCodec.vp9);
      expect(f.video.first.size, 900000000);
      expect(f.audio.first.size, 10000000);
      expect(f.audio.first.abr, 129.5);
    });

    test('has no formats for something that is not a format list', () {
      expect(DownloadFormats.parse({}).isEmpty, isTrue);
      expect(DownloadFormats.parse({'formats': 'x'}).isEmpty, isTrue);
    });

    test('lists the codecs of the video in dialog order', () {
      expect(parsed().codecs, [VideoCodec.vp9, VideoCodec.av1, VideoCodec.h264]);
      expect(parsed(av1: false).codecs, [VideoCodec.vp9, VideoCodec.h264]);
    });
  });

  group('heights and picking', () {
    test('offers only the heights of the codec', () {
      final f = parsed();
      expect(f.heightsFor(null), [2160, 1440, 1080, 720]);
      expect(f.heightsFor(VideoCodec.av1), [2160, 1440]);
      expect(f.heightsFor(VideoCodec.h264), [1080, 720]);
    });

    test('a codec that tops out lower does not offer 4K', () {
      final f = DownloadFormats.parse({'formats': [v('401', 'av01.0.08M.08', 1080, 'mp4'), v('313', 'vp09.00.51.08', 2160, 'webm')]});
      expect(f.heightsFor(VideoCodec.av1), [1080]);
      expect(f.pickVideo(VideoCodec.av1)!.id, '401');
    });

    test('takes the highest height by default, else the nearest below the wish', () {
      final f = parsed();
      expect(f.pickVideo(VideoCodec.vp9)!.id, '313');
      expect(f.pickVideo(VideoCodec.vp9, height: 1200)!.id, '303');
      expect(f.pickVideo(VideoCodec.h264, height: 4320)!.id, '137');
      expect(f.pickVideo(VideoCodec.h264, height: 480)!.id, '136');
      expect(f.pickVideo(VideoCodec.vp8), isNull);
    });

    test('prefers 60 fps, SDR, then the better codec', () {
      final f = parsed();
      expect(f.pickVideo(VideoCodec.vp9, height: 1080)!.id, '303');
      expect(f.pickVideo(null)!.id, '401'); // AV1 over VP9 at 4K
      final hdr = DownloadFormats.parse({'formats': [v('a', 'vp09.02.51.10', 1080, 'webm', tbr: 9000, range: 'HDR10'), v('b', 'vp09.00.40.08', 1080, 'webm', range: 'SDR')]});
      expect(hdr.pickVideo(null)!.id, 'b');
    });

    test('prefers the original language, then the bitrate, and skips DRC copies', () {
      final f = DownloadFormats.parse({
        'formats': [
          a('251-de', 'opus', 'webm', 130, extra: {'language_preference': -1}),
          a('251-en', 'opus', 'webm', 130, extra: {'language_preference': 10}),
          a('250-en', 'opus', 'webm', 70, extra: {'language_preference': 10}),
          a('251-drc', 'opus', 'webm', 200, extra: {'format_note': 'Medium, DRC'}),
        ],
      });
      expect(f.audioBest.map((e) => e.id), ['251-en', '250-en', '251-de']);
    });
  });

  group('containers', () {
    final audio = parsed().audioBest;
    test('auto: mp4 for H.264 with AAC, webm when everything fits, else mkv', () {
      var plan = planContainer(DownloadContainer.auto, VideoCodec.h264, audio);
      expect((plan.container, plan.audio!.id), (DownloadContainer.mp4, '140'));
      plan = planContainer(DownloadContainer.auto, VideoCodec.vp9, audio);
      expect((plan.container, plan.audio!.id), (DownloadContainer.webm, '251'));
      plan = planContainer(DownloadContainer.auto, VideoCodec.av1, audio);
      expect(plan.container, DownloadContainer.webm);
      expect(planContainer(DownloadContainer.auto, VideoCodec.h264, [audio.firstWhere((a) => a.id == '251')]).container, DownloadContainer.mkv);
      expect(planContainer(DownloadContainer.auto, VideoCodec.vp8, audio.where((a) => a.isAac).toList()).container, DownloadContainer.mkv);
    });

    test('mp4 holds AV1, VP9 and H.264 with AAC (or Opus) but not VP8', () {
      for (final c in [VideoCodec.av1, VideoCodec.vp9, VideoCodec.h264]) {
        final plan = planContainer(DownloadContainer.mp4, c, audio);
        expect(plan.problem, isNull);
        expect(plan.audio!.id, '140');
      }
      expect(planContainer(DownloadContainer.mp4, VideoCodec.vp9, audio.where((a) => a.isOpus).toList()).audio!.id, '251');
      expect(planContainer(DownloadContainer.mp4, VideoCodec.vp8, audio).problem, 'MP4 不能容纳 VP8');
    });

    test('webm takes Opus and not H.264', () {
      expect(planContainer(DownloadContainer.webm, VideoCodec.vp9, audio).audio!.id, '251');
      expect(planContainer(DownloadContainer.webm, VideoCodec.h264, audio).problem, 'WebM 不能容纳 H.264');
      expect(planContainer(DownloadContainer.webm, VideoCodec.vp9, audio.where((a) => a.isAac).toList()).problem, 'WebM 没有可用的音轨');
    });

    test('mkv takes anything', () {
      final plan = planContainer(DownloadContainer.mkv, VideoCodec.h264, audio);
      expect(plan.problem, isNull);
      expect(plan.audio, isNotNull);
    });
  });

  group('selection', () {
    test('locks the picked ids and sums the sizes', () {
      final plan = planDownload(parsed(), codec: VideoCodec.vp9, height: 1080);
      final s = plan.selection!;
      expect((s.videoId, s.audioId, s.container, s.size), ('303', '251', DownloadContainer.webm, 711000000));
      expect(s.label, 'VP9 · 1080p · WebM');
    });

    test('is missing for a container that does not fit, with the reason', () {
      final plan = planDownload(parsed(), codec: VideoCodec.h264, container: DownloadContainer.webm);
      expect(plan.selection, isNull);
      expect(plan.problem, 'WebM 不能容纳 H.264');
    });

    test('audio only takes the best m4a', () {
      final s = planDownload(parsed(), audioOnly: true).selection!;
      expect((s.audioOnly, s.audioId, s.videoId), (true, '140', null));
      expect(s.format(merge: true), '140');
      expect(s.containerArguments(merge: true), isEmpty);
    });

    test('yt-dlp format and container arguments', () {
      final s = planDownload(parsed(), codec: VideoCodec.av1, container: DownloadContainer.mp4).selection!;
      expect(s.format(merge: true), '401+140');
      expect(s.containerArguments(merge: true), ['--merge-output-format', 'mp4']);
      expect(s.format(merge: false), 'b[height<=2160][ext=mp4]/b[height<=2160]/b[ext=mp4]/b');
      expect(s.containerArguments(merge: false), isEmpty);
    });

    test('round-trips through json and ignores a broken one', () {
      final s = planDownload(parsed(), codec: VideoCodec.h264).selection!;
      final back = DownloadSelection.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
      expect((back.videoId, back.audioId, back.codec, back.height, back.container, back.size), ('137', '140', VideoCodec.h264, 1080, DownloadContainer.mp4, 660000000));
      expect(DownloadSelection.fromJson({'container': 'mkv'}), isNull);
      expect(DownloadSelection.fromJson('x'), isNull);
    });

    test('defaults survive unknown values', () {
      final d = DownloadDefaults.fromJson({'codec': 'av1', 'height': 1080, 'container': 'webm'});
      expect((d.videoCodec, d.height, d.container), (VideoCodec.av1, 1080, DownloadContainer.webm));
      expect(DownloadDefaults.fromJson({'codec': 'bogus', 'container': 'x'}).codec, 'auto');
      expect(DownloadDefaults.fromJson(null).container, DownloadContainer.auto);
    });
  });

  group('download task', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('lumtub_dl_formats'));
    tearDown(() async {
      for (var i = 0; ; i++) {
        try {
          return await dir.delete(recursive: true);
        } on FileSystemException {
          if (i == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    final item = VideoItem(id: 'aaaaaaaaaaa', title: 'T', channel: 'C', url: 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
    DownloadManager manager({String? ffmpeg}) => DownloadManager(
        file: File('${dir.path}/downloads.json'),
        ytDlpPath: 'yt-dlp',
        defaultDirectory: dir.path,
        ffmpegDirectory: () => ffmpeg,
        // yt-dlp never starts.
        start: (exe, args, {environment}) => Completer<Process>().future,
      );

    test('locks the format ids and the container', () {
      final s = planDownload(parsed(), codec: VideoCodec.vp9, height: 1440, container: DownloadContainer.mkv).selection!;
      final args = manager(ffmpeg: 'F').arguments(DownloadTask(item: item, quality: DownloadQuality.best, directory: 'D', selection: s));
      expect(args[args.indexOf('--format') + 1], '271+251');
      expect(args[args.indexOf('--merge-output-format') + 1], 'mkv');
      expect(args, isNot(contains('--remux-video')));
      expect(args, contains('--ffmpeg-location'));
    });

    test('downloads the audio id alone without a merge', () {
      final s = planDownload(parsed(), audioOnly: true).selection!;
      final args = manager(ffmpeg: 'F').arguments(DownloadTask(item: item, quality: DownloadQuality.audio, directory: 'D', selection: s));
      expect(args[args.indexOf('--format') + 1], '140');
      expect(args, isNot(contains('--merge-output-format')));
    });

    test('without ffmpeg takes a single-file format at most that tall', () {
      final s = planDownload(parsed(), codec: VideoCodec.h264).selection!;
      final args = manager().arguments(DownloadTask(item: item, quality: DownloadQuality.best, directory: 'D', selection: s));
      expect(args[args.indexOf('--format') + 1], startsWith('b[height<=1080]'));
      expect(args, isNot(contains('--merge-output-format')));
    });

    test('a task saved by an earlier version still loads and downloads', () {
      final old = {'item': item.toJson(), 'quality': 'p720', 'directory': 'D', 'status': 'done', 'added': DateTime(2026).toIso8601String()};
      final task = DownloadTask.fromJson(old)!;
      expect(task.selection, isNull);
      expect(task.quality, DownloadQuality.p720);
      expect(task.qualityLabel, '720p');
      final args = manager(ffmpeg: 'F').arguments(task);
      expect(args[args.indexOf('--format') + 1], contains('height<=720'));
      expect(args[args.indexOf('--merge-output-format') + 1], 'mp4/mkv');
    });

    test('a task with a selection and the remembered choices survive a restart', () async {
      final m = manager();
      final s = planDownload(parsed(), codec: VideoCodec.h264).selection!;
      m.add(item, DownloadQuality.best, selection: s);
      await m.setDefaults(const DownloadDefaults(codec: 'h264', height: 720, container: DownloadContainer.mp4));
      await m.flush();
      final again = manager();
      await again.load();
      expect(again.tasks.single.selection!.videoId, '137');
      expect(again.tasks.single.qualityLabel, 'H.264 · 1080p · MP4');
      expect(again.defaults.codec, 'h264');
      expect(again.defaults.height, 720);
      expect(again.defaults.container, DownloadContainer.mp4);
      await again.flush();
    });
  });

  group('dialog', () {
    Future<void> open(WidgetTester tester, Future<DownloadFormats> Function() load, {DownloadDefaults defaults = const DownloadDefaults(), void Function(DownloadChoice?)? onClosed}) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final choice = await showDialog<DownloadChoice>(context: context, builder: (_) => DownloadDialog(title: 'Title', loadFormats: load, defaults: defaults));
              onClosed?.call(choice);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
    }

    testWidgets('lists only the codecs and heights the video has', (tester) async {
      await open(tester, () async => parsed(av1: false));
      await tester.pumpAndSettle();
      expect(find.text('VP9'), findsOneWidget);
      expect(find.text('AV1'), findsNothing);
      expect(find.text('H.264'), findsOneWidget);
      expect(find.text('仅音频'), findsOneWidget);
      expect(find.text('自动（最佳可用格式）'), findsOneWidget);
      expect(find.text('2160p'), findsOneWidget);
      expect(find.textContaining('当前选择：VP9 · 2160p · 自动封装（WebM）'), findsOneWidget);
      await tester.tap(find.text('H.264'));
      await tester.pump();
      expect(find.text('2160p'), findsNothing);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.textContaining('H.264 · 1080p · 自动封装（MP4）'), findsOneWidget);
    });

    testWidgets('shows a loading indicator while the formats are read', (tester) async {
      await open(tester, () => Future.delayed(const Duration(seconds: 1), parsed));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('AV1 topping out at 1440p does not offer 4K, and WebM is disabled for H.264', (tester) async {
      await open(tester, () async => DownloadFormats.parse({'formats': [v('400', 'av01.0.08M.08', 1440, 'mp4'), v('313', 'vp09.00.51.08', 2160, 'webm'), v('137', 'avc1.640028', 1080, 'mp4'), a('140', 'mp4a.40.2', 'm4a', 129), a('251', 'opus', 'webm', 130)]}));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AV1'));
      await tester.pump();
      expect(find.text('2160p'), findsNothing);
      expect(find.text('1440p'), findsOneWidget);
      await tester.tap(find.text('H.264'));
      await tester.pump();
      expect(find.text('WebM：WebM 不能容纳 H.264'), findsOneWidget);
      final webm = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'WebM'));
      expect(webm.onSelected, isNull);
    });

    testWidgets('a remembered codec the video lacks is reported and nothing is chosen for the user', (tester) async {
      await open(tester, () async => parsed(av1: false), defaults: const DownloadDefaults(codec: 'av1', height: 1080));
      await tester.pumpAndSettle();
      expect(find.text('该视频没有 AV1 格式，请选择其他编码'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      await tester.tap(find.text('H.264'));
      await tester.pump();
      expect(find.text('该视频没有 AV1 格式，请选择其他编码'), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    });

    testWidgets('preselects the remembered options and returns the choice to remember', (tester) async {
      DownloadChoice? choice;
      await open(tester, () async => parsed(), defaults: const DownloadDefaults(codec: 'vp9', height: 1440, container: DownloadContainer.mp4), onClosed: (c) => choice = c);
      await tester.pumpAndSettle();
      expect(find.textContaining('VP9 · 1440p · MP4'), findsOneWidget);
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect(choice!.selection!.videoId, '271');
      expect(choice!.selection!.audioId, '140');
      expect(choice!.quality, DownloadQuality.best);
      expect((choice!.defaults!.codec, choice!.defaults!.height, choice!.defaults!.container), ('vp9', 1440, DownloadContainer.mp4));
    });

    testWidgets('a remembered container that does not fit goes back to auto, with a note', (tester) async {
      await open(tester, () async => parsed(), defaults: const DownloadDefaults(codec: 'h264', container: DownloadContainer.webm));
      await tester.pumpAndSettle();
      expect(find.textContaining('已改为自动封装'), findsOneWidget);
      expect(find.textContaining('H.264 · 1080p · 自动封装（MP4）'), findsOneWidget);
    });

    testWidgets('when the formats cannot be read it shows the error and the simple choices', (tester) async {
      DownloadChoice? choice;
      await open(tester, () => Future.error(StateError('boom')), onClosed: (c) => choice = c);
      await tester.pumpAndSettle();
      expect(find.textContaining('无法读取视频格式：boom'), findsOneWidget);
      for (final q in DownloadQuality.values) {
        expect(find.text(q.label), findsOneWidget);
      }
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();
      expect(choice!.quality, DownloadQuality.p720);
      expect(choice!.selection, isNull);
    });
  });
}
