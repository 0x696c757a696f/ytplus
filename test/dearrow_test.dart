import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumtub/dearrow.dart';
import 'package:lumtub/player_settings.dart';

void main() {
  test('reads the best title and frame that are not YouTube\'s own', () {
    const id = 'dQw4w9WgXcQ';
    expect(DeArrow.requestUri(id).toString(), 'https://sponsor.ajay.app/api/branding/${DeArrow.hashPrefix(id)}');
    expect(DeArrow.hashPrefix(id), hasLength(4));
    final branding = DeArrow.parse('''{
      "other": {"titles": [{"title": "Not this one", "votes": 5, "locked": false, "original": false}]},
      "$id": {
        "titles": [
          {"title": "Voted down", "votes": -1, "locked": false, "original": false},
          {"title": "> Rick Astley sings Never Gonna Give You Up", "votes": 0, "locked": false, "original": false}
        ],
        "thumbnails": [{"timestamp": 42.5, "votes": 1, "locked": false, "original": false}],
        "randomTime": 0.3
      }
    }''', id);
    expect(branding.title, 'Rick Astley sings Never Gonna Give You Up');
    expect(branding.thumbnailTime, 42.5);
    expect(DeArrow.thumbnailUri(id, 42.5).toString(), 'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=$id&time=42.5');
    final original = DeArrow.parse('{"$id": {"titles": [{"title": "Same", "votes": 3, "original": true}], "thumbnails": [{"original": true, "votes": 2}]}}', id);
    expect(original.title, isNull);
    expect(original.thumbnailTime, isNull);
    expect(DeArrow.parse('[]', id).title, isNull);
  });

  test('replaces titles and thumbnails only when each switch is on', () {
    var titles = false;
    var thumbnails = false;
    deArrow.configure(http.Client(), titles: () => titles, thumbnails: () => thumbnails);
    deArrow.debugSet('aaaaaaaaaaa', const Branding(title: 'Plain title', thumbnailTime: 10));
    expect(deArrow.titleOf('aaaaaaaaaaa', 'CLICKBAIT!!!'), 'CLICKBAIT!!!');
    expect(deArrow.thumbnailOf('aaaaaaaaaaa'), isNull);
    titles = true;
    expect(deArrow.titleOf('aaaaaaaaaaa', 'CLICKBAIT!!!'), 'Plain title');
    expect(deArrow.thumbnailOf('aaaaaaaaaaa'), isNull);
    thumbnails = true;
    expect(deArrow.thumbnailOf('aaaaaaaaaaa')?.queryParameters['time'], '10.0');
    expect(const PlayerSettings().deArrowTitles, isFalse);
    expect(PlayerSettings.fromJson(const PlayerSettings(deArrowTitles: true).toJson()).deArrowTitles, isTrue);
    deArrow.configure(http.Client(), titles: () => false, thumbnails: () => false);
  });
}
