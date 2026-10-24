import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/feed_quality.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/recommendations.dart';

VideoItem v(String id, {String title = 'title', String channel = 'c', int? duration, int? width, int? height, String? description, bool shortListing = false, String? url}) => VideoItem(
      id: id.padRight(11, '_'),
      title: title,
      channel: channel,
      channelId: 'UC$id',
      url: url ?? 'https://www.youtube.com/watch?v=$id',
      duration: duration,
      width: width,
      height: height,
      description: description,
      isShortListing: shortListing,
    );

void main() {
  test('shorts: address, length, tagged length', () {
    expect(isShort(v('a', url: 'https://www.youtube.com/shorts/a')), isTrue);
    expect(isShort(v('a', shortListing: true, duration: 500)), isTrue);
    expect(isShort(v('a', duration: 45)), isTrue);
    expect(isShort(v('a', duration: 120)), isFalse);
    expect(isShort(v('a', duration: 120, title: 'fun #Shorts')), isTrue);
    expect(isShort(v('a', duration: 200, title: 'fun #shorts')), isFalse);
    expect(isShort(v('a')), isFalse);
  });

  test('vertical needs a known size', () {
    expect(isVertical(v('a', width: 1080, height: 1920)), isTrue);
    expect(isVertical(v('a', width: 1920, height: 1080)), isFalse);
    expect(isVertical(v('a', width: 1080, height: 1080)), isFalse);
    expect(isVertical(v('a')), isFalse);
  });

  test('VideoItem keeps the new fields through json', () {
    final item = VideoItem.fromJson({'id': 'abcdefghijk', 'title': 't', 'width': 720, 'height': 1280, 'description': 'Provided to YouTube by X', 'webpage_url': 'https://www.youtube.com/shorts/abcdefghijk'});
    expect(isVertical(item) && isShort(item), isTrue);
    final again = VideoItem.fromJson(item.toJson());
    expect((again.width, again.height, again.description, again.isShortListing), (720, 1280, 'Provided to YouTube by X', true));
  });

  group('recommend with a mix', () {
    final taste = TasteProfile.from(history: const []);
    final candidates = [
      Candidate(v('norm1', duration: 600), RecommendSource.related),
      Candidate(v('short', duration: 30), RecommendSource.related, seedWeight: 1.5),
      Candidate(v('mv', title: 'X (Official MV)', channel: 'X'), RecommendSource.related),
      Candidate(v('vert', width: 720, height: 1280, duration: 600), RecommendSource.related, seedWeight: 1.5),
    ];
    List<String> ids(FeedMix mix) => [for (final r in recommend(candidates, taste: taste, mix: mix)) r.item.id.replaceAll('_', '')];

    test('off keeps everything', () {
      expect(ids(const FeedMix()).toSet(), {'norm1', 'short', 'mv', 'vert'});
    });

    test('drop removes only that kind', () {
      expect(ids(const FeedMix(shorts: FeedLevel.drop)).toSet(), {'norm1', 'mv', 'vert'});
      expect(ids(const FeedMix(vertical: FeedLevel.drop)).toSet(), {'norm1', 'short', 'mv'});
    });

    test('reduce ranks the kind last even with a stronger source', () {
      final order = ids(const FeedMix(shorts: FeedLevel.reduce, vertical: FeedLevel.reduce));
      expect(order.take(2).toSet(), {'norm1', 'mv'});
      expect(order.skip(2).toSet(), {'short', 'vert'});
    });
  });

  test('preferences persist the levels, defaulting to reduce', () {
    expect(const AppPreferences().feedShorts, FeedLevel.reduce);
    final prefs = const AppPreferences().copyWith(feedShorts: FeedLevel.off, feedVertical: FeedLevel.reduce);
    final back = AppPreferences.fromJson(prefs.toJson());
    expect((back.feedShorts, back.feedVertical), (FeedLevel.off, FeedLevel.reduce));
    expect(AppPreferences.fromJson({'feedShorts': 'bogus'}).feedShorts, FeedLevel.reduce);
  });
}
