import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/appearance_settings.dart';
import 'package:lumtub/explore_topics.dart';
import 'package:lumtub/faith_topics.dart';
import 'package:lumtub/l10n/l10n.dart';
import 'package:lumtub/l10n/strings_en.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/pages/explore_page.dart';
import 'package:lumtub/ui/pages/settings_page.dart';
import 'package:lumtub/ui/pages/settings_sections.dart';
import 'package:lumtub/ui/theme.dart';

/// The first argument of every tr('…') call in lib/, as the running app
/// passes it.
Set<String> _sourceKeys() {
  final call = RegExp(r"\btr\('((?:[^'\\]|\\.)*)'");
  String decode(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m[1]) { 'n' => '\n', 't' => '\t', _ => m[1]! });
  return {
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
      for (final m in call.allMatches(file.readAsStringSync())) decode(m[1]!),
  };
}

void main() {
  tearDown(() => setLanguage(AppLanguage.zhHans));

  test('every translatable string has English text with the same placeholders', () {
    final keys = _sourceKeys();
    expect(keys.length, greaterThan(900));
    final missing = keys.where((k) => !stringsEn.containsKey(k)).toList();
    expect(missing, isEmpty, reason: 'add these to lib/l10n/strings_en.dart');
    final placeholder = RegExp(r'\{\d+\}');
    for (final MapEntry(:key, :value) in stringsEn.entries) {
      expect(placeholder.allMatches(value).map((m) => m[0]).toSet(), placeholder.allMatches(key).map((m) => m[0]).toSet(), reason: key);
    }
  });

  test('translates with placeholders and falls back to the source text', () {
    setLanguage(AppLanguage.en);
    expect(tr('冷门宝藏'), 'Hidden gems');
    expect(tr('还没有翻译的文字'), '还没有翻译的文字');
    expect(ExploreMode.gems.label, 'Hidden gems');
    expect(formatCount(1234567), '1.2M');
    setLanguage(AppLanguage.zhHant);
    expect(tr('冷门宝藏'), '冷門寶藏');
    expect(formatCount(1234567), '123萬');
    setLanguage(AppLanguage.zhHans);
    expect(tr('冷门宝藏'), '冷门宝藏');
    expect(formatCount(1234567), '123万');
  });

  test('custom zones keep their own names and keys in every language', () {
    setLanguage(AppLanguage.en);
    const custom = CustomTopic('额我略圣歌', 'Gregorian chant', ExploreSection.popular);
    expect(custom.topic.label, '额我略圣歌');
    final faith = faithTraditionTopics.first;
    expect(faith.key, '基督宗教');
    expect(faith.label, 'Christianity');
  });

  testWidgets('the explore page lays out in English', (tester) async {
    setLanguage(AppLanguage.en);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController()..ready = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ExplorePage(controller: controller),
    ))));
    await tester.pump();
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Popular'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(popularTopics.singleWhere((t) => t.opens != null).label, 'Religion & faith');
    controller.setExplore(section: ExploreSection.faith);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Catholic'));
    await tester.pump();
    expect(find.text('All Catholic'), findsOneWidget);
    expect(find.text('Selected'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Live').last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Upcoming'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every settings group lays out in English', (tester) async {
    setLanguage(AppLanguage.en);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController();
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Scaffold(body: SettingsPage(controller: controller)),
    ));
    await tester.pump();
    expect(find.text('Language'), findsNothing);
    for (final category in SettingsCategory.values) {
      await tester.tap(find.text(category.title).first);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: category.title);
    }
    await tester.tap(find.text(SettingsCategory.style.title).first);
    await tester.pump();
    expect(find.text('Language'), findsNothing);
  });

  test('the interface is English whatever was saved or the system uses', () {
    for (final saved in ['zhHans', 'zhHant', 'system', 'en', null, 'nonsense']) {
      expect(AppLanguage.parse(saved), AppLanguage.en, reason: '$saved');
    }
    expect(AppLanguage.system.resolved, AppLanguage.en);
    expect(AppLanguage.selectable, [AppLanguage.en]);
    expect(const AppearanceSettings().language, AppLanguage.en);
    expect(AppearanceSettings.fromJson({'language': 'zhHant'}).language, AppLanguage.en);
  });
}
