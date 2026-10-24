import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/blocked_groups.dart';
import 'package:lumtub/explore_filters.dart';
import 'package:lumtub/explore_topics.dart';
import 'package:lumtub/faith_topics.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/recommendations.dart';
import 'package:lumtub/search_options.dart';
import 'package:lumtub/state_media.dart';
import 'package:lumtub/ui/pages/explore_page.dart';

/// Narrower than [ExplorePage.wideLayout], so zones are in a row on top.
Future<AppController> _open(WidgetTester tester, {double width = 950}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = AppController()..ready = true;
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
    listenable: controller,
    builder: (context, _) => ExplorePage(controller: controller),
  ))));
  await tester.pump();
  return controller;
}

/// Scrolls the zone strip with its arrow until [label] is in view.
Future<void> _reveal(WidgetTester tester, String label) async {
  bool inView() {
    final found = find.text(label);
    if (found.evaluate().isEmpty) return false;
    final rect = tester.getRect(found.last);
    return rect.left > 40 && rect.right < 910;
  }

  // The arrows appear a frame after the strip is laid out.
  await tester.pump();
  for (var turn = 0; turn < 20 && !inView(); turn++) {
    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  expect(inView(), isTrue, reason: '$label is in view');
}

void main() {
  test('each mode asks YouTube for its own order and filters', () {
    expect(exploreParams(ExploreMode.popular, period: SearchUploadDate.month), 'CAMSBAgEEAE%253D');
    expect(exploreParams(ExploreMode.liveViewers), 'CAMSAkAB');
    // Newest first, videos only.
    expect(exploreParams(ExploreMode.latest), 'CAISAhAB');
    // Long: views, this year, videos, over 20 minutes.
    expect(exploreParams(ExploreMode.long), 'CAMSBggFEAEYAg%253D%253D');
    final hdr = base64.decode(searchParams(quality: SearchQuality.hdr)!.replaceAll('%253D', '='));
    expect(hdr, [0x12, 3, 0xC8, 0x01, 1]);
    final uhd = base64.decode(exploreParams(ExploreMode.liveViewers, quality: SearchQuality.uhd).replaceAll('%253D', '='));
    expect(uhd, [0x08, 3, 0x12, 4, 0x40, 1, 0x70, 1]);
  });

  test('every zone splits into a similar number of sub-categories, without repeats', () {
    // Video zones 8-14, live zones 6-10, 宗教与信仰 tabs 5-10 (Christianity
    // is split by branch, one level further).
    const ranges = {
      ExploreSection.popular: (8, 14),
      ExploreSection.live: (6, 10),
      ExploreSection.faith: (5, 10),
      ExploreSection.faithStudy: (6, 10),
      ExploreSection.faithArts: (6, 10),
      ExploreSection.faithLive: (5, 10),
    };
    for (final MapEntry(key: section, value: (min, max)) in ranges.entries) {
      for (final topic in exploreTopicsOf(section)) {
        if (topic.mix || topic.opens != null) {
          expect(topic.subs, isEmpty, reason: topic.label);
          continue;
        }
        expect(topic.subs.length, inInclusiveRange(min, max), reason: '${section.name} ${topic.label}');
        expect(topic.subs.map((s) => s.label).toSet(), hasLength(topic.subs.length), reason: '${topic.label} labels');
        expect(topic.subs.map((s) => s.query).toSet(), hasLength(topic.subs.length), reason: '${topic.label} queries');
      }
    }
    // No two sub-categories of one half search for the same words.
    for (final section in [ExploreSection.popular, ExploreSection.live]) {
      final queries = [for (final t in exploreTopicsOf(section)) for (final s in t.subs) s.query];
      expect(queries.toSet(), hasLength(queries.length), reason: section.name);
    }
  });

  test('宗教与信仰 has four tabs of zones, with Christianity split twice', () {
    expect(ExploreSection.faithTabs.map((s) => s.label), ['宗教传统', '宗教学术', '文化艺术', '宗教直播']);
    final christian = faithTraditionTopics.first;
    expect(christian.label, '基督宗教');
    expect(christian.subs.map((s) => s.label), ['天主教', '东正教', '新教', '东方正统教会', '其他基督宗教']);
    final catholic = christian.subs.first;
    expect(catholic.subs.map((s) => s.label), containsAll(['教宗讲话', '梵蒂冈新闻', '弥撒', '圣事', '圣人传记', '修会生活', '教会音乐']));
    expect(christian.subs[2].subs.map((s) => s.label), containsAll(['路德宗', '改革宗', '圣公会', '卫理宗', '浸信会', '五旬节派', '福音派']));
    expect(faithTraditionTopics.map((t) => t.label), containsAll(['伊斯兰教', '佛教', '道教与中国传统信仰', '印度教', '犹太教', '其他宗教']));
    expect(faithStudyTopics.map((t) => t.label), containsAll(['宗教历史', '宗教哲学', '比较宗教学', '宗教与社会', '无神论与宗教批评', '宗教对话']));
    expect(faithLiveTopics, hasLength(10));
    for (final section in ExploreSection.values) {
      final topics = exploreTopicsOf(section);
      expect(topics.map((t) => t.key).toSet(), hasLength(topics.length), reason: section.name);
      for (final topic in topics) {
        expect(topic.mix || topic.query.isNotEmpty, isTrue, reason: topic.label);
        for (final sub in topic.subs) {
          expect([sub.query, for (final leaf in sub.subs) leaf.query], everyElement(isNotEmpty));
        }
      }
    }
    // Among the video zones, 宗教信仰 opens the tabs.
    expect(popularTopics.singleWhere((t) => t.label == '宗教信仰').opens, ExploreSection.faith);
    expect(ExploreMode.of(ExploreSection.faith).first, ExploreMode.curated);
    expect(ExploreMode.of(ExploreSection.popular), isNot(contains(ExploreMode.curated)));
    expect(ExploreMode.of(ExploreSection.faithLive), [ExploreMode.liveViewers, ExploreMode.liveLatest, ExploreMode.liveUpcoming, ExploreMode.liveReplay]);
    // Upcoming and past streams come from the newest videos.
    expect(exploreParams(ExploreMode.liveUpcoming), 'CAISAhAB');
    expect(exploreParams(ExploreMode.curated), 'EgIQAQ%253D%253D');
  });

  test('宗教与信仰 leaves out bait and keeps a channel to three videos', () {
    expect(looksLikeBait('Atheist DESTROYS pastor in debate'), isTrue);
    expect(looksLikeBait('震惊！神父说出真相'), isTrue);
    expect(looksLikeBait('WHAT THE CHURCH WILL NOT TELL YOU'), isTrue);
    expect(looksLikeBait('You must see this!!!'), isTrue);
    expect(looksLikeBait('Holy Mass from St Peter\'s Basilica'), isFalse);
    expect(looksLikeBait('天主教的七件圣事'), isFalse);
    expect(looksLikeBait('EWTN Daily Mass'), isFalse);
    final keep = faithFilter();
    VideoItem video(int i, String channel) => VideoItem(id: 'v$i'.padRight(11, '0'), title: 'Mass $i', channel: channel, url: '');
    final kept = [for (var i = 0; i < 6; i++) video(i, i < 5 ? 'a' : 'b')].where(keep).map((v) => v.channel).toList();
    expect(kept, ['a', 'a', 'a', 'b']);
  });

  test('blocked groups show in a search only for the exact channel name, and the setting turns it off', () {
    VideoItem video(String id, String title, String channel) => VideoItem(id: id.padRight(11, '0'), title: title, channel: channel, url: '');
    final items = [video('a', '新闻', 'NTD Television'), video('b', 'Shen Yun 2026', 'Shen Yun Performing Arts'), video('c', '弥撒', 'EWTN')];
    final controller = AppController();
    String ids(List<VideoItem> list) => list.map((v) => v.id[0]).join();
    expect(ids(controller.visible(items)), 'c');
    controller.debugQuery = 'NTD Televisio';
    expect(ids(controller.visible(items, search: true)), 'c');
    controller.debugQuery = 'ntd television';
    expect(ids(controller.visible(items, search: true)), 'c');
    controller.debugQuery = ' NTD Television ';
    expect(ids(controller.visible(items, search: true)), 'ac');
    // Outside a search the exact name does not matter.
    expect(ids(controller.visible(items)), 'c');
    // Channels the user follows stay in the subscription feed.
    expect(ids(controller.visible(items, subscriptions: true)), 'abc');
    controller.preferences = controller.preferences.copyWith(allowedGroups: ['法轮功']);
    expect(ids(controller.visible(items)), 'abc');
    controller.preferences = controller.preferences.copyWith(allowedGroups: [], blockGroups: false);
    expect(ids(controller.visible(items)), 'abc');
    expect(isExactName('大紀元時報', '大紀元'), isFalse);
  });

  test('propaganda media are matched by channel name, and blocked only when turned on', () {
    expect(isStateMediaChannel('CGTN'), isTrue);
    expect(isStateMediaChannel('CGTN Français'), isTrue);
    expect(isStateMediaChannel('RT Documentary'), isTrue);
    expect(isStateMediaChannel('RTL'), isFalse);
    expect(isStateMediaChannel('央视新闻'), isTrue);
    expect(isStateMediaChannel('BBC News'), isFalse);
    expect(isStateMediaChannel('NHK WORLD-JAPAN'), isFalse);
    expect(isStateMediaChannel('Rick Talks CGTN'), isFalse);
    expect(isStateMediaChannel('VOA News', {'美国政府国际广播'}), isFalse);
    VideoItem video(String id, String channel) => VideoItem(id: id.padRight(11, '0'), title: 'News', channel: channel, url: '');
    final items = [video('a', 'CGTN'), video('b', 'BBC News'), video('c', 'VOA Chinese'), video('d', 'Some Vlog')];
    final controller = AppController();
    String ids(List<VideoItem> list) => list.map((v) => v.id[0]).join();
    expect(ids(controller.visible(items)), 'abcd');
    controller.preferences = controller.preferences.copyWith(blockStateMedia: true);
    // 美国政府国际广播 starts unticked.
    expect(ids(controller.visible(items)), 'bcd');
    controller.debugQuery = 'CGTN';
    expect(ids(controller.visible(items, search: true)), 'abcd');
    controller.preferences = controller.preferences.copyWith(enabledGroups: ['美国政府国际广播']);
    expect(ids(controller.visible(items)), 'bd');
    // One entry can be unticked on its own.
    final cgtn = stateMedia.first.entries().firstWhere((e) => e.label == 'CGTN');
    controller.preferences = controller.preferences.copyWith(allowedEntries: [cgtn.key]);
    expect(ids(controller.visible(items)), 'abd');
    final restored = AppPreferences.fromJson(jsonDecode(jsonEncode(controller.preferences.toJson())));
    expect(restored.blockStateMedia, isTrue);
    expect(restored.enabledGroups, ['美国政府国际广播']);
    expect(restored.allowedEntries, [cgtn.key]);
  });

  test('Falun Gong channels are blocked by name, @handle and id; unproven ones too unless unticked', () {
    final prefs = const AppPreferences();
    expect(prefs.blocksChannel('文昭談古論今 -Wen Zhao Official'), isTrue);
    expect(prefs.blocksChannel('江峰时刻'), isTrue);
    expect(prefs.blocksChannel('Some host', handle: '@WenZhaoOfficial'), isTrue);
    expect(prefs.blocksChannel('', id: 'UCAk-SBMZp79a4k2CAqqoDLQ'), isTrue);
    expect(prefs.blocksChannel('China Uncensored'), isTrue);
    // A title naming a host is not enough; only his channel is.
    expect(prefs.blocksGroup(VideoItem(id: 'x'.padRight(11, '0'), title: '采访文昭谈古论今', channel: 'BBC News 中文', url: '')), isFalse);
    expect(prefs.blocksChannel('石濤聚焦'), isTrue);
    expect(prefs.copyWith(allowedGroups: ['法轮功相关（待核实）']).blocksChannel('石涛聚焦'), isFalse);
    final wenzhao = blockedGroups.firstWhere((g) => g.name == '法轮功相关自媒体').entries().firstWhere((e) => e.label == '文昭谈古论今');
    expect(wenzhao.forms, contains('文昭談古論今'));
    expect(prefs.copyWith(allowedEntries: [wenzhao.key]).blocksChannel('文昭談古論今'), isFalse);
    expect(prefs.copyWith(allowedGroups: ['法轮功相关自媒体']).blocksChannel('江峰时刻'), isFalse);
    expect(prefs.blocksChannel('BBC News 中文'), isFalse);
  });

  test('channels not to recommend stay in searches; typed channels are blocked by id or exact name', () async {
    const ewtn = ChannelRef('UCaaaaaaaaaaaaaaaaaaaaaa', 'EWTN');
    VideoItem video(String id, String channel, [String? channelId]) => VideoItem(id: id.padRight(11, '0'), title: 'Mass', channel: channel, channelId: channelId, url: '');
    final items = [video('a', 'EWTN', ewtn.id), video('b', 'Other', 'UCbbbbbbbbbbbbbbbbbbbbbb'), video('c', 'Some Channel')];
    final controller = AppController();
    String ids(List<VideoItem> list) => list.map((v) => v.id[0]).join();
    controller.setRecommendChannel(ewtn, false);
    expect(ids(controller.visible(items)), 'bc');
    expect(ids(controller.visible(items, search: true)), 'abc');
    expect(ids(controller.visible(items, subscriptions: true)), 'abc');
    controller.setRecommendChannel(ewtn, true);
    expect(controller.preferences.unrecommendedChannels, isEmpty);

    expect(controller.blockChannelTyped('https://www.youtube.com/channel/UCbbbbbbbbbbbbbbbbbbbbbb'), 'UCbbbbbbbbbbbbbbbbbbbbbb');
    expect(controller.blockChannelTyped('  some channel '), 'some channel');
    expect(ids(controller.visible(items, search: true)), 'a');
    controller.unblockChannelName('some channel');
    expect(ids(controller.visible(items)), 'ac');

    final back = AppPreferences.fromJson(jsonDecode(jsonEncode(controller.preferences.copyWith(
      unrecommendedChannels: [ewtn],
      allowedGroups: ['NXIVM'],
      blockedChannelNames: ['X'],
      blockGroups: false,
    ).toJson())));
    expect(back.unrecommendedChannels.single.name, 'EWTN');
    expect(back.allowedGroups, ['NXIVM']);
    expect(back.blockedChannelNames, ['X']);
    expect(back.blockGroups, isFalse);
    expect(const AppPreferences().blockGroups, isTrue);
  });

  test('block lists hide the blocked channel only, never other channels\' videos naming it', () {
    VideoItem video(String title, [String channel = 'Some channel']) => VideoItem(id: 'x'.padRight(11, '0'), title: title, channel: channel, url: '');
    const prefs = AppPreferences();
    // The blocked channel's own videos go; third-party reports stay.
    expect(prefs.blocksGroup(video('今日时事', '江峰时刻')), isTrue);
    expect(prefs.blocksGroup(video('江峰是谁？一个独立调查', 'BBC News 中文')), isFalse);
    expect(prefs.blocksGroup(video('江峰 访谈 文昭谈古论今')), isFalse);
    expect(prefs.blocksGroup(video('Sermon', 'Church of Almighty God')), isTrue);
    expect(prefs.blocksGroup(video('Inside SCIENTOLOGY', 'Journalism Today')), isFalse);
    expect(prefs.blocksGroup(video('Shincheonji in Korea', 'DW Documentary')), isFalse);
    expect(prefs.blocksCommenter('江峰时刻', null), isTrue);
    expect(prefs.blocksCommenter('@WenZhaoOfficial', null), isTrue);
    expect(prefs.blocksCommenter('网友', null), isFalse);
    expect(namesBlockedGroup(video('法輪大法好')), isFalse);
    expect(namesBlockedGroup(video('Sermon', 'Shincheonji')), isTrue);
    expect(namesBlockedGroup(video('Sermon', 'The Epoch Times')), isTrue);
    expect(namesBlockedGroup(video('Sermon', "KAILASA's SPH Nithyananda")), isTrue);
    expect(namesBlockedGroup(video('Sermon', 'Unrelated channel').withChannel(const ChannelRef('UCewpZIBPFGB8S53fZn-W4mg', 'Unrelated channel'))), isTrue);
    expect(namesBlockedGroup(video('KAILASA documentary', 'DW Documentary')), isFalse);
    expect(namesBlockedGroup(video('Almighty God, we pray', 'EWTN')), isFalse);
    expect(namesBlockedGroup(video('Sermon', 'Twin Flames Universe')), isTrue);
    expect(namesBlockedGroup(video('Sermon', 'Unrelated channel').withChannel(const ChannelRef('UC8AqZc9Ij7GGptu3U5Mcj7A', 'Unrelated channel'))), isTrue);
    expect(prefs.copyWith(allowedGroups: ['补充的灵性导师与宗教频道']).blocksChannel('Twin Flames Universe'), isFalse);
    expect(namesBlockedGroup(video('Twin Flames Universe investigation', 'DW Documentary')), isFalse);
    expect(namesBlockedGroup(video('天主教的七件圣事', '梵蒂冈新闻')), isFalse);
  });

  test('arranges zones in the saved order and leaves hidden ones out', () {
    const topics = [ExploreTopic('A', Icons.abc, 'a'), ExploreTopic('B', Icons.abc, 'b'), ExploreTopic('C', Icons.abc, 'c'), ExploreTopic('D', Icons.abc, 'd')];
    expect(arrangeTopics(topics, ['C', 'A'], {'B'}).map((t) => t.label), ['C', 'A', 'D']);
    expect(arrangeTopics(topics, const [], {'A', 'B', 'C', 'D'}).map((t) => t.label), ['A']);
  });

  test('custom zones, order and hidden zones round-trip through the preferences', () {
    const prefs = AppPreferences(
      exploreCustomTopics: [CustomTopic('额我略圣歌', 'Gregorian chant', ExploreSection.popular), CustomTopic('朝拜圣体', 'Eucharistic adoration live', ExploreSection.live)],
      exploreOrder: {'popular': ['宗教信仰', 'custom:额我略圣歌']},
      exploreHidden: {'popular': ['游戏']},
    );
    final back = AppPreferences.fromJson(jsonDecode(jsonEncode(prefs.toJson())));
    expect(back.exploreCustomTopics.map((t) => (t.label, t.query, t.section)), [
      ('额我略圣歌', 'Gregorian chant', ExploreSection.popular),
      ('朝拜圣体', 'Eucharistic adoration live', ExploreSection.live),
    ]);
    expect(back.exploreOrder, {'popular': ['宗教信仰', 'custom:额我略圣歌']});
    expect(back.exploreHidden, {'popular': ['游戏']});
    final live = exploreTopicsOf(ExploreSection.live, back.exploreCustomTopics);
    expect(live.last.label, '朝拜圣体');
    expect(live.last.custom, isTrue);
  });

  test('为你推荐 ranks videos like the history above others', () {
    VideoItem video(String id, String title, String channel, {int? views}) =>
        VideoItem(id: id.padRight(11, '0'), title: title, channel: channel, channelId: 'UC$channel'.padRight(24, '0'), url: '', viewCount: views);
    final taste = TasteProfile.from(history: [
      for (var i = 0; i < 5; i++) video('h$i', 'Catholic Mass Gregorian chant $i', 'chant'),
      video('x', 'Cooking pasta', 'food'),
    ]);
    final liked = AppController.exploreScore(taste, video('a', 'Gregorian chant for prayer', 'chant'));
    final other = AppController.exploreScore(taste, video('b', 'Football highlights', 'sport', views: 10000000));
    expect(liked, greaterThan(other));
  });

  testWidgets('switches halves, zones, sub-categories and modes', (tester) async {
    final controller = await _open(tester);
    // 推荐 comes first: a mix of zones, with 换一批.
    expect(controller.exploreTopicNow.mix, isTrue);
    expect(find.text('换一批'), findsOneWidget);
    await tester.tap(find.text('知识教育'));
    await tester.pump();
    expect(find.text('知识教育 · 本月观看最多'), findsOneWidget);
    expect(find.text('换一批'), findsNothing);

    await tester.tap(find.text('历史'));
    await tester.pump();
    expect(controller.exploreQuery, '历史 纪录片');
    expect(find.text('知识教育 · 历史 · 本月观看最多'), findsOneWidget);

    await tester.tap(find.text('最新'));
    await tester.pump();
    expect(controller.exploreMode, ExploreMode.latest);
    expect(controller.exploreSub, 2);

    await _reveal(tester, '游戏');
    await tester.tap(find.text('游戏'));
    await tester.pump();
    expect(controller.exploreSub, 0);
    await tester.tap(find.text('攻略'));
    await tester.pump();
    expect(controller.exploreQuery, '游戏攻略');
    expect(controller.exploreMode, ExploreMode.latest);

    await tester.tap(find.text('直播').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreSection, ExploreSection.live);
    expect(controller.exploreMode, ExploreMode.liveViewers);
    expect(find.text('推荐直播 · 按观看人数排列'), findsOneWidget);
    expect(find.text('换一批'), findsOneWidget);
    expect(find.text('本月'), findsNothing);

    await _reveal(tester, '电台助眠');
    await tester.tap(find.text('电台助眠'));
    await tester.pump();
    await tester.tap(find.text('Lo-Fi'));
    await tester.pump();
    expect(controller.exploreQuery, 'lofi hip hop radio');
    expect(tester.takeException(), isNull);
  });

  testWidgets('宗教与信仰: tabs, three levels, filters and stream states', (tester) async {
    final controller = await _open(tester);
    await tester.tap(find.text('知识教育'));
    await tester.pump();
    await tester.tap(find.text('数学'));
    await tester.pump();
    await _reveal(tester, '宗教信仰');
    await tester.tap(find.text('宗教信仰'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreSection, ExploreSection.faith);
    expect(controller.exploreMode, ExploreMode.curated);
    expect(controller.exploreTopicNow.label, '基督宗教');
    expect(find.text('宗教学术'), findsOneWidget);

    await tester.tap(find.text('天主教'));
    await tester.pump();
    expect(find.text('全部天主教'), findsOneWidget);
    await tester.tap(find.text('弥撒'));
    await tester.pump();
    expect(controller.exploreQuery, 'Holy Mass 弥撒');
    expect(find.text('基督宗教 · 天主教 · 弥撒 · 相关度高的完整内容，少标题党，每个频道最多 3 个'), findsOneWidget);

    await tester.tap(find.text('类型'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('纪录片').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.exploreQuery, 'Holy Mass 弥撒 documentary 纪录片');

    // Another sub-category starts on all of it.
    await tester.tap(find.text('新教'));
    await tester.pump();
    expect(controller.exploreLeaf, 0);
    expect(find.text('福音派'), findsOneWidget);

    await tester.tap(find.text('宗教学术'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreSection, ExploreSection.faithStudy);
    expect(controller.exploreMode, ExploreMode.curated);
    expect(controller.exploreTopicNow.label, '精选专题');

    await tester.tap(find.text('宗教直播'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreMode, ExploreMode.liveViewers);
    // The 类型 picked for videos applies to live streams too.
    expect(controller.exploreFormat, FaithFormat.documentary);
    await tester.tap(find.text('纪录片').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('不限').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('即将开播'));
    await tester.pump();
    expect(controller.exploreMode, ExploreMode.liveUpcoming);
    expect(controller.exploreQuery, 'Holy Mass live 弥撒 直播');

    // Back to the video zones, on the one shown before.
    await tester.tap(find.text('全部分区'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreSection, ExploreSection.popular);
    expect(controller.exploreMode, ExploreMode.popular);
    expect(controller.exploreTopicNow.label, '知识教育');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every zone has 类型 and 视角, with lists of its own outside 宗教与信仰', (tester) async {
    final controller = await _open(tester);
    await tester.tap(find.text('知识教育'));
    await tester.pump();
    await tester.tap(find.text('类型'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('教程').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.exploreQuery, endsWith('tutorial 教程'));
    await tester.tap(find.text('视角'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('入门科普').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.exploreQuery, endsWith('tutorial 教程 beginner explained 入门'));
    // 直播 keeps them.
    await tester.tap(find.text('直播').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.exploreFormat, ContentFormat.tutorial);
    expect(find.text('教程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window lists the zones down the left', (tester) async {
    final controller = await _open(tester, width: 1280);
    final first = tester.getTopLeft(find.text('推荐').first);
    final second = tester.getTopLeft(find.text('全部').first);
    expect(first.dx, lessThan(TopicStrip.railWidth));
    expect(second.dx, first.dx);
    expect(second.dy, greaterThan(first.dy));
    expect(find.text('管理'), findsOneWidget);
    await tester.tap(find.text('全部').first);
    await tester.pump();
    expect(controller.exploreTopicNow.label, '全部');
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds and removes a custom zone', (tester) async {
    final controller = await _open(tester);
    await _reveal(tester, '添加');
    await tester.tap(find.text('添加'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加分类'), findsOneWidget);
    final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '额我略圣歌');
    await tester.enterText(fields.at(1), 'Gregorian chant');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.preferences.exploreCustomTopics.single.query, 'Gregorian chant');
    expect(controller.exploreTopicNow.label, '额我略圣歌');
    expect(controller.exploreQuery, 'Gregorian chant');

    await _reveal(tester, '额我略圣歌');
    await tester.longPress(find.text('额我略圣歌').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.preferences.exploreCustomTopics, isEmpty);
    expect(controller.exploreTopicNow.label, '推荐');
    expect(tester.takeException(), isNull);
  });

  testWidgets('pins and hides zones from the manage dialog', (tester) async {
    final controller = await _open(tester);
    await _reveal(tester, '管理');
    await tester.tap(find.text('管理'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('管理视频分区'), findsOneWidget);

    // Hide the first zone, then pin 游戏 to the front.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    final faith = find.ancestor(of: find.text('游戏'), matching: find.byType(ListTile));
    await tester.ensureVisible(faith);
    await tester.pump();
    await tester.tap(find.descendant(of: faith, matching: find.byTooltip('置顶')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump(const Duration(milliseconds: 300));

    final topics = controller.exploreTopicsFor(ExploreSection.popular);
    expect(topics.first.label, '游戏');
    expect(topics.map((t) => t.label), isNot(contains('推荐')));
    expect(controller.preferences.exploreHidden['popular'], ['推荐']);
    // The zone shown was hidden, so the strip starts over on its first.
    expect(controller.exploreTopicNow.label, '游戏');
    expect(tester.takeException(), isNull);
  });
}
