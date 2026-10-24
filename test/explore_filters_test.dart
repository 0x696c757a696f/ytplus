import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/explore_filters.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/video_repository.dart';
import 'package:lumtub/youtube_related.dart';

void main() {
  test('tells a title\'s language from its script and small words', () {
    expect(titleLanguage('【4K】東京の夜景を歩く'), ExploreLanguage.ja);
    expect(titleLanguage('서울 맛집 투어'), ExploreLanguage.ko);
    expect(titleLanguage('中国历史纪录片 第一集'), ExploreLanguage.zh);
    expect(titleLanguage('How to build a PC in 2026'), ExploreLanguage.en);
    expect(titleLanguage('Cómo hacer pan en casa con una receta fácil'), ExploreLanguage.es);
    expect(titleLanguage("Les secrets de la cuisine française, c'est simple"), ExploreLanguage.fr);
    expect(titleLanguage('Die besten Tipps für den Garten und mehr'), ExploreLanguage.de);
    expect(titleLanguage('Como fazer uma receita fácil, não é difícil'), ExploreLanguage.pt);
    expect(titleLanguage('Новости дня'), ExploreLanguage.ru);
    expect(titleLanguage('Hướng dẫn nấu phở'), ExploreLanguage.vi);
    expect(titleLanguage('ข่าววันนี้'), ExploreLanguage.th);
    expect(titleLanguage('1234 !!!'), ExploreLanguage.any);
    expect(ExploreLanguage.any.matches('anything'), isTrue);
    expect(ExploreLanguage.zh.matches('How to cook'), isFalse);
  });

  test('a region search carries only a PREF cookie with the country', () {
    final cookies = VideoRepository.regionCookies('jp');
    expect(cookies, startsWith('# Netscape HTTP Cookie File\n'));
    expect(cookies.trim().split('\n').last.split('\t'), ['.youtube.com', 'TRUE', '/', 'TRUE', '2147483647', 'PREF', 'gl=JP&hl=en']);
    final repository = VideoRepository('yt-dlp');
    expect(repository.listingArguments('u', cookies: 'c.txt'), containsAllInOrder(['--cookies', 'c.txt']));
    expect(repository.listingArguments('u'), isNot(contains('--cookies')));
  });

  test('a mix takes a few lines of each search in turn and skips failed ones', () async {
    Stream<String> lines(String name, int count) => Stream.fromIterable([for (var i = 0; i < count; i++) '$name$i']);
    Stream<String> failing() => Stream.error(StateError('no'));
    final mixed = await VideoRepository.interleave([() => lines('a', 4), failing, () => lines('b', 2), () => lines('c', 5)], run: 2).toList();
    expect(mixed, ['a0', 'a1', 'b0', 'b1', 'c0', 'c1', 'a2', 'a3', 'c2', 'c3', 'c4']);
    expect(VideoRepository.interleave([failing]).toList(), throwsStateError);
  });

  test('details take the translated title, description and chapter names', () {
    final details = VideoDetails(
      title: 'Original',
      channel: 'c',
      description: '0:00 Intro\n1:30 Main part',
      chapters: const [Chapter(Duration.zero, Duration(seconds: 90), 'Intro'), Chapter(Duration(seconds: 90), Duration.zero, 'Main part')],
    );
    final local = details.localized('翻译标题', '0:00 开场\n01:30 - 正片\n结尾');
    expect(local.title, '翻译标题');
    expect(local.description, startsWith('0:00 开场'));
    expect(local.chapters.map((c) => c.title), ['开场', '正片']);
    expect(identical(details.localized('', ''), details), isTrue);
    final text = YoutubeRelated.localized({
      'contents': [
        {'videoPrimaryInfoRenderer': {'title': {'runs': [{'text': '你好'}, {'text': '世界'}]}}},
        {'videoSecondaryInfoRenderer': {'attributedDescription': {'content': '说明'}}},
      ],
      'frameworkUpdates': {'entityBatchUpdate': {'mutations': [
        {'payload': {'likeCountEntity': {'likeCountIfIndifferentNumber': '1234567', 'likeCountIfLiked': {'content': '1.2M'}}}},
      ]}},
    });
    expect(text?.title, '你好世界');
    expect(text?.description, '说明');
    expect(text?.likes, 1234567);
    expect(details.localized(details.title, details.description, likes: 5).likeCount, 5);
  });

  test('subtitles follow Windows\' language unless another is chosen', () {
    expect(const PlayerSettings().subtitleLanguage, SubtitleLanguage.auto);
    final saved = SubtitleLanguage.systemLocale;
    addTearDown(() => SubtitleLanguage.systemLocale = saved);
    var locale = const Locale('zh', 'CN');
    SubtitleLanguage.systemLocale = () => locale;
    expect(SubtitleLanguage.auto.mpvLangs, SubtitleLanguage.zh.mpvLangs);
    locale = const Locale('zh', 'TW');
    expect(SubtitleLanguage.auto.resolved, SubtitleLanguage.zhHant);
    locale = const Locale('de', 'DE');
    expect(SubtitleLanguage.auto.resolved, SubtitleLanguage.en);
    // 简体中文优先, the old default, now follows; a choice saved since stays.
    expect(PlayerSettings.fromJson({'subtitleLanguage': 'zh'}).subtitleLanguage, SubtitleLanguage.auto);
    expect(PlayerSettings.fromJson({'subtitleLanguage': 'ja'}).subtitleLanguage, SubtitleLanguage.ja);
    final chosen = PlayerSettings.fromJson(jsonDecode(jsonEncode(const PlayerSettings(subtitleLanguage: SubtitleLanguage.zh).toJson())));
    expect(chosen.subtitleLanguage, SubtitleLanguage.zh);
  });

  test('explore region and language round-trip through the preferences', () {
    final saved = const AppPreferences().copyWith(exploreRegion: ExploreRegion.jp, exploreLanguage: ExploreLanguage.ja);
    final restored = AppPreferences.fromJson(jsonDecode(jsonEncode(saved.toJson())));
    expect(restored.exploreRegion, ExploreRegion.jp);
    expect(restored.exploreLanguage, ExploreLanguage.ja);
    expect(AppPreferences.fromJson(<String, Object?>{}).exploreRegion, ExploreRegion.any);
  });
}
