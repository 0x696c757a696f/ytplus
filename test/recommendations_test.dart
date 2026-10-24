import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/home_feed.dart';
import 'package:lumtub/library_store.dart' show WatchProgress;
import 'package:lumtub/models.dart';
import 'package:lumtub/recommendations.dart';
import 'package:lumtub/youtube_related.dart';

VideoItem video(String id, {String title = '', String channel = 'c', String? channelId, int? views, int? duration, DateTime? published}) => VideoItem(
      id: id.padRight(11, '_'),
      title: title,
      channel: channel,
      channelId: channelId,
      url: 'https://www.youtube.com/watch?v=$id',
      viewCount: views,
      duration: duration,
      published: published,
    );

void main() {
  group('TasteProfile', () {
    test('weighs recent channels and shared title words', () {
      final taste = TasteProfile.from(history: [
        video('a', title: '原神 新角色 实机演示', channelId: 'UCgame'),
        video('b', title: '原神 剧情 解说', channelId: 'UCgame'),
        video('c', title: 'Lofi hip hop radio', channelId: 'UClofi'),
      ]);
      expect(taste.topChannels(1), ['UCgame']);
      expect(taste.channelAffinity(video('x', channelId: 'UCgame')), 1);
      expect(taste.channelAffinity(video('x', channelId: 'UCother')), 0);
      expect(taste.titleMatch(video('x', title: '原神 4.0 前瞻')), greaterThan(taste.titleMatch(video('y', title: '红烧肉做法'))));
      expect(TasteProfile.titleWords('Official MV 原神'), {'原神'});
    });
  });

  group('recommend', () {
    final taste = TasteProfile.from(history: [
      for (var i = 0; i < 5; i++) video('h$i', title: '机械键盘 评测', channelId: 'UCkeys'),
    ]);

    test('puts close matches first and skips what was watched or dismissed', () async {
      final notInterested = NotInterested(null);
      await notInterested.add(video('bad', channelId: 'UCbad'));
      final ranked = recommend([
        Candidate(video('cook', title: '家常菜', channelId: 'UCcook'), RecommendSource.topic),
        Candidate(video('keys', title: '机械键盘 轴体 评测', channelId: 'UCkeys'), RecommendSource.related),
        Candidate(video('h1', title: '机械键盘 评测', channelId: 'UCkeys'), RecommendSource.related),
        Candidate(video('bad', channelId: 'UCbad'), RecommendSource.related),
      ], taste: taste, exclude: {video('h1').id}, notInterested: notInterested).map((r) => r.item).toList();
      expect(ranked.map((v) => v.id.replaceAll('_', '')), ['keys', 'cook']);
    });

    test('keeps one channel from filling the top', () {
      final ranked = recommend([
        for (var i = 0; i < 10; i++) Candidate(video('k$i', title: '机械键盘 评测', channelId: 'UCkeys'), RecommendSource.related),
        for (var i = 0; i < 4; i++) Candidate(video('o$i', title: '别的', channelId: 'UCo$i'), RecommendSource.topic),
      ], taste: taste, count: 8).map((r) => r.item).toList();
      final fromKeys = ranked.where((v) => v.channelId == 'UCkeys').length;
      expect(fromKeys, lessThan(8));
      expect(ranked.length, 8);
    });

    test('counts a video suggested twice once, higher', () {
      final ranked = recommend([
        Candidate(video('twice', channelId: 'UCa'), RecommendSource.topic),
        Candidate(video('twice', channelId: 'UCa'), RecommendSource.channel),
        Candidate(video('once', channelId: 'UCb'), RecommendSource.channel),
      ], taste: taste).map((r) => r.item).toList();
      expect(ranked.length, 2);
      expect(ranked.first.id, video('twice').id);
    });

    test('a different seed changes the order a little, not the set', () {
      final candidates = [for (var i = 0; i < 20; i++) Candidate(video('v$i', channelId: 'UC$i'), RecommendSource.topic)];
      final a = recommend(candidates, taste: taste, seed: 1).map((r) => r.item).toList();
      final b = recommend(candidates, taste: taste, seed: 2).map((r) => r.item).toList();
      expect(a.map((v) => v.id).toSet(), b.map((v) => v.id).toSet());
      expect(a.map((v) => v.id).toList(), isNot(b.map((v) => v.id).toList()));
    });
  });

  test('NotInterested is saved', () async {
    final dir = await Directory.systemTemp.createTemp('lumtub_ni');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/not_interested.json');
    await NotInterested(file).add(video('x', channelId: 'UCx'));
    final loaded = NotInterested(file);
    await loaded.load();
    expect(loaded.videos, {video('x').id});
    expect(loaded.channels, {'UCx': 1});
  });

  group('HomeFeed', () {
    test('gathers from related videos, channels and topics', () async {
      final asked = <String>[];
      final feed = HomeFeed(NotInterested(null));
      await feed.refresh(HomeFeedSources(
        history: [video('seen', title: '机械键盘 评测', channelId: 'UCkeys', channel: 'Keys')],
        subscriptions: [video('sub', channelId: 'UCsub')],
        followed: const [ChannelRef('UCsub', 'Sub')],
        related: (id) async {
          asked.add('related $id');
          return [video('rel', title: '机械键盘 推荐', channelId: 'UCother'), video('seen', channelId: 'UCkeys')];
        },
        channelUploads: (channel) async {
          asked.add('channel ${channel.id}');
          return [video('up', channelId: channel.id)];
        },
        search: (query) async {
          asked.add('search');
          throw StateError('offline');
        },
      ));
      expect(asked, contains('related ${video('seen').id}'));
      expect(asked, contains('channel UCkeys'));
      expect(asked, isNot(contains('channel UCsub')));
      final ids = feed.items.map((v) => v.id.replaceAll('_', '')).toSet();
      expect(ids, containsAll(['rel', 'up', 'sub']));
      expect(ids, isNot(contains('seen')));
      expect(feed.error, isNull);

      final first = feed.items.map((v) => v.id).toSet();
      feed.shuffle();
      // Only three candidates: after 换一批 runs out it starts over.
      expect(feed.items, isNotEmpty);
      expect(first, isNotEmpty);
      await feed.dismiss(feed.items.first);
      expect(feed.notInterested.videos, hasLength(1));
    });

    test('starts from popular videos with no history', () async {
      final feed = HomeFeed(NotInterested(null));
      String? query;
      await feed.refresh(HomeFeedSources(
        history: const [],
        related: (_) async => const [],
        channelUploads: (_) async => const [],
        search: (q) async {
          query = q;
          return [video('pop', channelId: 'UCpop')];
        },
      ));
      expect(query, '热门');
      expect(feed.items, hasLength(1));
    });

    test('shows a first page before a slow search answers', () async {
      final slow = Completer<List<VideoItem>>();
      final feed = HomeFeed(NotInterested(null));
      final done = feed.refresh(HomeFeedSources(
        history: const [],
        subscriptions: [video('sub', channelId: 'UCsub')],
        related: (_) async => const [],
        channelUploads: (_) async => const [],
        search: (_) => slow.future,
      ));
      await Future<void>.delayed(HomeFeed.firstPageWait + const Duration(milliseconds: 100));
      expect(feed.loading, isFalse);
      expect(feed.gathering, isTrue);
      final shown = feed.items.map((v) => v.id).toList();
      expect(shown, hasLength(1));
      slow.complete([video('pop', channelId: 'UCpop')]);
      await done;
      expect(feed.gathering, isFalse);
      expect(feed.items.map((v) => v.id).take(shown.length), shown, reason: '先显示的不会被重新排序');
      expect(feed.items, hasLength(2));
    });

    test('shows the saved feed on the next launch without dismissed videos', () async {
      final dir = await Directory.systemTemp.createTemp('home_feed');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/home_feed.json');
      final feed = HomeFeed(NotInterested(null), cacheFile: file);
      await feed.refresh(HomeFeedSources(
        history: const [],
        related: (_) async => const [],
        channelUploads: (_) async => const [],
        search: (_) async => [video('a', channelId: 'UCa'), video('b', channelId: 'UCb')],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(file.existsSync(), isTrue);

      final dismissed = NotInterested(null)..videos.add(video('a').id);
      final next = HomeFeed(dismissed, cacheFile: file);
      await next.restore(filter: (items) => items.where((v) => v.channelId != 'UCblocked').toList());
      expect(next.items.map((v) => v.id), [video('b').id]);
      expect(next.reasons[video('b').id], isNotNull);
    });
  });

  group('YoutubeRelated.parse', () {
    test('reads compact video renderers', () {
      final items = YoutubeRelated.parse({
        'contents': {
          'twoColumnWatchNextResults': {
            'secondaryResults': {
              'secondaryResults': {
                'results': [
                  {
                    'compactVideoRenderer': {
                      'videoId': 'abcdefghijk',
                      'title': {'simpleText': '标题'},
                      'longBylineText': {
                        'runs': [
                          {'text': '频道', 'navigationEndpoint': {'browseEndpoint': {'browseId': 'UCxxxxxxxxxxxxxxxxxxxxxx'}}},
                        ],
                      },
                      'lengthText': {'simpleText': '12:34'},
                      'viewCountText': {'simpleText': '12万次观看'},
                    },
                  },
                  {'compactRadioRenderer': {'playlistId': 'RD123'}},
                ],
              },
            },
          },
        },
      });
      expect(items, hasLength(1));
      final item = items.single;
      expect((item.id, item.title, item.channel, item.channelId, item.duration, item.viewCount), ('abcdefghijk', '标题', '频道', 'UCxxxxxxxxxxxxxxxxxxxxxx', 754, 120000));
    });

    test('reads lockup view models and skips playlists', () {
      final items = YoutubeRelated.parse([
        {
          'lockupViewModel': {
            'contentId': 'ABCDEFGHIJK',
            'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
            'contentImage': {
              'thumbnailViewModel': {
                'overlays': [
                  {
                    'thumbnailOverlayBadgeViewModel': {
                      'thumbnailBadges': [
                        {'thumbnailBadgeViewModel': {'text': '1:02:03'}},
                      ],
                    },
                  },
                ],
              },
            },
            'metadata': {
              'lockupMetadataViewModel': {
                'title': {'content': 'Lockup 标题'},
                'image': {
                  'decoratedAvatarViewModel': {
                    'rendererContext': {
                      'commandContext': {
                        'onTap': {'innertubeCommand': {'browseEndpoint': {'browseId': 'UCyyyyyyyyyyyyyyyyyyyyyy'}}},
                      },
                    },
                  },
                },
                'metadata': {
                  'contentMetadataViewModel': {
                    'metadataRows': [
                      {'metadataParts': [{'text': {'content': 'Some Channel'}}]},
                      {'metadataParts': [{'text': {'content': '3.4万次观看'}}, {'text': {'content': '2天前'}}]},
                    ],
                  },
                },
              },
            },
          },
        },
        {'lockupViewModel': {'contentId': 'PLxxxxxxxxx', 'contentType': 'LOCKUP_CONTENT_TYPE_PLAYLIST'}},
      ]);
      expect(items, hasLength(1));
      final item = items.single;
      expect((item.id, item.title, item.channel, item.channelId, item.duration, item.viewCount), ('ABCDEFGHIJK', 'Lockup 标题', 'Some Channel', 'UCyyyyyyyyyyyyyyyyyyyyyy', 3723, 34000));
    });
  });

  group('taste details', () {
    test('words in every title count less than distinctive ones', () {
      final taste = TasteProfile.from(history: [
        video('a', title: '教程 机械键盘'),
        video('b', title: '教程 剪辑'),
        video('c', title: '教程 摄影'),
      ]);
      expect(taste.words['教程']! / 3, lessThan(taste.words['键盘']!));
    });

    test('a video left within seconds counts against its channel', () {
      final taste = TasteProfile.from(
        history: [video('a', channelId: 'UCskip', title: '不喜欢'), video('b', channelId: 'UCgood', title: '喜欢')],
        progressOf: (id) => id.startsWith('a')
            ? const WatchProgress(Duration(seconds: 5), Duration(minutes: 10))
            : const WatchProgress(Duration(minutes: 9), Duration(minutes: 10)),
      );
      expect(taste.channelAffinity(video('x', channelId: 'UCskip')), lessThan(0));
      expect(taste.channelAffinity(video('x', channelId: 'UCgood')), 1);
      expect(taste.words.containsKey('不喜'), isFalse);
    });

    test('searches count as interests', () {
      final taste = TasteProfile.from(history: const [], searches: ['露营装备']);
      expect(taste.titleMatch(video('x', title: '露营装备推荐')), greaterThan(0.5));
    });

    test('keeps the reason of the stronger source', () {
      final taste = TasteProfile.from(history: const []);
      final picked = recommend([
        Candidate(video('v', channelId: 'UCa'), RecommendSource.topic, reason: '热门'),
        Candidate(video('v', channelId: 'UCa'), RecommendSource.related, reason: '看过《A》的人也在看'),
      ], taste: taste);
      expect(picked.single.reason, '看过《A》的人也在看');
    });
  });

  test('mixLanes follows the lanes\' shares and skips repeats', () {
    List<Recommendation> lane(String prefix, int n) => [for (var i = 0; i < n; i++) Recommendation(video('$prefix$i'), prefix)];
    final lanes = {
      FeedLane.longTerm: lane('l', 50),
      FeedLane.recent: [Recommendation(video('l0'), 'dup'), ...lane('r', 50)],
      FeedLane.explore: lane('e', 50),
      FeedLane.fresh: lane('f', 50),
    };
    final mixed = mixLanes(lanes, 20);
    expect(mixed.map((r) => r.item.id).toSet(), hasLength(20));
    int count(String reason) => mixed.where((r) => r.reason == reason).length;
    expect((count('l'), count('r'), count('e'), count('f')), (7, 6, 4, 3));
    // A lane that runs dry leaves its share to the others.
    final short = mixLanes({FeedLane.longTerm: lane('a', 2), FeedLane.fresh: lane('b', 10)}, 8);
    expect(short, hasLength(8));
  });

  test('HomeFeed scrolls on and follows the video just watched', () async {
    var n = 0;
    Future<List<VideoItem>> related(String id) async => [for (var i = 0; i < 12; i++) video('x${n++}', title: '相关 $id', channelId: 'UC${n % 9}')];
    HomeFeedSources sources(List<VideoItem> history) => HomeFeedSources(
          history: history,
          related: related,
          channelUploads: (_) async => const [],
          search: (_) async => [for (var i = 0; i < 10; i++) video('s${n++}', channelId: 'UCs${n % 7}')],
        );
    final feed = HomeFeed(NotInterested(null));
    final watched = [video('w1', title: '咖啡 拉花', channelId: 'UCcafe')];
    await feed.refresh(sources(watched));
    expect(feed.items, hasLength(HomeFeed.pageSize));
    expect(feed.items.every((v) => feed.reasons[v.id]?.isNotEmpty ?? false), isTrue);
    await feed.loadMore();
    expect(feed.items.length, greaterThan(HomeFeed.pageSize));
    expect(feed.items.map((v) => v.id).toSet(), hasLength(feed.items.length), reason: 'no repeats');

    final next = video('w2', title: '手冲 咖啡豆', channelId: 'UCbeans');
    await feed.learn(next, sources([next, ...watched]), skipped: false);
    expect(feed.reasons[feed.items.first.id], startsWith('刚看完《手冲 咖啡豆》'));
  });
}
