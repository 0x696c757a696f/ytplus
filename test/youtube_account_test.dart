import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/youtube_account.dart';

void main() {
  test('pages through subscriptions with the access token', () async {
    final pages = <String?>[];
    final api = YouTubeAccountApi(MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer token-1');
      expect(request.url.path, '/youtube/v3/subscriptions');
      expect(request.url.queryParameters['mine'], 'true');
      final page = request.url.queryParameters['pageToken'];
      pages.add(page);
      final channel = page == null ? 'UCuAXFkgsw1L7xaCfnd5JJOw' : 'UC_x5XG1OV2P6uZZ5FSM9Ttw';
      return http.Response(jsonEncode({
        if (page == null) 'nextPageToken': 'p2',
        'items': [
          {'snippet': {'title': page == null ? 'Rick Astley' : 'Google for Developers', 'resourceId': {'kind': 'youtube#channel', 'channelId': channel}}},
          {'snippet': {'title': 'broken', 'resourceId': {'channelId': 'nope'}}},
        ],
      }), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }), () async => 'token-1');
    final channels = await api.subscriptions();
    expect(pages, [null, 'p2']);
    expect(channels.map((c) => c.name), ['Rick Astley', 'Google for Developers']);
  });

  test('keeps playable playlist entries only', () {
    final video = YouTubeAccountApi.parsePlaylistItem({
      'snippet': {'title': 'Never Gonna Give You Up', 'videoOwnerChannelTitle': 'Rick Astley', 'videoOwnerChannelId': 'UCuAXFkgsw1L7xaCfnd5JJOw'},
      'contentDetails': {'videoId': 'dQw4w9WgXcQ'},
    })!;
    expect(video.id, 'dQw4w9WgXcQ');
    expect(video.channel, 'Rick Astley');
    expect(video.channelId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
    expect(YouTubeAccountApi.parsePlaylistItem({'snippet': {'title': 'Deleted video'}, 'contentDetails': {'videoId': 'aaaaaaaaaaa'}}), isNull);
    final playlist = YouTubeAccountApi.parsePlaylist({'id': 'PL123', 'snippet': {'title': '收藏夹'}, 'contentDetails': {'itemCount': 7}})!;
    expect((playlist.id, playlist.title, playlist.count), ('PL123', '收藏夹', 7));
  });

  test('stops reading a playlist at the item limit', () async {
    var requests = 0;
    final api = YouTubeAccountApi(MockClient((request) async {
      requests++;
      return http.Response(jsonEncode({
        'nextPageToken': 'more',
        'items': [
          for (var i = 0; i < 50; i++)
            {'snippet': {'title': '$i', 'videoOwnerChannelId': 'UCuAXFkgsw1L7xaCfnd5JJOw'}, 'contentDetails': {'videoId': 'v${'$i'.padLeft(10, '0')}'}},
        ],
      }), 200);
    }), () async => 't');
    final items = await api.playlistItems('PL1');
    expect(items, hasLength(YouTubeAccountApi.maxPlaylistItems));
    expect(requests, YouTubeAccountApi.maxPlaylistItems ~/ 50);
  });

  test('explains common API errors', () async {
    final api = YouTubeAccountApi(MockClient((_) async => http.Response('{"error":{"code":403,"errors":[{"reason":"quotaExceeded"}]}}', 403)), () async => 't');
    await expectLater(api.playlists(), throwsA(predicate((e) => '$e'.contains('配额'))));
    expect('${const YouTubeApiException(403, 'accessNotConfigured')}', contains('YouTube Data API v3'));
    expect('${const YouTubeApiException(401, null)}', contains('重新登录'));
  });
}
