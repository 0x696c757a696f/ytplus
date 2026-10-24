import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/piped_streams.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/video_codec.dart';

Map<String, dynamic> _streams() => {
      'title': 'x',
      'livestream': false,
      'proxyUrl': 'https://proxy.example',
      'videoStreams': [
        {'url': 'https://proxy.example/v?itag=137', 'codec': 'avc1.640028', 'height': 1080, 'bitrate': 4000000, 'videoOnly': true, 'mimeType': 'video/mp4'},
        {'url': 'https://proxy.example/v?itag=248', 'codec': 'vp9', 'height': 1080, 'bitrate': 3000000, 'videoOnly': true, 'mimeType': 'video/webm'},
        {'url': 'https://proxy.example/v?itag=136', 'codec': 'avc1.4d401f', 'height': 720, 'bitrate': 2000000, 'videoOnly': true, 'mimeType': 'video/mp4'},
        {'url': 'https://proxy.example/v?itag=18', 'codec': 'avc1', 'height': 360, 'bitrate': 500000, 'videoOnly': false, 'mimeType': 'video/mp4'},
      ],
      'audioStreams': [
        {'url': 'https://proxy.example/a?itag=140', 'codec': 'mp4a.40.2', 'bitrate': 130000, 'mimeType': 'audio/mp4'},
        {'url': 'https://proxy.example/a?itag=251', 'codec': 'opus', 'bitrate': 160000, 'mimeType': 'audio/webm'},
        {'url': 'https://proxy.example/a?itag=139', 'codec': 'mp4a.40.5', 'bitrate': 48000, 'mimeType': 'audio/mp4'},
      ],
    };

