import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/invidious_streams.dart';
import 'package:lumtub/piped_streams.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/video_codec.dart';

/// The shape of https://api.invidious.io/instances.json?sort_by=type,users
/// (docs.invidious.io/instances), written from its documented schema.
const _instances = '''
[
  ["yewtu.be", {"flag": "🇩🇪", "region": "DE", "stats": null, "cors": true, "api": true, "type": "https", "uri": "https://yewtu.be", "monitor": {"statusClass": "success", "uptime": 99.9}}],
  ["inv.nadeko.net", {"flag": "🇨🇱", "region": "CL", "stats": null, "cors": true, "api": true, "type": "https", "uri": "https://inv.nadeko.net/", "monitor": null}],
  ["noapi.example", {"flag": "🇫🇷", "region": "FR", "stats": null, "cors": true, "api": false, "type": "https", "uri": "https://noapi.example", "monitor": null}],
  ["unknownapi.example", {"flag": "🇫🇷", "region": "FR", "stats": null, "cors": null, "api": null, "type": "https", "uri": "https://unknownapi.example", "monitor": null}],
  ["abcdef.onion", {"flag": "🇩🇪", "region": "DE", "stats": null, "cors": true, "api": true, "type": "onion", "uri": "http://abcdef.onion", "monitor": null}],
  ["192.0.2.1:3000", {"flag": "🇺🇸", "region": "US", "stats": null, "cors": true, "api": true, "type": "http", "uri": "http://192.0.2.1:3000", "monitor": null}]
]
''';

