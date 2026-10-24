import 'package:http/http.dart' as http;

import 'models.dart';
import 'l10n/l10n.dart';

/// Reads a channel's public Atom feed, which lists its latest 15 uploads with
/// their publish times in one small request, without yt-dlp.
class ChannelFeed {
  ChannelFeed(this._client, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final http.Client _client;
  final DateTime Function() _clock;

  /// Channels whose feed answered 404, and when. Some channels have no
  /// feed at all; asking again on every refresh only delays the fallback.
  final _missing = <String, DateTime>{};
  static const missingFor = Duration(days: 1);

  static Uri feedUri(ChannelRef channel) => Uri.https('www.youtube.com', '/feeds/videos.xml', {'channel_id': channel.id});

  Future<List<VideoItem>> latest(ChannelRef channel) async {
    final missingSince = _missing[channel.id];
    if (missingSince != null && _clock().difference(missingSince) < missingFor) throw StateError(tr('频道订阅源返回 HTTP {0}', [404]));
    final response = await _client.get(feedUri(channel), headers: {'User-Agent': 'Lumtub-Windows/0.1'}).timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) _missing[channel.id] = _clock();
    if (response.statusCode != 200) throw StateError(tr('频道订阅源返回 HTTP {0}', [response.statusCode]));
    _missing.remove(channel.id);
    return parse(response.body, channel);
  }

  /// Parses the feed. The format is fixed and small, so a few patterns are
  /// enough and no XML package is needed.
  static List<VideoItem> parse(String xml, ChannelRef channel) {
    final items = <VideoItem>[];
    for (final entry in RegExp(r'<entry>([\s\S]*?)</entry>').allMatches(xml)) {
      final body = entry.group(1)!;
      String? field(String pattern) => RegExp(pattern).firstMatch(body)?.group(1);
      final id = field(r'<yt:videoId>([\w-]{11})</yt:videoId>');
      if (id == null) continue;
      final views = field(r'<media:statistics views="(\d+)"');
      items.add(VideoItem(
        id: id,
        title: _unescape(field(r'<title>([\s\S]*?)</title>') ?? ''),
        channel: channel.name.isNotEmpty ? channel.name : _unescape(field(r'<name>([\s\S]*?)</name>') ?? ''),
        url: 'https://www.youtube.com/watch?v=$id',
        viewCount: views == null ? null : int.tryParse(views),
        channelId: channel.id,
        published: DateTime.tryParse(field(r'<published>([^<]+)</published>') ?? ''),
      ));
    }
    return items;
  }

  static String _unescape(String text) => text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&')
      .trim();
}