void main() {
  final video = PipedVideo.fromJson('https://p', _streams());

  test('picks streams the way the yt-dlp expression would', () {
    expect(video.heights, [1080, 720]);
    expect(video.pickVideo(const PlayerSettings())!.url, endsWith('itag=137'));
    expect(video.pickVideo(const PlayerSettings(disabledCodecs: {VideoCodec.h264}))!.url, endsWith('itag=248'));
    expect(video.pickVideo(const PlayerSettings(disabledCodecs: {VideoCodec.h264, VideoCodec.vp9})), isNull);
    expect(video.heightsFor(const PlayerSettings(disabledCodecs: {VideoCodec.h264})), [1080]);
    expect(video.edl(const PlayerSettings(disabledCodecs: {VideoCodec.h264, VideoCodec.vp9})), isNull);
    expect(video.pickVideo(const PlayerSettings(maxHeight: 720))!.url, endsWith('itag=136'));
    expect(video.pickVideo(const PlayerSettings(maxHeight: 144))!.height, 720);
    expect(video.pickAudio(const PlayerSettings())!.url, endsWith('itag=251'));
    expect(video.pickAudio(const PlayerSettings(audioQuality: AudioQuality.medium))!.url, endsWith('itag=140'));
    expect(video.pickAudio(const PlayerSettings(audioQuality: AudioQuality.low))!.url, endsWith('itag=139'));
    final edl = video.edl(const PlayerSettings())!;
    expect(edl, startsWith('edl://!new_stream;!no_clip;!no_chapters;%'));
    expect(edl, contains('itag=137'));
    expect(PipedVideo.fromJson('s', {..._streams(), 'livestream': true}).edl(const PlayerSettings()), isNull);
  });

  test('normalises typed servers', () {
    expect(normalizePipedServer('pipedapi.kavin.rocks/'), 'https://pipedapi.kavin.rocks');
    expect(normalizePipedServer('http://insecure.example'), isNull);
    expect(normalizePipedServer(''), isNull);
  });

  test('ranks servers by speed and moves on from one that fails', () async {
    final asked = <String>[];
    final client = MockClient((request) async {
      final url = request.url.toString();
      asked.add(url);
      if (url == 'https://piped-instances.kavin.rocks/') {
        return http.Response(jsonEncode([
          {'api_url': 'https://slow.example', 'up_to_date': true},
          {'api_url': 'https://broken.example', 'up_to_date': true},
          {'api_url': 'https://down.example', 'up_to_date': true},
        ]), 200);
      }
      if (url.endsWith('/healthcheck')) {
        if (url.startsWith('https://down.example')) return http.Response('no', 503);
        if (url.startsWith('https://slow.example')) await Future<void>.delayed(const Duration(milliseconds: 60));
        if (PipedStreams.knownServers.any(url.startsWith)) return http.Response('no', 503);
        return http.Response('OK', 200);
      }
      if (url.startsWith('https://broken.example/streams/')) return http.Response(jsonEncode({'message': 'blocked'}), 500);
      return http.Response.bytes(utf8.encode(jsonEncode(_streams())), 200);
    });
    final piped = PipedStreams(client);
    expect(await piped.servers(), ['https://broken.example', 'https://slow.example']);
    final fetched = await piped.fetch('dQw4w9WgXcQ');
    expect(fetched.server, 'https://slow.example');
    expect(await piped.servers(), ['https://slow.example', 'https://broken.example']);
    expect(asked.where((u) => u.contains('/streams/')), ['https://broken.example/streams/dQw4w9WgXcQ', 'https://slow.example/streams/dQw4w9WgXcQ']);
  });

  test('playback source is saved, direct YouTube by default', () {
    expect(const PlayerSettings().playbackSource, PlaybackSource.youtube);
    expect(PlayerSettings.fromJson(const {'playbackSource': 'pipedAuto'}).playbackSource, PlaybackSource.youtube);
    final saved = PlayerSettings.fromJson(const PlayerSettings(playbackSource: PlaybackSource.pipedCustom, pipedServer: 'https://p.example').toJson());
    expect((saved.playbackSource, saved.pipedServer), (PlaybackSource.pipedCustom, 'https://p.example'));
  });

  test('stops asking after three failed videos in a row', () async {
    var calls = 0;
    final piped = PipedStreams(MockClient((request) async {
      calls++;
      return http.Response('down', 502);
    }));
    for (var i = 0; i < 3; i++) {
      await expectLater(piped.fetch('dQw4w9WgXcQ', server: 'https://p.example'), throwsStateError);
    }
    final before = calls;
    await expectLater(piped.fetch('dQw4w9WgXcQ', server: 'https://p.example'), throwsStateError);
    expect(calls, before);
  });

  test('reads the documentation table and the JSON status list', () {
    const table = '''
Instance Name | Instance API URL | Instance Location(s) | CDN | Registered Users
--- | --- | --- | --- | ---
kavin.rocks (Official) | https://pipedapi.kavin.rocks | 🇺🇸, 🇮🇳 | Yes | ![](https://pipedapi.kavin.rocks/registered/badge)
piped.yt | https://api.piped.yt | 🇩🇪 | No | ![](https://api.piped.yt/registered/badge)
''';
    expect(parsePipedInstanceList(table), ['https://pipedapi.kavin.rocks', 'https://api.piped.yt']);
    expect(
      parsePipedInstanceList(jsonEncode([
        {'api_url': 'https://a.example/', 'up_to_date': true},
        {'api_url': 'https://old.example', 'up_to_date': false},
        {'api_url': 'http://insecure.example'},
      ])),
      ['https://a.example'],
    );
    expect(parsePipedInstanceList('{"message": "x"}'), isEmpty);
  });

  test('keeps the downloaded list and updates it once a day', () async {
    final dir = await Directory.systemTemp.createTemp('piped');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/piped_servers.json');
    var listRequests = 0;
    PipedStreams make() => PipedStreams(MockClient((request) async {
          final url = request.url.toString();
          if (PipedStreams.instanceLists.contains(url)) {
            listRequests++;
            return http.Response('| new | https://new.example | x |', 200);
          }
          return http.Response('OK', url.startsWith('https://new.example') ? 200 : 503);
        }))
      ..catalogFile = file;

    final first = make();
    expect(await first.servers(), ['https://new.example']);
    expect(listRequests, 2);
    await first.saved;
    final saved = jsonDecode(await file.readAsString()) as Map;
    expect(saved['servers'], ['https://new.example']);

    // A fresh list is used as it is.
    final next = make();
    expect(await next.servers(), ['https://new.example']);
    expect(listRequests, 2);
    expect(next.catalog, containsAll([...PipedStreams.knownServers, 'https://new.example']));
    expect(next.timingOf('https://new.example'), isNotNull);
    expect((next.wasTried('https://pipedapi.kavin.rocks'), next.timingOf('https://pipedapi.kavin.rocks')), (true, null));
    await next.saved;

    // A day-old one is downloaded again.
    await file.writeAsString(jsonEncode({...saved, 'updated': DateTime.now().subtract(const Duration(days: 2)).toIso8601String()}));
    await make().servers();
    // Known servers answered, so the list is downloaded in the background.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(listRequests, 4);
  });

  test('streams off the allowed hosts are skipped', () {
    PipedStream? parse(String url, [List<String> trusted = const ['pipedapi.example', 'proxy.example']]) =>
        PipedStream.tryParse({'url': url, 'codec': 'opus', 'bitrate': 1}, trustedHosts: trusted);
    for (final good in [
      'https://pipedapi.example/v',
      'https://proxy.example:8443/v',
      'https://rr3---sn-abc.googlevideo.com/videoplayback?x=1',
      'https://www.youtube.com/a',
      'https://i.ytimg.com/a',
    ]) {
      expect(parse(good), isNotNull, reason: good);
    }
    for (final bad in [
      'http://pipedapi.example/v',
      'https://evil.example/v',
      'https://notgooglevideo.com/v',
      'https://googlevideo.com.evil.example/v',
      'https://googlevideo.com@evil.example/v',
      'https://127.0.0.1/v',
      'https://localhost/v',
      'https://a.localhost/v',
      'https://printer.local/v',
      'https://10.0.0.5/v',
      'https://172.16.0.1/v',
      'https://192.168.1.1/v',
      'https://169.254.169.254/v',
      'https://[::1]/v',
      'https://[fe80::1]/v',
      'https://[fd00::1]/v',
      'https://[::ffff:192.168.0.1]/v',
      'https://2130706433/v',
      'https://0x7f.1/v',
      '/relative',
      '',
    ]) {
      expect(parse(bad), isNull, reason: bad);
      // Not even a server that names itself so is believed.
      if (RegExp(r'^https://(\[|\d|0x|a?\.?localhost|printer\.local)').hasMatch(bad)) {
        expect(parse(bad, [Uri.parse(bad).host]), isNull, reason: 'trusted $bad');
      }
    }
    // Without trusted hosts only YouTube's own pass.
    expect(parse('https://proxy.example/v', const []), isNull);
    final video = PipedVideo.fromJson('https://pipedapi.example', {
      'proxyUrl': 'https://proxy.example',
      'audioStreams': [
        {'url': 'https://proxy.example/a', 'codec': 'opus', 'bitrate': 1},
        {'url': 'https://evil.example/a', 'codec': 'opus', 'bitrate': 2},
        {'url': 'https://192.168.0.9/a', 'codec': 'opus', 'bitrate': 3},
        {'url': 'https://r1.googlevideo.com/a', 'codec': 'opus', 'bitrate': 4},
      ],
    });
    expect(video.audio.map((s) => s.bitrate), [1, 4]);
  });

  test('servers are probed four at a time, the last one that worked first', () async {
    final servers = [for (var i = 0; i < 12; i++) 'https://s$i.example'];
    var running = 0, most = 0;
    final order = <String>[];
    final dir = await Directory.systemTemp.createTemp('piped');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/piped_servers.json');
    await file.writeAsString(jsonEncode({'updated': DateTime.now().toIso8601String(), 'servers': servers, 'last': servers[9]}));
    final streams = PipedStreams(MockClient((request) async {
      final host = request.url.origin;
      order.add(host);
      most = max(most, ++running);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      return http.Response('OK', host == servers[9] || host == servers[3] ? 200 : 503);
    }))
      ..catalogFile = file;
    final ranked = await streams.servers();
    expect(most, 4);
    expect(order.first, servers[9]);
    expect(order.toSet().containsAll(servers), isTrue);
    expect(ranked.toSet(), {servers[9], servers[3]});
    await streams.saved;
    expect(((jsonDecode(await file.readAsString()) as Map)['last']), ranked.first);
  });
}