/// `/api/v1/videos/<id>?local=true`: adaptiveFormats with numbers as strings,
/// quoted codecs in `type`, and addresses on the instance itself.
Map<String, dynamic> _video() => {
      'type': 'video',
      'title': 'Me at the zoo',
      'videoId': 'jNQXAC9IVRw',
      'liveNow': false,
      'adaptiveFormats': [
        {'index': '740-1186', 'bitrate': '4000000', 'init': '0-739', 'url': 'https://inv.example/videoplayback?expire=1&itag=137&local=true', 'itag': '137', 'type': 'video/mp4; codecs="avc1.640028"', 'clen': '1', 'lmt': '1', 'projectionType': 'RECTANGULAR', 'fps': 30, 'size': '1920x1080', 'resolution': '1080p', 'qualityLabel': '1080p', 'container': 'mp4', 'encoding': 'h264'},
        {'bitrate': '3000000', 'url': '/videoplayback?expire=1&itag=248&local=true', 'itag': '248', 'type': 'video/webm; codecs="vp9"', 'fps': 30, 'size': '1920x1080', 'resolution': '1080p', 'qualityLabel': '1080p', 'container': 'webm', 'encoding': 'vp9'},
        {'bitrate': '2000000', 'url': 'http://inv.example/videoplayback?expire=1&itag=298&local=true', 'itag': '298', 'type': 'video/mp4; codecs="avc1.4d4020"', 'fps': 60, 'size': '1280x720', 'resolution': '720p', 'qualityLabel': '720p60', 'container': 'mp4', 'encoding': 'h264'},
        {'bitrate': '130000', 'url': 'https://inv.example/videoplayback?expire=1&itag=140&local=true', 'itag': '140', 'type': 'audio/mp4; codecs="mp4a.40.2"', 'audioQuality': 'AUDIO_QUALITY_MEDIUM', 'audioSampleRate': 44100, 'audioChannels': 2, 'container': 'm4a', 'encoding': 'aac'},
        {'bitrate': '160000', 'url': '/videoplayback?expire=1&itag=251&local=true', 'itag': '251', 'type': 'audio/webm; codecs="opus"', 'audioQuality': 'AUDIO_QUALITY_MEDIUM', 'container': 'webm', 'encoding': 'opus'},
        {'bitrate': '48000', 'url': 'https://inv.example/videoplayback?expire=1&itag=139&local=true', 'itag': '139', 'type': 'audio/mp4; codecs="mp4a.40.5"', 'container': 'm4a', 'encoding': 'aac'},
        {'bitrate': '9', 'url': 'ftp://nope', 'type': 'video/mp4; codecs="avc1"', 'size': '640x360'},
      ],
      'formatStreams': [
        {'url': 'https://inv.example/videoplayback?itag=18&local=true', 'itag': '18', 'type': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"', 'quality': 'medium', 'size': '640x360', 'qualityLabel': '360p'},
      ],
    };

void main() {
  test('keeps only https instances with the API on', () {
    expect(parseInvidiousInstances(_instances), ['https://yewtu.be', 'https://inv.nadeko.net']);
    expect(parseInvidiousInstances(_instances, limit: 1), ['https://yewtu.be']);
    expect(parseInvidiousInstances('<html>blocked</html>'), isEmpty);
    expect(parseInvidiousInstances('{"error": "x"}'), isEmpty);
    expect(parseInvidiousInstances('[["a", 1], "b", []]'), isEmpty);
  });

  test('reads adaptive formats like a Piped video', () {
    final video = parseInvidiousVideo('https://inv.example', _video());
    expect(video.live, isFalse);
    expect(video.heights, [1080, 720]);
    expect(video.audio.length, 3);
    final h264 = video.pickVideo(const PlayerSettings())!;
    expect((h264.codec, h264.height, h264.bitrate, h264.videoOnly), ('avc1.640028', 1080, 4000000, true));
    expect(h264.url, startsWith('https://inv.example/videoplayback?'));
    // A path alone belongs to the instance.
    final vp9 = video.pickVideo(const PlayerSettings(disabledCodecs: {VideoCodec.h264}))!;
    expect((vp9.codec, vp9.url), ('vp9', 'https://inv.example/videoplayback?expire=1&itag=248&local=true'));
    // The instance's own http address becomes https; the 720p60 label has no size problem.
    final p720 = video.pickVideo(const PlayerSettings(maxHeight: 720))!;
    expect((p720.height, p720.url), (720, 'https://inv.example/videoplayback?expire=1&itag=298&local=true'));
    expect(video.pickAudio(const PlayerSettings())!.url, endsWith('itag=251&local=true'));
    expect(video.pickAudio(const PlayerSettings(audioQuality: AudioQuality.low))!.url, contains('itag=139'));
    final edl = video.edl(const PlayerSettings())!;
    expect(edl, startsWith('edl://!new_stream;!no_clip;!no_chapters;%'));
    expect(edl, allOf(contains('itag=137'), contains('itag=251')));
  });

  test('streams off the instance and YouTube are skipped', () {
    final video = parseInvidiousVideo('https://inv.example', {
      'adaptiveFormats': [
        for (final (i, url) in ['https://inv.example/a', 'https://r1.googlevideo.com/a', 'https://evil.example/a', 'https://127.0.0.1/a', 'https://192.168.1.2/a', 'https://[::1]/a', 'https://nas.local/a'].indexed)
          {'bitrate': '${i + 1}', 'url': url, 'type': 'audio/mp4; codecs="mp4a.40.2"'},
      ],
    });
    expect(video.audio.map((s) => s.bitrate), [1, 2]);
  });

  test('height comes from the label when there is no size, and live has no EDL', () {
    final video = parseInvidiousVideo('https://inv.example', {
      'liveNow': true,
      'adaptiveFormats': [
        {'bitrate': '1', 'url': 'https://inv.example/v', 'type': 'video/mp4; codecs="avc1.4d401f"', 'qualityLabel': '480p'},
        {'bitrate': '1', 'url': 'https://inv.example/a', 'type': 'audio/mp4; codecs="mp4a.40.2"'},
      ],
    });
    expect(video.heights, [480]);
    expect(video.live, isTrue);
    expect(video.edl(const PlayerSettings()), isNull);
    expect(parseInvidiousVideo('https://inv.example', {'error': 'x'}).edl(const PlayerSettings()), isNull);
  });

  test('downloads the list once a day, keeps it on disk and fetches from the fastest instance', () async {
    final dir = await Directory.systemTemp.createTemp('invidious');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/invidious_servers.json');
    var listRequests = 0;
    final asked = <String>[];
    InvidiousStreams make() => InvidiousStreams(MockClient((request) async {
          final url = request.url.toString();
          asked.add(url);
          if (url == InvidiousStreams.instanceList) {
            listRequests++;
            return http.Response.bytes(utf8.encode(_instances), 200);
          }
          if (url.contains('/api/v1/videos/${InvidiousStreams.probeVideo}')) {
            if (url.startsWith('https://yewtu.be')) return http.Response('{"error": "blocked"}', 500);
            if (url.startsWith('https://inv.nadeko.net')) return http.Response('{"videoId": "${InvidiousStreams.probeVideo}"}', 200);
            return http.Response('', 503);
          }
          if (url.startsWith('https://inv.nadeko.net/api/v1/videos/dQw4w9WgXcQ?local=true')) {
            return http.Response.bytes(utf8.encode(jsonEncode(_video())), 200);
          }
          return http.Response('{"error": "nope"}', 404);
        }))
      ..catalogFile = file;

    final first = make();
    expect(await first.servers(), ['https://inv.nadeko.net']);
    expect(listRequests, 1);
    // A known instance answered, so the list comes in the background.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(first.wasTried('https://yewtu.be'), isTrue);
    expect(first.timingOf('https://yewtu.be'), isNull);
    await first.saved;
    expect((jsonDecode(await file.readAsString()) as Map)['servers'], ['https://yewtu.be', 'https://inv.nadeko.net']);
    final fetched = await first.fetch('dQw4w9WgXcQ');
    expect(fetched.server, 'https://inv.nadeko.net');
    expect(fetched.edl(const PlayerSettings()), isNotNull);

    // A list from today is not downloaded again.
    final second = make();
    await second.servers();
    await second.saved;
    expect(listRequests, 1);
    // A day-old one is.
    final saved = jsonDecode(await file.readAsString()) as Map;
    await file.writeAsString(jsonEncode({...saved, 'updated': DateTime.now().subtract(const Duration(days: 2)).toIso8601String()}));
    await make().servers();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(listRequests, 2);
  });

  test('reports the instance error, and pauses after three failed videos', () async {
    var calls = 0;
    final invidious = InvidiousStreams(MockClient((request) async {
      calls++;
      return http.Response('{"error": "Could not extract video info. Instance is likely blocked."}', 500);
    }));
    await expectLater(invidious.fetch('dQw4w9WgXcQ', server: 'https://i.example'), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('likely blocked'))));
    for (var i = 0; i < 2; i++) {
      await expectLater(invidious.fetch('dQw4w9WgXcQ', server: 'https://i.example'), throwsStateError);
    }
    final before = calls;
    await expectLater(invidious.fetch('dQw4w9WgXcQ', server: 'https://i.example'), throwsStateError);
    expect(calls, before);
  });

  test('playback source and Invidious instance are saved', () {
    const settings = PlayerSettings(playbackSource: PlaybackSource.invidiousCustom, invidiousServer: 'https://yewtu.be');
    final saved = PlayerSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
    expect((saved.playbackSource, saved.invidiousServer), (PlaybackSource.invidiousCustom, 'https://yewtu.be'));
    expect(PlaybackSource.invidiousAuto.relay, RelayKind.invidious);
    expect(PlaybackSource.pipedCustom.relay, RelayKind.piped);
    expect(PlaybackSource.youtube.relay, isNull);
    expect(PlaybackSource.invidiousCustom.isCustom && !PlaybackSource.invidiousAuto.isCustom, isTrue);
  });
}
