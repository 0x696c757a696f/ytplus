import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'l10n/l10n.dart';

/// A playlist of the signed-in account.
class RemotePlaylist {
  const RemotePlaylist(this.id, this.title, this.count);
  final String id;
  final String title;
  final int count;
}

/// How the signed-in user rated a video.
enum VideoRating { like, dislike, none }

/// The parts of the YouTube Data API that Lumtub uses for a signed-in user.
/// A read costs one unit of the client's daily quota, a change about 50.
class YouTubeAccountApi {
  YouTubeAccountApi(this._client, this._accessToken);
  final http.Client _client;
  final Future<String> Function() _accessToken;

  /// Playlists larger than this are cut, to keep syncing quick and cheap.
  static const maxPlaylistItems = 500;

  /// The account's channel name and its "liked videos" playlist.
  Future<({String name, String? likes})> me() async {
    final data = await _get('channels', {'part': 'snippet,contentDetails', 'mine': 'true'});
    final items = data['items'];
    if (items is! List || items.isEmpty || items.first is! Map) return (name: tr('YouTube 账号'), likes: null);
    final channel = items.first as Map;
    final likes = (channel['contentDetails'] as Map?)?['relatedPlaylists']?['likes'];
    return (name: (channel['snippet'] as Map?)?['title']?.toString() ?? tr('YouTube 账号'), likes: likes is String && likes.isNotEmpty ? likes : null);
  }

  Future<List<ChannelRef>> subscriptions() async {
    final channels = <ChannelRef>[];
    await _pages('subscriptions', {'part': 'snippet', 'mine': 'true', 'order': 'alphabetical'}, (item) {
      final channel = parseSubscription(item);
      if (channel != null) channels.add(channel);
    });
    return channels;
  }

  Future<List<RemotePlaylist>> playlists() async {
    final playlists = <RemotePlaylist>[];
    await _pages('playlists', {'part': 'snippet,contentDetails', 'mine': 'true'}, (item) {
      final playlist = parsePlaylist(item);
      if (playlist != null) playlists.add(playlist);
    });
    return playlists;
  }

  Future<List<VideoItem>> playlistItems(String playlistId) async {
    final videos = <VideoItem>[];
    await _pages('playlistItems', {'part': 'snippet,contentDetails', 'playlistId': playlistId}, (item) {
      final video = parsePlaylistItem(item);
      if (video != null) videos.add(video);
    }, limit: maxPlaylistItems);
    return videos;
  }

  Future<VideoRating> rating(String videoId) async {
    final data = await _get('videos/getRating', {'id': videoId});
    final items = data['items'];
    final rating = items is List && items.isNotEmpty && items.first is Map ? (items.first as Map)['rating'] : null;
    return VideoRating.values.where((r) => r.name == rating).firstOrNull ?? VideoRating.none;
  }

  Future<void> rate(String videoId, VideoRating rating) => _send('POST', 'videos/rate', {'id': videoId, 'rating': rating.name});

  /// Posts a top-level comment under [videoId]; returns its id.
  Future<String?> comment(String videoId, String text) async {
    final data = await _send('POST', 'commentThreads', {'part': 'snippet'}, {
      'snippet': {
        'videoId': videoId,
        'topLevelComment': {
          'snippet': {'textOriginal': text},
        },
      },
    });
    return data['id']?.toString();
  }

  /// Replies to comment [parentId]; returns the reply's id.
  Future<String?> reply(String parentId, String text) async {
    final data = await _send('POST', 'comments', {'part': 'snippet'}, {
      'snippet': {'parentId': parentId, 'textOriginal': text},
    });
    return data['id']?.toString();
  }

  Future<void> addToPlaylist(String playlistId, String videoId) => _send('POST', 'playlistItems', {'part': 'snippet'}, {
        'snippet': {
          'playlistId': playlistId,
          'resourceId': {'kind': 'youtube#video', 'videoId': videoId},
        },
      });

  /// Creates a private playlist; returns it.
  Future<RemotePlaylist> createPlaylist(String title) async {
    final data = await _send('POST', 'playlists', {'part': 'snippet,status'}, {
      'snippet': {'title': title},
      'status': {'privacyStatus': 'private'},
    });
    final id = data['id']?.toString();
    if (id == null || id.isEmpty) throw const YouTubeApiException(200, 'noPlaylistId');
    return RemotePlaylist(id, title, 0);
  }

  /// The id of the account's subscription to [channelId], if any.
  Future<String?> subscriptionTo(String channelId) async {
    final data = await _get('subscriptions', {'part': 'id', 'mine': 'true', 'forChannelId': channelId});
    final items = data['items'];
    return items is List && items.isNotEmpty && items.first is Map ? (items.first as Map)['id']?.toString() : null;
  }

  Future<void> subscribe(String channelId) async {
    try {
      await _send('POST', 'subscriptions', {'part': 'snippet'}, {
        'snippet': {
          'resourceId': {'kind': 'youtube#channel', 'channelId': channelId},
        },
      });
    } on YouTubeApiException catch (e) {
      if (e.reason != 'subscriptionDuplicate') rethrow;
    }
  }

  Future<void> unsubscribe(String channelId) async {
    final id = await subscriptionTo(channelId);
    if (id != null) await _send('DELETE', 'subscriptions', {'id': id});
  }

