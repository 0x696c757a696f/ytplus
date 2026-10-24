import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/return_dislike.dart';

void main() {
  test('reads Return YouTube Dislike votes; off unless turned on', () {
    expect(ReturnDislike.requestUri('dQw4w9WgXcQ').toString(), 'https://returnyoutubedislikeapi.com/votes?videoId=dQw4w9WgXcQ');
    final votes = ReturnDislike.parse('{"id":"dQw4w9WgXcQ","likes":900,"dislikes":100,"rating":4.6,"viewCount":5}');
    expect(votes?.dislikes, 100);
    expect(votes?.likes, 900);
    expect(votes?.ratio, 0.9);
    expect(ReturnDislike.parse('{"error":"not found"}'), isNull);
    expect(const PlayerSettings().returnDislike, isFalse);
    expect(PlayerSettings.fromJson(const PlayerSettings(returnDislike: true).toJson()).returnDislike, isTrue);
  });
}
