import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/sponsor_block.dart';

void main() {
  test('sends only a short hash prefix of the video id', () {
    expect(SponsorBlock.hashPrefix('dQw4w9WgXcQ'), '5f6b');
    final uri = SponsorBlock.requestUri('dQw4w9WgXcQ');
    expect(uri.host, 'sponsor.ajay.app');
    expect(uri.path, '/api/skipSegments/5f6b');
    expect(uri.toString(), isNot(contains('dQw4w9WgXcQ')));
  });

  test('keeps the skip segments of the requested video only', () {
    const body = '''[
      {"videoID": "otherVideo1", "segments": [{"segment": [1, 20], "category": "sponsor", "actionType": "skip"}]},
      {"videoID": "dQw4w9WgXcQ", "segments": [
        {"segment": [120.5, 150], "category": "selfpromo", "actionType": "skip"},
        {"segment": [10, 30.25], "category": "sponsor", "actionType": "skip"},
        {"segment": [40, 50], "category": "sponsor", "actionType": "mute"},
        {"segment": [60, 70], "category": "music_offtopic", "actionType": "skip"},
        {"segment": [80, 80], "category": "sponsor"}
      ]}
    ]''';
    final segments = SponsorBlock.parse(body, 'dQw4w9WgXcQ');
    expect(segments, hasLength(2));
    expect(segments.first.start, const Duration(seconds: 10));
    expect(segments.first.end, const Duration(milliseconds: 30250));
    expect(segments.first.category, 'sponsor');
    expect(segments.last.category, 'selfpromo');
    expect(SponsorBlock.parse('{}', 'dQw4w9WgXcQ'), isEmpty);
  });

  test('skips while inside a segment, not at its very end', () {
    const segment = SkipSegment(Duration(seconds: 10), Duration(seconds: 30), 'sponsor');
    expect(segment.contains(const Duration(seconds: 9)), isFalse);
    expect(segment.contains(const Duration(seconds: 10)), isTrue);
    expect(segment.contains(const Duration(milliseconds: 29800)), isFalse);
  });
}
