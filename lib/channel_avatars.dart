import 'package:http/http.dart' as http;

import 'models.dart';

/// Finds the picture of a channel whose subscription was saved without one
/// (followed from a video or channel page), from the `og:image` of its public
/// page. One small request per channel, made once and then stored with it.
class ChannelAvatars {
  ChannelAvatars(this._client);
  final http.Client _client;

  static Uri pageUri(ChannelRef channel) => Uri.https('www.youtube.com', '/channel/${channel.id}');

  Future<String?> fetch(ChannelRef channel) async {
    final response = await _client.get(pageUri(channel), headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Lumtub-Windows/0.1',
      'Accept-Language': 'en',
      // Skips the cookie consent page shown in some regions.
      'Cookie': 'SOCS=CAI',
    }).timeout(const Duration(seconds: 15));
    return response.statusCode == 200 ? parse(response.body) : null;
  }

  /// The avatar in a channel page's `og:image`, or null.
  static String? parse(String html) {
    final tag = RegExp(r'<meta\s+property="og:image"\s+content="([^"]+)"').firstMatch(html);
    final url = tag == null ? null : ChannelRef.avatarUrl(tag.group(1)!.replaceAll('&amp;', '&'));
    // Channels without a picture list YouTube's own logo instead.
    return url != null && (url.contains('googleusercontent.com') || url.contains('ggpht.com')) ? url : null;
  }
}
