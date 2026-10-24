import 'dart:convert';

import 'package:http/http.dart' as http;

/// A video's likes and dislikes as Return YouTube Dislike estimates them.
/// YouTube stopped showing dislikes in 2021; the project counts the
/// dislikes from before then and from its extension's users since, and
/// extrapolates the rest. No account is involved.
class DislikeCount {
  const DislikeCount({required this.likes, required this.dislikes});
  final int likes;
  final int dislikes;

  /// The share of likes among all votes, from 0 to 1.
  double get ratio => likes + dislikes == 0 ? 0 : likes / (likes + dislikes);
}

/// The public Return YouTube Dislike API
/// (github.com/Anarios/return-youtube-dislike). Unlike SponsorBlock it
/// takes the whole video id, so it is off unless the user turns it on.
class ReturnDislike {
  ReturnDislike(this._client);
  final http.Client _client;
  final _cache = <String, DislikeCount>{};

  static Uri requestUri(String videoId) => Uri.https('returnyoutubedislikeapi.com', '/votes', {'videoId': videoId});

  Future<DislikeCount?> votes(String videoId) async {
    final cached = _cache[videoId];
    if (cached != null) return cached;
    final response = await _client.get(requestUri(videoId), headers: {'User-Agent': 'Lumtub-Windows/0.1'}).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final count = parse(response.body);
    if (count != null) {
      if (_cache.length > 200) _cache.clear();
      _cache[videoId] = count;
    }
    return count;
  }

  static DislikeCount? parse(String body) {
    final data = jsonDecode(body);
    if (data is! Map || data['dislikes'] is! num) return null;
    return DislikeCount(likes: (data['likes'] as num? ?? 0).toInt(), dislikes: (data['dislikes'] as num).toInt());
  }
}
