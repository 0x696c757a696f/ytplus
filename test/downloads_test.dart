import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/video_codec.dart';
import 'package:lumtub/downloads/download_manager.dart';
import 'package:lumtub/downloads/download_models.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/sponsor_block.dart';

class FakeProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  void out(String line) => _stdout.add(utf8.encode('$line\n'));
  void err(String line) => _stderr.add(utf8.encode('$line\n'));
  Future<void> exit(int code) async {
    await _stdout.close();
    await _stderr.close();
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    unawaited(exit(-15));
    return true;
  }

  @override
  int get pid => 1;
  @override
  IOSink get stdin => throw UnimplementedError();
}

VideoItem video(String id) => VideoItem(id: id, title: 'Video $id', channel: 'Channel', url: 'https://www.youtube.com/watch?v=$id');

void main() {
  group('progress lines', () {
    test('parses bytes, speed and eta', () {
      final p = DownloadProgress.parse('lumtub|downloading|524288|1048576|NA|2097152.5|12')!;
      expect(p.downloaded, 524288);
      expect(p.total, 1048576);
      expect(p.speed, 2097152.5);
      expect(p.eta, 12);
      expect(p.fraction, 0.5);
      expect(p.finished, isFalse);
    });

    test('falls back to the estimated total and tolerates NA', () {
      final p = DownloadProgress.parse('lumtub|downloading|1000|NA|4000|NA|NA')!;
      expect(p.total, 4000);
      expect(p.speed, isNull);
      expect(p.eta, isNull);
      expect(DownloadProgress.parse('lumtub|finished|100|100|NA|NA|NA')!.finished, isTrue);
      expect(DownloadProgress.parse('lumtub|downloading|NA|NA|NA|NA|NA')!.fraction, isNull);
    });

    test('ignores other output and finds the printed file', () {
      expect(DownloadProgress.parse('[download] 5%'), isNull);
      expect(DownloadProgress.parse('lumtub|downloading|1'), isNull);
      expect(DownloadProgress.parseFile(r'lumtub-file|C:\Videos\a [x].mp4'), r'C:\Videos\a [x].mp4');
      expect(DownloadProgress.parseFile('something else'), isNull);
    });
  });

  test('formats depend on quality and ffmpeg', () {
    expect(DownloadQuality.audio.format(merge: false), 'ba[ext=m4a]/ba');
    expect(DownloadQuality.best.format(merge: true), 'bv*+ba/b');
    expect(DownloadQuality.p1080.format(merge: true), contains('bv*[height<=1080]'));
    expect(DownloadQuality.p720.format(merge: true), contains('height<=720'));
    // Without ffmpeg nothing may ask for a merge.
    for (final q in DownloadQuality.values) {
      expect(q.format(merge: false), isNot(contains('+')));
    }
  });

  group('queue', () {
    late Directory dir;
    late List<FakeProcess> processes;
    late List<List<String>> started;
    late Map<String, String> lastEnvironment;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lumtub_downloads');
      processes = [];
      started = [];
      lastEnvironment = {};
    });
    final managers = <DownloadManager>[];
    tearDown(() async {
      // Windows refuses to delete a folder while a list write is open.
      for (final m in managers) {
        await m.flush();
      }
      managers.clear();
      for (var i = 0; ; i++) {
        try {
          return await dir.delete(recursive: true);
        } on FileSystemException {
          if (i == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    DownloadManager manager({String? ffmpeg, List<SkipSegment> segments = const []}) => _track(managers, DownloadManager(
          file: File('${dir.path}/downloads.json'),
          ytDlpPath: 'yt-dlp',
          defaultDirectory: '${dir.path}/videos',
          start: (exe, args, {environment}) async {
            final process = FakeProcess();
            processes.add(process);
            started.add(args);
            lastEnvironment = environment ?? {};
            return process;
          },
          ffmpegDirectory: () => ffmpeg,
          options: () => const DownloadOptions(proxy: 'http://127.0.0.1:7890', deno: 'deno.exe', subtitleLanguages: '(zh|en).*', autoSubtitles: true),
          sponsorSegments: (id) async => segments,
        ));

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

    /// Waits for [done], for at most a few seconds: file writes can be slow
    /// while the whole suite runs.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    test('runs at most two downloads at once and starts the next when one ends', () async {
      final m = manager();
      for (final id in ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc']) {
        m.add(video(id), DownloadQuality.best);
      }
      await until(() => processes.length >= 2);
      await settle();
      expect(processes, hasLength(2));
      // Oldest first; the two processes may start in either order.
      expect(started.map((a) => a.last.substring(a.last.length - 11)).toSet(), {'aaaaaaaaaaa', 'bbbbbbbbbbb'});
      expect(m.taskFor('ccccccccccc')!.status, DownloadStatus.queued);
      await processes[started.indexWhere((a) => a.last.endsWith('aaaaaaaaaaa'))].exit(1);
      await until(() => processes.length >= 3);
      expect(processes, hasLength(3));
      expect(m.taskFor('aaaaaaaaaaa')!.status, DownloadStatus.failed);
      expect(m.taskFor('ccccccccccc')!.status, DownloadStatus.downloading);
    });

    test('shows progress and finishes with the printed file, a sidecar and segments', () async {
      final m = manager(segments: const [SkipSegment(Duration(seconds: 5), Duration(seconds: 12), 'sponsor')]);
      m.add(video('aaaaaaaaaaa'), DownloadQuality.p720);
      await settle();
      final file = File('${dir.path}/videos/Video [aaaaaaaaaaa].mp4')..createSync(recursive: true);
      File('${dir.path}/videos/Video [aaaaaaaaaaa].info.json').writeAsStringSync(jsonEncode({
        'title': 'Video',
        'vcodec': 'av01.0.12M.08',
        'chapters': [{'title': 'Intro', 'start_time': 0, 'end_time': 10}, {'title': 'Main', 'start_time': 10, 'end_time': 20}],
        'formats': List.generate(50, (i) => {'url': 'https://x/$i'}),
      }));
      File('${dir.path}/videos/Video [aaaaaaaaaaa].en.vtt').writeAsStringSync('WEBVTT');
      processes[0].out('lumtub|downloading|500|1000|NA|250.0|2');
      await settle();
      final task = m.taskFor('aaaaaaaaaaa')!;
      expect(task.fraction, 0.5);
      expect(task.speed, 250.0);
      processes[0].out('lumtub-file|${file.path}');
      await processes[0].exit(0);
      await settle();
      expect(task.status, DownloadStatus.done);
      expect(task.filePath, file.path);

      final local = m.localVideo('aaaaaaaaaaa')!;
      expect(local.info.containsKey('formats'), isFalse);
      expect(local.info['title'], 'Video');
      expect(local.videoCodec, VideoCodec.av1);
      expect(VideoDetails.fromJson(local.info).chapters, hasLength(2));
      expect(local.segments.single.category, 'sponsor');
      expect(local.segments.single.end, const Duration(seconds: 12));
      expect(local.subtitles.map((f) => f.uri.pathSegments.last), ['Video [aaaaaaaaaaa].en.vtt']);
      expect(local.preferredSubtitle(['zh-Hans', 'en']).path, endsWith('.en.vtt'));
    });

    test('a file that went missing is not played locally', () async {
      final m = manager();
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      await settle();
      final file = File('${dir.path}/videos/x [aaaaaaaaaaa].mp4')..createSync(recursive: true);
      processes[0].out('lumtub-file|${file.path}');
      await processes[0].exit(0);
      await settle();
      expect(m.localVideo('aaaaaaaaaaa'), isNotNull);
      file.deleteSync();
      expect(m.localVideo('aaaaaaaaaaa'), isNull);
    });

    test('pause keeps a slot until the process ends, resume continues, cancel deletes partial files', () async {
      final m = manager();
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      await settle();
      final partial = File('${dir.path}/videos/v [aaaaaaaaaaa].mp4.part')..createSync(recursive: true);
      m.pause('aaaaaaaaaaa');
      await settle();
      expect(processes[0].killed, isTrue);
      expect(m.taskFor('aaaaaaaaaaa')!.status, DownloadStatus.paused);
      expect(partial.existsSync(), isTrue);
      m.resume('aaaaaaaaaaa');
      await settle();
      expect(processes, hasLength(2));
      expect(m.taskFor('aaaaaaaaaaa')!.status, DownloadStatus.downloading);
      m.cancel('aaaaaaaaaaa');
      await settle();
      expect(m.taskFor('aaaaaaaaaaa')!.status, DownloadStatus.cancelled);
      expect(partial.existsSync(), isFalse);
      m.retry('aaaaaaaaaaa');
      await settle();
      expect(processes, hasLength(3));
    });

    test('failure keeps the ERROR line and can be retried; duplicates are refused', () async {
      final m = manager();
      expect(m.add(video('aaaaaaaaaaa'), DownloadQuality.best), isNotNull);
      expect(m.add(video('aaaaaaaaaaa'), DownloadQuality.best), isNull);
      await settle();
      processes[0].err('ERROR: [youtube] aaaaaaaaaaa: Video unavailable');
      await processes[0].exit(1);
      await settle();
      final task = m.taskFor('aaaaaaaaaaa')!;
      expect(task.status, DownloadStatus.failed);
      expect(task.error, contains('Video unavailable'));
      expect(m.add(video('aaaaaaaaaaa'), DownloadQuality.audio), isNotNull);
      expect(m.tasks, hasLength(1));
    });

    test('arguments carry the proxy, Deno, format and subtitles; ffmpeg enables merging', () {
      final without = manager().arguments(DownloadTask(item: video('aaaaaaaaaaa'), quality: DownloadQuality.best, directory: 'D'));
      expect(without, containsAllInOrder(['--proxy', 'http://127.0.0.1:7890']));
      expect(without, containsAllInOrder(['--js-runtimes', 'deno:deno.exe']));
      expect(without, containsAllInOrder(['--sub-langs', '(zh|en).*']));
      expect(without, containsAll(['--write-subs', '--write-auto-subs', '--write-info-json', '--newline']));
      expect(without, isNot(contains('--merge-output-format')));
      expect(without[without.indexOf('--format') + 1], isNot(contains('+')));
      expect(without.last, 'https://www.youtube.com/watch?v=aaaaaaaaaaa');

      final merged = manager(ffmpeg: 'F').arguments(DownloadTask(item: video('aaaaaaaaaaa'), quality: DownloadQuality.best, directory: 'D'));
      expect(merged, containsAllInOrder(['--merge-output-format', 'mp4/mkv']));
      expect(merged, containsAllInOrder(['--ffmpeg-location', 'F']));
      expect(merged[merged.indexOf('--format') + 1], contains('+'));

      final audio = manager().arguments(DownloadTask(item: video('aaaaaaaaaaa'), quality: DownloadQuality.audio, directory: 'D'));
      expect(audio, isNot(contains('--write-subs')));
    });

    test('progress ticks reach only the progress listenable, at most twice a second', () async {
      final m = manager();
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      await until(() => processes.isNotEmpty);
      var managerNotified = 0;
      var ticks = 0;
      m.addListener(() => managerNotified++);
      m.progress.addListener(() => ticks++);
      for (var i = 0; i < 20; i++) {
        processes[0].out('lumtub|downloading|${i * 10}|1000|NA|250.0|2');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settle();
      expect(managerNotified, 0);
      expect(ticks, inInclusiveRange(1, 2));
      expect(m.tasks.single.downloaded, 190);
    });

    test('saves are coalesced and flush writes a pending one', () async {
      final m = manager();
      final list = File('${dir.path}/downloads.json');
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      m.add(video('bbbbbbbbbbb'), DownloadQuality.best);
      await settle();
      expect(list.existsSync(), isFalse);
      await m.flush();
      expect(jsonDecode(list.readAsStringSync())['tasks'], hasLength(2));
    });

    test('keeps the list and the folder across restarts, and resumes interrupted downloads', () async {
      final m = manager();
      await m.setDirectory('${dir.path}/chosen');
      m.add(video('aaaaaaaaaaa'), DownloadQuality.audio);
      m.add(video('bbbbbbbbbbb'), DownloadQuality.best);
      await until(() => processes.length >= 2);
      await settle();
      final file = File('${dir.path}/chosen/a [aaaaaaaaaaa].m4a')..createSync(recursive: true);
      // The two downloads may start in either order.
      final a = processes[started.indexWhere((args) => args.last.endsWith('aaaaaaaaaaa'))];
      a.out('lumtub-file|${file.path}');
      await a.exit(0);
      await settle();
      expect(processes, hasLength(2));
      processes.clear();
      await m.flush();

      final restarted = manager();
      await restarted.load();
      await settle();
      expect(restarted.directory, '${dir.path}/chosen');
      expect(restarted.tasks.map((t) => t.id), ['bbbbbbbbbbb', 'aaaaaaaaaaa']);
      expect(restarted.taskFor('aaaaaaaaaaa')!.status, DownloadStatus.done);
      expect(restarted.taskFor('aaaaaaaaaaa')!.quality, DownloadQuality.audio);
      expect(restarted.taskFor('aaaaaaaaaaa')!.filePath, file.path);
      // The one that was running when the app closed starts again.
      expect(restarted.taskFor('bbbbbbbbbbb')!.status, DownloadStatus.downloading);
      expect(processes, hasLength(1));
      expect(restarted.localVideo('aaaaaaaaaaa'), isNotNull);
    });

    test('remove can delete the files', () async {
      final m = manager();
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      await settle();
      final file = File('${dir.path}/videos/a [aaaaaaaaaaa].mp4')..createSync(recursive: true);
      final other = File('${dir.path}/videos/b [bbbbbbbbbbb].mp4')..createSync();
      processes[0].out('lumtub-file|${file.path}');
      await processes[0].exit(0);
      await settle();
      await m.remove('aaaaaaaaaaa', deleteFiles: true);
      // A download still finishing deletes its files once it has finished.
      await until(() => !file.existsSync());
      expect(file.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(m.tasks, isEmpty);
    });

    test('the process environment forces UTF-8 output', () async {
      final m = manager();
      m.add(video('aaaaaaaaaaa'), DownloadQuality.best);
      await settle();
      expect(lastEnvironment['PYTHONUTF8'], '1');
    });
  });

  test('the default folder is Videos/Lumtub, else a fallback', () {
    expect(DownloadManager.defaultDirectoryFor({'USERPROFILE': 'C:/Users/me'}, 'F'), endsWith('Videos${Platform.pathSeparator}Lumtub'));
    expect(DownloadManager.defaultDirectoryFor({}, 'F'), 'F');
  });
}

T _track<T>(List<T> list, T item) => (list..add(item)).last;
