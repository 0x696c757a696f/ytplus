import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app/library_controller.dart';
import 'package:lumtub/app_directories.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/library_store.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/play_queue.dart';
import 'package:lumtub/ui/pages/history_page.dart';
import 'package:lumtub/ui/pages/library_pages.dart';
import 'package:lumtub/ui/play_queue_panel.dart';
import 'package:lumtub/ui/theme.dart';
import 'package:lumtub/ui/video_card.dart';
import 'package:lumtub/video_repository.dart';

void main() {
  final videos = [
    for (var i = 0; i < 5; i++)
      VideoItem(id: 'video${i}xxxxx', title: i == 3 ? 'Flutter 教程' : '视频 $i', channel: i == 3 ? '开发者频道' : 'Rick Astley', url: 'https://www.youtube.com/watch?v=video${i}xxxxx', duration: 200),
  ];

  late Directory dir;
  late LibraryStore store;
  late LibraryController library;
  late AppController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lumtub_later');
    addTearDown(() => dir.deleteSync(recursive: true));
    store = LibraryStore(File('${dir.path}/library.json'));
    library = LibraryController(store);
    controller = AppController()..library = library;
  });

  group('watch later store', () {
    test('toggles, removes, clears and survives a restart', () async {
      expect(library.toggleWatchLater(videos[0]), isTrue);
      expect(library.toggleWatchLater(videos[1]), isTrue);
      // Newest first.
      expect(library.watchLater.map((v) => v.id), [videos[1].id, videos[0].id]);
      expect(library.isWatchLater(videos[0].id), isTrue);
      await library.flush();
      final reloaded = LibraryStore(store.file);
      await reloaded.load();
      expect(reloaded.watchLater.map((v) => v.id), [videos[1].id, videos[0].id]);

      library.removeWatchLater(videos[1].id);
      expect(library.watchLater.map((v) => v.id), [videos[0].id]);
      expect(library.toggleWatchLater(videos[0]), isFalse);
      library.toggleWatchLater(videos[2]);
      library.clearWatchLater();
      expect(library.watchLater, isEmpty);
      await library.flush();
    });

    test('a finished video leaves the list unless the setting is off', () async {
      controller.playing = videos[0];
      library.toggleWatchLater(videos[0]);
      library.toggleWatchLater(videos[1]);
      await controller.playAfterEndForTest();
      expect(library.isWatchLater(videos[0].id), isFalse);
      expect(library.isWatchLater(videos[1].id), isTrue);

      controller.preferences = controller.preferences.copyWith(watchLaterAutoRemove: false);
      controller.playing = videos[1];
      await controller.playAfterEndForTest();
      expect(library.isWatchLater(videos[1].id), isTrue);
      await library.flush();
    });

    test('the setting defaults to on and is saved', () {
      expect(const AppPreferences().watchLaterAutoRemove, isTrue);
      final json = const AppPreferences().copyWith(watchLaterAutoRemove: false).toJson();
      expect(AppPreferences.fromJson(json).watchLaterAutoRemove, isFalse);
    });
  });

  group('play queue', () {
    test('orders next, last and reorder; no duplicates', () {
      final queue = PlayQueue();
      expect(queue.addLast(videos[0]), isTrue);
      expect(queue.addLast(videos[0]), isFalse);
      queue.addLast(videos[1]);
      queue.addNext(videos[2]);
      expect(queue.items.map((v) => v.id), [videos[2].id, videos[0].id, videos[1].id]);
      queue.addNext(videos[1]);
      expect(queue.items.map((v) => v.id), [videos[1].id, videos[2].id, videos[0].id]);
      queue.move(0, 2);
      expect(queue.items.map((v) => v.id), [videos[2].id, videos[0].id, videos[1].id]);
      queue.remove(videos[0].id);
      expect(queue.takeNext()!.id, videos[2].id);
      expect(queue.takeNext()!.id, videos[1].id);
      expect(queue.takeNext(), isNull);
    });

    test('the controller queues, counts as next, and playing one takes it off', () async {
      controller.playing = videos[0];
      controller.queue = videos.take(3).toList();
      expect(controller.hasNext, isTrue);
      expect(controller.stopsAfterEnd, isFalse);
      controller.queueLast(videos[4]);
      controller.queueNext(videos[3]);
      expect(controller.playQueue.items.map((v) => v.id), [videos[3].id, videos[4].id]);
      controller.moveQueued(0, 1);
      expect(controller.playQueue.items.first.id, videos[4].id);
      // No player here, so play() returns at once; the queue still advances.
      await controller.playAfterEndForTest();
      expect(controller.playQueue.items.map((v) => v.id), [videos[3].id]);
      expect(await controller.playQueued(), isTrue);
      expect(controller.playQueue.isEmpty, isTrue);
      expect(await controller.playQueued(), isFalse);
      controller.queueLast(videos[1]);
      controller.clearQueue();
      expect(controller.playQueue.isEmpty, isTrue);
    });
  });

  group('history store', () {
    test('removes some ids and keeps the rest on disk', () async {
      Directory sub(String name) => Directory('${dir.path}/$name')..createSync();
      final history = HistoryStore(AppDirectories(root: dir, config: sub('c'), data: sub('d'), cache: sub('k'), components: sub('p'), logs: sub('l')));
      await history.initialize();
      for (final video in videos) {
        await history.record(video);
      }
      await history.remove({videos[1].id, videos[2].id});
      expect(history.items.map((v) => v.id), [videos[4].id, videos[3].id, videos[0].id]);
      final again = HistoryStore(history.directories);
      await again.initialize();
      expect(again.items.map((v) => v.id), [videos[4].id, videos[3].id, videos[0].id]);
    });
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Scaffold(body: VideoActions(controller: controller, child: page)),
    ));
    await tester.pump();
  }

  testWidgets('the watch later page lists, plays and clears', (tester) async {
    controller.openPlaylistId = AppController.watchLaterPlaylistId;
    await pump(tester, PlaylistDetailPage(controller: controller));
    expect(find.text('稍后观看是空的'), findsOneWidget);

    library.toggleWatchLater(videos[0]);
    library.toggleWatchLater(videos[1]);
    await pump(tester, PlaylistDetailPage(controller: controller));
    expect(find.text('稍后观看'), findsOneWidget);
    expect(find.text('视频 0'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(library.watchLater, isEmpty);
    unawaited(library.flush());
  });

  testWidgets('the library page has a watch later entry', (tester) async {
    library.toggleWatchLater(videos[0]);
    await pump(tester, PlaylistsPage(controller: controller));
    expect(find.text('稍后观看'), findsOneWidget);
    unawaited(library.flush());
  });

  testWidgets('the queue panel shows the queue and removes and clears', (tester) async {
    controller.queueLast(videos[0]);
    controller.queueLast(videos[1]);
    await pump(tester, SingleChildScrollView(child: PlayQueuePanel(controller: controller)));
    expect(find.text('播放队列'), findsOneWidget);
    expect(find.text('视频 0'), findsOneWidget);
    expect(find.text('视频 1'), findsOneWidget);
    await tester.tap(find.byTooltip('从队列移除').first);
    expect(controller.playQueue.items.map((v) => v.id), [videos[1].id]);
    await tester.tap(find.text('清空'));
    expect(controller.playQueue.isEmpty, isTrue);
  });

  group('history page', () {
    late HistoryStore history;

    setUp(() async {
      Directory sub(String name) => Directory('${dir.path}/$name')..createSync();
      history = HistoryStore(AppDirectories(root: dir, config: sub('c'), data: sub('d'), cache: sub('k'), components: sub('p'), logs: sub('l')));
      await history.initialize();
      for (final video in videos) {
        await history.record(video);
      }
      controller.historyStore = history;
    });

    test('filters by title or channel, ignoring case', () {
      expect(filterHistory(videos, 'flutter').map((v) => v.id), [videos[3].id]);
      expect(filterHistory(videos, '开发者').map((v) => v.id), [videos[3].id]);
      expect(filterHistory(videos, 'rick').length, 4);
      expect(filterHistory(videos, '  ').length, 5);
    });

    testWidgets('searches, then selects several and deletes them', (tester) async {
      await pump(tester, HistoryPage(controller: controller));
      expect(find.byType(VideoCard), findsNWidgets(5));
      await tester.enterText(find.byType(TextField), 'flutter');
      await tester.pump();
      expect(find.byType(VideoCard), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'nothing like this');
      await tester.pump();
      expect(find.text('没有匹配的历史记录'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();

      await tester.tap(find.text('选择'));
      await tester.pump();
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 5 个'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.text('已选 4 个'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('删除所选'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(controller.history.length, 1);
      expect(controller.history.single.id, videos.last.id);
    });
  });
}
