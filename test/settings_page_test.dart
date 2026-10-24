import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/pages/settings_page.dart';
import 'package:lumtub/ui/pages/settings_sections.dart';
import 'package:lumtub/ui/pages/settings_subpages.dart';
import 'package:lumtub/ui/theme.dart';

void main() {
  late AppController controller;
  setUp(() => controller = AppController());

  Future<void> pump(WidgetTester tester, {double width = 1280}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Scaffold(body: SettingsPage(controller: controller)),
    ));
    await tester.pump();
  }

  testWidgets('wide windows show the groups beside the chosen group', (tester) async {
    await pump(tester);
    for (final category in SettingsCategory.values) {
      expect(find.text(category.title), findsOneWidget);
    }
    await tester.tap(find.text(SettingsCategory.video.title));
    await tester.pump();
    expect(find.text('默认画质'), findsOneWidget);
    expect(find.text('开启硬解'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow windows open a group on its own page', (tester) async {
    await pump(tester, width: 600);
    expect(find.text('默认画质'), findsNothing);
    await tester.tap(find.text(SettingsCategory.play.title));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, SettingsCategory.play.title), findsOneWidget);
    expect(find.text('自动连播'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search finds rows across groups', (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField).first, '硬解');
    await tester.pump();
    expect(find.text('开启硬解'), findsOneWidget);
    expect(find.text('硬解模式'), findsOneWidget);
    expect(find.text('自动连播'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '没有这种设置');
    await tester.pump();
    expect(find.text('没有找到相关设置'), findsOneWidget);
  });

  testWidgets('the theme mode menu changes the theme mode', (tester) async {
    await pump(tester);
    await tester.tap(find.text(SettingsCategory.style.title));
    await tester.pump();
    await tester.tap(find.text('主题模式'));
    await tester.pumpAndSettle();
    // The menu item's text sits under its ink; the tap still lands on the item.
    await tester.tap(find.text('深色'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(controller.appearance.themeMode, ThemeMode.dark);
  });

  Future<void> openRow(WidgetTester tester, SettingsCategory category, String row) async {
    await tester.tap(find.text(category.title));
    await tester.pump();
    await tester.scrollUntilVisible(find.text(row), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text(row));
    await tester.pumpAndSettle();
  }

  testWidgets('sub-pages open from their rows', (tester) async {
    await pump(tester);
    for (final (category, row, title, content) in [
      (SettingsCategory.play, '倍速设置', '倍速设置', '倍速列表'),
      (SettingsCategory.play, '字幕设置', '字幕设置', '首选字幕语言'),
      (SettingsCategory.style, '应用主题', '选择应用主题', '调色板风格'),
      (SettingsCategory.style, 'App 字体设置', 'App 字体设置', '微软雅黑'),
      (SettingsCategory.extra, '组件管理', '组件管理', '正在准备组件…'),
      (SettingsCategory.about, '错误日志', '日志', '暂无日志'),
    ]) {
      await openRow(tester, category, row);
      expect(find.widgetWithText(AppBar, title), findsOneWidget, reason: row);
      expect(find.text(content), findsWidgets, reason: row);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('the SponsorBlock row opens its categories and keeps its switch', (tester) async {
    await pump(tester);
    await openRow(tester, SettingsCategory.extra, '空降助手');
    expect(find.text('跳过的片段类型'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(8));
  });

  testWidgets('blocked channels can be removed', (tester) async {
    await controller.savePreferences(controller.preferences.copyWith(blockedChannels: const [ChannelRef('UC0123456789abcdefghijkl', '测试频道')]));
    await pump(tester);
    await openRow(tester, SettingsCategory.privacy, '屏蔽频道');
    expect(find.text('测试频道'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(controller.preferences.blockedChannels, isEmpty);
    expect(find.textContaining('还没有屏蔽任何频道'), findsOneWidget);
  });

  testWidgets('account and about sit at the bottom without a subtitle', (tester) async {
    await pump(tester);
    expect(find.text(SettingsCategory.video.subtitle), findsOneWidget);
    expect(find.text(SettingsCategory.about.subtitle), findsNothing);
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('block lists open to their entries, each tickable', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () => openBlockedGroups(context, controller), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('法轮功相关（待核实）'), findsOneWidget);
    await tester.tap(find.text('法轮功相关自媒体'));
    await tester.pumpAndSettle();
    expect(find.textContaining('频道名 · '), findsOneWidget);
    await tester.tap(find.widgetWithText(CheckboxListTile, '文昭谈古论今'));
    await tester.pump();
    expect(controller.preferences.allowedEntries.single, endsWith('/channel/文昭谈古论今'));
    expect(controller.preferences.blocksChannel('文昭談古論今'), isFalse);
    expect(controller.preferences.blocksChannel('江峰时刻'), isTrue);
    await tester.tap(find.text('全不选'));
    await tester.pump();
    expect(controller.preferences.blocksChannel('江峰时刻'), isFalse);
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(controller.preferences.allowedEntries, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
