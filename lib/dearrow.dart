import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What DeArrow's users put in place of a video's title and thumbnail:
/// a plain title, and the time of a frame to show. Null keeps YouTube's.
class Branding {
  const Branding({this.title, this.thumbnailTime});
  final String? title;
  final double? thumbnailTime;

  static const none = Branding();
}

/// Titles and thumbnails from DeArrow (github.com/ajayyy/DeArrow), the
/// SponsorBlock author's crowd-sourced replacement for clickbait.
///
/// Titles are looked up like SponsorBlock's segments, by the first four
/// hex digits of the video id's SHA-256, so the server cannot tell which
/// video is shown. A replaced thumbnail is a frame its server renders for
/// a given video id, so thumbnails have a switch of their own.
class DeArrow extends ChangeNotifier {
  DeArrow._();

  http.Client? _client;
  bool Function() _titles = () => false;
  bool Function() _thumbnails = () => false;

  /// Turns it on: [titles] and [thumbnails] say, when asked, whether
  /// each part is wanted.
  void configure(http.Client client, {required bool Function() titles, required bool Function() thumbnails}) {
    _client = client;
    _titles = titles;
    _thumbnails = thumbnails;
  }

  bool get titlesOn => _titles();
  bool get thumbnailsOn => _thumbnails();

  final _branding = <String, Branding>{};
  final _pending = <String>{};
  final _queue = <String>[];
  var _running = 0;
  Timer? _notify;

  static String hashPrefix(String videoId) => sha256.convert(utf8.encode(videoId)).toString().substring(0, 4);

  static Uri requestUri(String videoId) => Uri.https('sponsor.ajay.app', '/api/branding/${hashPrefix(videoId)}');

  static Uri thumbnailUri(String videoId, double time) =>
      Uri.https('dearrow-thumb.ajay.app', '/api/v1/getThumbnail', {'videoID': videoId, 'time': '$time'});

  /// [videoId]'s branding once looked up; asks for it the first time.
  Branding brandingOf(String videoId) {
    if (!titlesOn && !thumbnailsOn) return Branding.none;
    final known = _branding[videoId];
    if (known != null) return known;
    if (_client != null && _pending.add(videoId)) {
      _queue.add(videoId);
      _pump();
    }
    return Branding.none;
  }

  /// The title to show for a video called [title].
  String titleOf(String videoId, String title) => titlesOn ? brandingOf(videoId).title ?? title : title;

  /// The frame to show in place of the thumbnail, if one was chosen.
  Uri? thumbnailOf(String videoId) {
    if (!thumbnailsOn) return null;
    final time = brandingOf(videoId).thumbnailTime;
    return time == null ? null : thumbnailUri(videoId, time);
  }

  /// A few lookups at a time, so a page of cards does not open twenty
  /// connections at once.
  void _pump() {
    while (_running < 4 && _queue.isNotEmpty) {
      final id = _queue.removeLast();
      _running++;
      unawaited(_fetch(id).whenComplete(() {
        _running--;
        _pump();
      }));
    }
  }

  Future<void> _fetch(String videoId) async {
    Branding found = Branding.none;
    try {
      final response = await _client!.get(requestUri(videoId), headers: {'User-Agent': 'Lumtub-Windows/0.1'}).timeout(const Duration(seconds: 10));
      // 404: no video with this prefix has submissions.
      if (response.statusCode == 200) found = parse(response.body, videoId);
    } catch (_) {
      // Shown as YouTube has it; asked again after a restart.
    }
    if (_branding.length > 5000) _branding.clear();
    _branding[videoId] = found;
    _pending.remove(videoId);
    if (found.title != null || found.thumbnailTime != null) {
      // One rebuild for a burst of answers.
      _notify ??= Timer(const Duration(milliseconds: 150), () {
        _notify = null;
        notifyListeners();
      });
    }
  }

  /// The branding for [videoId] in a response for its hash prefix: the
  /// best title and thumbnail that are not YouTube's own, as DeArrow's
  /// extension takes them (locked by a moderator, or not voted down).
  static Branding parse(String body, String videoId) {
    final data = jsonDecode(body);
    if (data is! Map || data[videoId] is! Map) return Branding.none;
    final video = data[videoId] as Map;
    bool trusted(Map entry) => entry['locked'] == true || (entry['votes'] is num && (entry['votes'] as num) >= 0);
    Map? best(Object? list) => list is List ? list.whereType<Map>().where(trusted).firstOrNull : null;
    final title = best(video['titles']);
    final thumbnail = best(video['thumbnails']);
    // A title starting with ">" asks not to be re-cased; the mark is not shown.
    final text = title == null || title['original'] == true ? null : '${title['title'] ?? ''}'.replaceFirst(RegExp(r'^>\s*'), '').trim();
    final time = thumbnail == null || thumbnail['original'] == true ? null : thumbnail['timestamp'];
    return Branding(title: text == null || text.isEmpty ? null : text, thumbnailTime: time is num ? time.toDouble() : null);
  }

  @visibleForTesting
  void debugSet(String videoId, Branding branding) => _branding[videoId] = branding;
}

/// The one DeArrow lookup the app shares; video cards read it.
final deArrow = DeArrow._();
