import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/models.dart';

void main() {
  test('yt-dlp flat search entries become video cards', () {
    const jsonLine = '{"id":"dQw4w9WgXcQ","title":"Example","channel":"Demo","duration":125}';
    final videos = VideoItem.fromJsonLines('$jsonLine\n');
    expect(videos, hasLength(1));
    expect(videos.first.url, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(videos.first.durationLabel, '2:05');
    expect(videos.first.channel, 'Demo');
  });

  test('duplicates and non-video entries are skipped', () {
    const valid = '{"id":"dQw4w9WgXcQ","title":"Example","channel":"Demo"}';
    final videos = VideoItem.fromJsonLines('$valid\n$valid\n{"id":"playlist"}\n');
    expect(videos, hasLength(1));
  });

  test('upcoming streams keep their scheduled start from yt-dlp', () {
    final item = VideoItem.fromJson({
      'id': 'dQw4w9WgXcQ',
      'title': 'Scheduled stream',
      'live_status': 'is_upcoming',
      'release_timestamp': 1767229200,
      'timestamp': 1767225600,
    });
    expect(item.isUpcoming, isTrue);
    expect(item.scheduledStart?.toUtc(), DateTime.utc(2026, 1, 1, 1));

    final restored = VideoItem.fromJson(item.toJson());
    expect(restored.scheduledStart?.toUtc(), DateTime.utc(2026, 1, 1, 1));
  });

  test('upcoming streams fall back to yt-dlp timestamp', () {
    final item = VideoItem.fromJson({
      'id': 'dQw4w9WgXcQ',
      'title': 'Scheduled stream',
      'live_status': 'is_upcoming',
      'timestamp': 1767225600,
    });
    expect(item.scheduledStart?.toUtc(), DateTime.utc(2026, 1, 1));
  });
}