  static ChannelRef? parseSubscription(Map item) {
    final snippet = item['snippet'];
    if (snippet is! Map) return null;
    final id = (snippet['resourceId'] as Map?)?['channelId']?.toString() ?? '';
    final thumbnails = snippet['thumbnails'];
    final picture = thumbnails is Map ? thumbnails['medium'] ?? thumbnails['default'] : null;
    final avatar = ChannelRef.avatarUrl(picture is Map ? picture['url'] : null);
    return ChannelRef.isValidId(id) ? ChannelRef(id, snippet['title']?.toString() ?? '', avatar) : null;
  }

  static RemotePlaylist? parsePlaylist(Map item) {
    final id = item['id'];
    if (id is! String || id.isEmpty) return null;
    final count = (item['contentDetails'] as Map?)?['itemCount'];
    return RemotePlaylist(id, (item['snippet'] as Map?)?['title']?.toString() ?? tr('播放列表'), count is num ? count.toInt() : 0);
  }

  /// Deleted and private videos stay in playlists without an owner; they
  /// cannot be played, so they are left out.
  static VideoItem? parsePlaylistItem(Map item) {
    final snippet = item['snippet'];
    if (snippet is! Map) return null;
    final resource = snippet['resourceId'];
    final id = (item['contentDetails'] as Map?)?['videoId'] ?? (resource is Map ? resource['videoId'] : null);
    if (id is! String || !RegExp(r'^[\w-]{11}$').hasMatch(id)) return null;
    final ownerId = snippet['videoOwnerChannelId']?.toString();
    if (ownerId == null) return null;
    return VideoItem(
      id: id,
      title: snippet['title']?.toString() ?? '',
      channel: snippet['videoOwnerChannelTitle']?.toString() ?? '',
      url: 'https://www.youtube.com/watch?v=$id',
      channelId: ChannelRef.isValidId(ownerId) ? ownerId : null,
    );
  }

  Future<void> _pages(String resource, Map<String, String> query, void Function(Map item) onItem, {int? limit}) async {
    String? pageToken;
    var seen = 0;
    do {
      final data = await _get(resource, {...query, 'maxResults': '50', if (pageToken != null) 'pageToken': pageToken});
      for (final item in data['items'] is List ? data['items'] as List : const []) {
        if (item is Map) onItem(item);
        if (limit != null && ++seen >= limit) return;
      }
      pageToken = data['nextPageToken'] is String ? data['nextPageToken'] as String : null;
    } while (pageToken != null);
  }

  Future<Map<String, dynamic>> _get(String resource, Map<String, String> query) async {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/$resource', query);
    final response = await _client.get(uri, headers: {'Authorization': 'Bearer ${await _accessToken()}'}).timeout(const Duration(seconds: 20));
    // Always UTF-8, whatever the headers say, so titles keep their characters.
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode != 200) throw YouTubeApiException(response.statusCode, errorReason(body));
    final data = jsonDecode(body);
    return data is Map<String, dynamic> ? data : const {};
  }

  /// A change: [body] as JSON, an empty answer read as an empty map.
  Future<Map<String, dynamic>> _send(String method, String resource, Map<String, String> query, [Map<String, Object?>? body]) async {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/$resource', query);
    final request = http.Request(method, uri)..headers['Authorization'] = 'Bearer ${await _accessToken()}';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    final response = await http.Response.fromStream(await _client.send(request)).timeout(const Duration(seconds: 20));
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 300) throw YouTubeApiException(response.statusCode, errorReason(text));
    if (text.trim().isEmpty) return const {};
    final data = jsonDecode(text);
    return data is Map<String, dynamic> ? data : const {};
  }

  static String? errorReason(String body) {
    try {
      final errors = (jsonDecode(body) as Map)['error']['errors'] as List;
      return (errors.first as Map)['reason']?.toString();
    } catch (_) {
      return null;
    }
  }
}

class YouTubeApiException implements Exception {
  const YouTubeApiException(this.status, this.reason);
  final int status;
  final String? reason;

  /// Where a Google Cloud project turns the YouTube Data API on.
  static const enableApiUrl = 'https://console.cloud.google.com/apis/library/youtube.googleapis.com';

  /// What [toString] says when the client's project has not turned the
  /// API on, so the settings page can offer a way there.
  static String get apiNotEnabled => tr('这个 Google 客户端所在的 Google Cloud 项目还没有启用 YouTube Data API v3。点“去启用”，确认顶部选中的是创建这个客户端的项目，点“启用”，等几分钟后再登录。');

  @override
  String toString() => switch (reason) {
        'quotaExceeded' || 'dailyLimitExceeded' => tr('YouTube API 今日配额已用完，请明天再同步'),
        'accessNotConfigured' => apiNotEnabled,
        'youtubeSignupRequired' => tr('这个 Google 账号还没有 YouTube 频道'),
        'insufficientPermissions' || 'ACCESS_TOKEN_SCOPE_INSUFFICIENT' => tr('登录时没有授予修改权限，请重新登录 Google 账号'),
        'commentsDisabled' => tr('这个视频关闭了评论'),
        'forbidden' when status == 403 => tr('YouTube 拒绝了这个操作'),
        'subscriptionForbidden' => tr('不能订阅这个频道'),
        'videoNotFound' => tr('找不到这个视频'),
        _ when status == 401 => tr('登录已失效，请重新登录'),
        _ => tr('YouTube API 请求失败（HTTP {0}{1}）', [status, reason == null ? '' : ' · $reason']),
      };
}
