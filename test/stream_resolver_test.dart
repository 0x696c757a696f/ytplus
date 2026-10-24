import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/stream_resolver.dart';

Map<String, dynamic> _info({int? expire}) {
  final exp = expire ?? DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch ~/ 1000;
  return {
    'id': 'dQw4w9WgXcQ',
    'title': 'Never Gonna Give You Up',
    'channel': 'Rick Astley',
    'channel_id': 'UCuAXFkgsw1L7xaCfnd5JJOw',
    'formats': [
      {'format_id': '137', 'vcodec': 'avc1', 'height': 1080},
      {'format_id': '136', 'vcodec': 'avc1', 'height': 720},
      {'format_id': '248', 'vcodec': 'vp9', 'height': 1080},
      {'format_id': '140', 'vcodec': 'none', 'acodec': 'mp4a'},
    ],
    'requested_formats': [
      {'url': 'https://r1.googlevideo.com/videoplayback?expire=$exp&itag=137', 'protocol': 'https', 'vcodec': 'avc1', 'http_headers': {'User-Agent': 'UA/1'}},
      {'url': 'https://r1.googlevideo.com/videoplayback?expire=$exp&itag=140&ü', 'protocol': 'https', 'acodec': 'mp4a'},
    ],
  };
}

void main() {
  final file = File('info.json');

  test('builds the EDL address mpv\'s ytdl_hook would', () {
    final video = ResolvedVideo(_info(), file, 'f');
    final tracks = (video.info['requested_formats'] as List).map((t) => t['url'] as String).toList();
    expect(
      video.directUrl,
      'edl://!new_stream;!no_clip;!no_chapters;%${tracks[0].length}%${tracks[0]};'
      '!new_stream;!no_clip;!no_chapters;%${utf8.encode(tracks[1]).length}%${tracks[1]}',
    );
    expect(video.userAgent, 'UA/1');
    final relayed = video.directAddress(relay: (url, size) => url.contains('itag=137') ? 'http://127.0.0.1:9/a' : null)!;
    expect(relayed, contains('%20%http://127.0.0.1:9/a;'));
    expect(relayed, contains(tracks[1]));
    expect(video.heights, [1080, 720]);
    expect(video.details.channelId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
  });

  test('leaves live and fragmented streams to ytdl_hook', () {
    expect(ResolvedVideo({..._info(), 'is_live': true}, file, 'f').directUrl, isNull);
    final fragmented = _info();
    (fragmented['requested_formats'] as List)[0]['fragments'] = [{'url': 'x'}];
    expect(ResolvedVideo(fragmented, file, 'f').directUrl, isNull);
    final hls = _info();
    (hls['requested_formats'] as List)[0]['protocol'] = 'm3u8_native';
    expect(ResolvedVideo(hls, file, 'f').directUrl, isNull);
  });

  test('is used well before its addresses expire', () {
    final soon = DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000;
    expect(ResolvedVideo(_info(expire: soon), file, 'f').fresh, isFalse);
    expect(ResolvedVideo(_info(), file, 'f').fresh, isTrue);
    expect(ResolvedVideo(_info(), file, 'f', now: DateTime.now().subtract(const Duration(hours: 2))).fresh, isFalse);
  });

  test('runs yt-dlp once per video and saves the info file', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final count = File('${dir.path}/count');
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\necho x >> ${count.path}\nsleep 0.2\ncat <<\'JSON\'\n${jsonEncode(_info())}\nJSON\n');
    await Process.run('chmod', ['+x', script.path]);
    final resolver = StreamResolver(script.path, infoDirectory: Directory('${dir.path}/info'));
    resolver.prefetch('dQw4w9WgXcQ', 'ytdl');
    final videos = await Future.wait([resolver.resolve('dQw4w9WgXcQ', 'ytdl'), resolver.resolve('dQw4w9WgXcQ', 'ytdl')]);
    expect(identical(videos[0], videos[1]), isTrue);
    expect(count.readAsLinesSync(), hasLength(1));
    expect(jsonDecode(videos[0].file.readAsStringSync())['title'], 'Never Gonna Give You Up');
    expect(resolver.arguments('dQw4w9WgXcQ', 'ytdl'), containsAllInOrder(['--format', 'bestvideo+bestaudio/best', '--', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ']));
    expect(resolver.arguments('dQw4w9WgXcQ', 'bestvideo+bestaudio', formatSort: 'res,fps,vcodec:vp9'), containsAllInOrder(['--format', 'bestvideo+bestaudio', '--format-sort', 'res,fps,vcodec:vp9']));
    resolver.forget('dQw4w9WgXcQ');
    await resolver.resolve('dQw4w9WgXcQ', 'ytdl');
    expect(count.readAsLinesSync(), hasLength(2));
  });

  test('prefetches one video at a time, then only the last one asked for', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final log = File('${dir.path}/log');
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\nfor last; do :; done\necho "\$last" >> ${log.path}\nsleep 0.3\ncat <<\'JSON\'\n${jsonEncode(_info())}\nJSON\n');
    await Process.run('chmod', ['+x', script.path]);
    final resolver = StreamResolver(script.path, infoDirectory: Directory('${dir.path}/info'));
    for (final id in ['aaaaaaaaaaa', 'bbbbbbbbbbb', 'ccccccccccc']) {
      resolver.prefetch(id, 'ytdl');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(log.readAsLinesSync(), hasLength(1));
    await resolver.resolve('ccccccccccc', 'ytdl');
    expect(log.readAsLinesSync().map((line) => line.substring(line.length - 11)), ['aaaaaaaaaaa', 'ccccccccccc']);
  });

  test('a failed resolution is not kept', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\necho "ERROR: Sign in to confirm" >&2\nexit 1\n');
    await Process.run('chmod', ['+x', script.path]);
    final resolver = StreamResolver(script.path, infoDirectory: Directory('${dir.path}/info'));
    await expectLater(resolver.resolve('dQw4w9WgXcQ', 'ytdl'), throwsA(isA<StateError>()));
    await expectLater(resolver.resolve('dQw4w9WgXcQ', 'ytdl'), throwsA(isA<StateError>()));
  });

  test('points yt-dlp at Deno and retries a network error once', () async {
    expect(StreamResolver('yt-dlp', deno: r'C:\tools\deno.exe', infoDirectory: Directory('x')).arguments('dQw4w9WgXcQ', 'ytdl'),
        containsAllInOrder(['--js-runtimes', r'deno:C:\tools\deno.exe']));
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final count = File('${dir.path}/count');
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\necho x >> ${count.path}\n'
        'if [ \$(wc -l < ${count.path}) -eq 1 ]; then echo "ERROR: HTTP Error 503: Service Unavailable" >&2; exit 1; fi\n'
        'echo "WARNING: n challenge solving failed" >&2\n'
        'cat <<\'JSON\'\n${jsonEncode(_info())}\nJSON\n');
    await Process.run('chmod', ['+x', script.path]);
    final video = await StreamResolver(script.path, infoDirectory: Directory('${dir.path}/info')).resolve('dQw4w9WgXcQ', 'ytdl');
    expect(video.info['title'], 'Never Gonna Give You Up');
    expect(count.readAsLinesSync(), hasLength(2));
  });

  test('resolves again when the format differs from the cached one', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final count = File('${dir.path}/count');
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\necho x >> ${count.path}\ncat <<\'JSON\'\n${jsonEncode(_info())}\nJSON\n');
    await Process.run('chmod', ['+x', script.path]);
    final resolver = StreamResolver(script.path, infoDirectory: Directory('${dir.path}/info'));
    final first = await resolver.resolve('dQw4w9WgXcQ', 'best[height<=720]');
    expect(first.format, 'best[height<=720]');
    expect(identical(await resolver.resolve('dQw4w9WgXcQ', 'best[height<=720]'), first), isTrue);
    final second = await resolver.resolve('dQw4w9WgXcQ', 'bestvideo+bestaudio');
    expect(second.format, 'bestvideo+bestaudio');
    expect(count.readAsLinesSync(), hasLength(2));
    // A prefetch for the cached format is skipped, one for another is not.
    resolver.prefetch('dQw4w9WgXcQ', 'bestvideo+bestaudio');
    resolver.prefetch('dQw4w9WgXcQ', 'ytdl');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(count.readAsLinesSync(), hasLength(3));
    expect((await resolver.cached('dQw4w9WgXcQ'))!.format, 'ytdl');
  });

  test('deletes the info file of a forgotten or evicted video, and of old runs', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_resolve');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\ncat <<\'JSON\'\n${jsonEncode(_info())}\nJSON\n');
    await Process.run('chmod', ['+x', script.path]);
    final info = Directory('${dir.path}/info')..createSync();
    final old = File('${info.path}/oldoldoldol.json')..writeAsStringSync('{}');
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    final recent = File('${info.path}/recentrecen.json')..writeAsStringSync('{}');
    final resolver = StreamResolver(script.path, infoDirectory: info);
    await resolver.deleteStaleInfo();
    expect(old.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);

    final ids = [for (var i = 0; i < 13; i++) 'video${i.toString().padLeft(6, '0')}'];
    for (final id in ids) {
      await resolver.resolve(id, 'ytdl');
    }
    // Only the 12 kept entries still have a file.
    expect(File('${info.path}/${ids.first}.json').existsSync(), isFalse);
    for (final id in ids.skip(1)) {
      expect(File('${info.path}/$id.json').existsSync(), isTrue);
    }
    resolver.forget(ids.last);
    expect(File('${info.path}/${ids.last}.json').existsSync(), isFalse);
  });
}
