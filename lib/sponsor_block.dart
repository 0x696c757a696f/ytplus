import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'player_settings.dart';

/// A part of a video that SponsorBlock users marked, in seconds.
class SkipSegment {
  const SkipSegment(this.start, this.end, this.category);
  final Duration start;
  final Duration end;
  final String category;

  bool contains(Duration position) => position >= start && position < end - const Duration(milliseconds: 500);
}

/// Labels for the categories Lumtub can skip.
final sponsorCategories = {for (final entry in sponsorCategoryNames.entries) entry.key: entry.value.$1};

/// Looks up skip segments from the public SponsorBlock API.
///
/// Only the first four hex digits of the video id's SHA-256 are sent, so the
/// server cannot tell which video is being watched: it answers with the
/// segments of every video sharing that prefix, and the match happens here.
class SponsorBlock {
  SponsorBlock(this._client);
  final http.Client _client;

  static String hashPrefix(String videoId) => sha256.convert(utf8.encode(videoId)).toString().substring(0, 4);

  static Uri requestUri(String videoId, [Set<String> categories = PlayerSettings.defaultSponsorCategories]) =>
      Uri.https('sponsor.ajay.app', '/api/skipSegments/${hashPrefix(videoId)}', {
        'categories': jsonEncode(categories.toList()),
      });

  Future<List<SkipSegment>> segments(String videoId, [Set<String> categories = PlayerSettings.defaultSponsorCategories]) async {
    if (categories.isEmpty) return const [];
    final response = await _client.get(requestUri(videoId, categories), headers: {'User-Agent': 'Lumtub-Windows/0.1'}).timeout(const Duration(seconds: 10));
    // 404 means no video with this prefix has segments.
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) throw StateError('SponsorBlock HTTP ${response.statusCode}');
    return parse(response.body, videoId, categories);
  }

  static List<SkipSegment> parse(String body, String videoId, [Set<String> categories = PlayerSettings.defaultSponsorCategories]) {
    final data = jsonDecode(body);
    if (data is! List) return const [];
    final segments = <SkipSegment>[];
    for (final video in data) {
      if (video is! Map || video['videoID'] != videoId || video['segments'] is! List) continue;
      for (final raw in video['segments'] as List) {
        if (raw is! Map || raw['segment'] is! List || (raw['actionType'] ?? 'skip') != 'skip') continue;
        final bounds = raw['segment'] as List;
        if (bounds.length != 2 || bounds[0] is! num || bounds[1] is! num) continue;
        final category = raw['category']?.toString() ?? '';
        if (!categories.contains(category)) continue;
        final start = Duration(milliseconds: ((bounds[0] as num) * 1000).round());
        final end = Duration(milliseconds: ((bounds[1] as num) * 1000).round());
        if (end > start) segments.add(SkipSegment(start, end, category));
      }
    }
    segments.sort((a, b) => a.start.compareTo(b.start));
    return segments;
  }
}
