import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/main.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/mini_player.dart';
import 'package:lumtub/ui/theme.dart';

import 'player_controls_test.dart' show FakePlayer;

const _video = VideoItem(id: 'dQw4w9WgXcQ', title: '测试视频标题', channel: '频道', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');

void main() {
  late AppController controller;
  late FakePlayer player;

  setUp(() async {
    controller = AppController();
    player = FakePlayer();
    controller.player = player;
    controller.playing = _video;
    await player.playOrPause();
  });

  group('leaving the watch page', () {
    test('keeps the video playing in the mini player', () {
      controller.navigate(PageMode.history);
      expect(controller.mini, isTrue);
      expect(controller.playing, _video);
      expect(controller.onWatchPage, isFalse);
      expect(controller.mode, PageMode.history);
      expect(player.state.playing, isTrue);
    });

    test('stops it when the setting is off', () {
      controller.preferences = controller.preferences.copyWith(miniPlayer: false);
      controller.navigate(PageMode.history);
      expect(controller.mini, isFalse);
      expect(controller.playing, isNull);
      expect(player.state.playing, isFalse);
    });

    test('stops it after a playback error', () {
      controller.playbackError = 'boom';
      controller.navigate(PageMode.history);
      expect(controller.mini, isFalse);
      expect(controller.playing, isNull);
    });

    test('back with nothing earlier leaves for the page under the video', () {
      controller.goBack();
      expect(controller.mini, isTrue);
      expect(controller.playing, _video);
      expect(controller.mode, PageMode.home);
      // The mini player is not a page: back has nowhere to go.
      expect(controller.canGoBack, isFalse);
    });

    test('moving between pages keeps the mini player', () {
      controller.navigate(PageMode.history);
      controller.navigate(PageMode.subscriptions);
      expect(controller.mini, isTrue);
      expect(controller.playing, _video);
      expect(player.state.playing, isTrue);
    });

    test('the 应用内小窗 button leaves the page it was opened from', () {
      controller.mode = PageMode.subscriptions;
      controller.enterMini();
      expect(controller.mini, isTrue);
      expect(controller.mode, PageMode.subscriptions);
      expect(player.state.playing, isTrue);
    });

    test('there is nothing to put in the mini player without a video', () {
      controller.playing = null;
      controller.enterMini();
      expect(controller.mini, isFalse);
    });
  });

  group('from the mini player', () {
    setUp(() => controller.enterMini());

    test('expanding shows the watch page again, where it was', () async {
      await player.seek(const Duration(minutes: 3));
      controller.expandMini();
      expect(controller.mini, isFalse);
      expect(controller.onWatchPage, isTrue);
      expect(player.state.position, const Duration(minutes: 3));
      expect(player.state.playing, isTrue);
    });

    test('opening the same video expands instead of reloading it', () async {
      await controller.play(_video);
      expect(controller.onWatchPage, isTrue);
      expect(player.seeks, isEmpty);
    });

    test('closing stops playback', () {
      controller.stopWatching();
      expect(controller.mini, isFalse);
      expect(controller.playing, isNull);
      expect(player.state.playing, isFalse);
    });

    test('going back to the same video expands it', () {
      controller.ready = true;
      controller.expandMini();
      controller.navigate(PageMode.history);
      expect(controller.mini, isTrue);
      controller.goBack();
      expect(controller.onWatchPage, isTrue);
      expect(controller.playing, _video);
    });
  });

  test('picture in picture leaves the mini player as it was', () {
    controller.enterMini();
    controller.setPip(false);
    expect(controller.mini, isTrue);
    expect(controller.playing, _video);
  });

  test('the setting is on by default and is saved', () {
    expect(const AppPreferences().miniPlayer, isTrue);
    final off = AppPreferences.fromJson(const AppPreferences(miniPlayer: false).toJson());
    expect(off.miniPlayer, isFalse);
    expect(AppPreferences.fromJson(<String, dynamic>{}).miniPlayer, isTrue);
  });

  group('the card', () {
    const pictureKey = Key('picture');

    Widget card({bool theme = true}) => MaterialApp(
          theme: theme ? buildAppTheme(Colors.red, Brightness.light) : null,
          home: Scaffold(
            body: Stack(children: [
              Positioned.fill(child: MiniPlayer(controller: controller, videoBuilder: (context) => const ColoredBox(key: pictureKey, color: Colors.black))),
            ]),
          ),
        );

    Future<void> pumpCard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.mini = true;
      await tester.pumpWidget(card());
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> dragCard(WidgetTester tester, Offset by) async {
      await tester.dragFrom(tester.getCenter(find.byKey(pictureKey)) + const Offset(0, 40), by);
    }

    Future<void> hover(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byKey(pictureKey)));
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('sits at the bottom right, 320 wide in the video\'s ratio', (tester) async {
      await pumpCard(tester);
      final rect = tester.getRect(find.byKey(pictureKey));
      expect(rect.width, 320);
      expect(rect.height, closeTo(180, 0.5));
      expect(rect.right, 960 - MiniPlayer.margin);
      expect(rect.bottom, 540 - MiniPlayer.margin);
    });

    testWidgets('follows a tall video\'s ratio', (tester) async {
      player.state = player.state.copyWith(width: 720, height: 1280);
      await pumpCard(tester);
      final rect = tester.getRect(find.byKey(pictureKey));
      expect(rect.width / rect.height, closeTo(9 / 16, 0.01));
      expect(rect.height, lessThanOrEqualTo(540 - 2 * MiniPlayer.margin));
    });

    testWidgets('does not mount the video until the watch page has gone', (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(card(theme: false));
      expect(find.byKey(pictureKey), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(pictureKey), findsOneWidget);
    });

    testWidgets('dragging snaps to the nearest corner', (tester) async {
      await pumpCard(tester);
      await dragCard(tester, const Offset(-700, -330));
      await tester.pumpAndSettle();
      var rect = tester.getRect(find.byKey(pictureKey));
      expect(rect.topLeft, const Offset(MiniPlayer.margin, MiniPlayer.margin));

      // A short drag stays in the same corner.
      await dragCard(tester, const Offset(150, 20));
      await tester.pumpAndSettle();
      rect = tester.getRect(find.byKey(pictureKey));
      expect(rect.topLeft, const Offset(MiniPlayer.margin, MiniPlayer.margin));

      await dragCard(tester, const Offset(600, 100));
      await tester.pumpAndSettle();
      rect = tester.getRect(find.byKey(pictureKey));
      expect(rect.topRight, const Offset(960 - MiniPlayer.margin, MiniPlayer.margin));
      expect(controller.mini, isTrue);
    });

    testWidgets('hovering shows play/pause, expand and close', (tester) async {
      await pumpCard(tester);
      await hover(tester);
      expect(find.byTooltip('展开到播放页'), findsOneWidget);
      expect(find.byTooltip('关闭小窗并停止播放'), findsOneWidget);

      expect(player.state.playing, isTrue);
      await tester.tap(find.byIcon(Icons.pause_circle_rounded));
      await tester.pump();
      expect(player.state.playing, isFalse);
      expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget);
    });

    testWidgets('expand goes back to the watch page', (tester) async {
      await pumpCard(tester);
      await hover(tester);
      await tester.tap(find.byTooltip('展开到播放页'));
      await tester.pump();
      expect(controller.mini, isFalse);
      expect(controller.onWatchPage, isTrue);
      expect(player.state.playing, isTrue);
    });

    testWidgets('close stops the video', (tester) async {
      await pumpCard(tester);
      await hover(tester);
      await tester.tap(find.byTooltip('关闭小窗并停止播放'));
      await tester.pump();
      expect(controller.mini, isFalse);
      expect(controller.playing, isNull);
      expect(player.state.playing, isFalse);
    });

    testWidgets('a double tap expands', (tester) async {
      await pumpCard(tester);
      final spot = tester.getTopLeft(find.byKey(pictureKey)) + const Offset(100, 90);
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.mini, isFalse);
    });
  });

  test('corners and sizes', () {
    const area = Size(1000, 600);
    const size = Size(320, 180);
    expect(miniPosition(MiniCorner.bottomRight, area, size), const Offset(668, 408));
    expect(miniPosition(MiniCorner.topLeft, area, size), const Offset(12, 12));
    expect(nearestMiniCorner(const Offset(100, 400), area, size), MiniCorner.bottomLeft);
    expect(nearestMiniCorner(const Offset(600, 10), area, size), MiniCorner.topRight);
    expect(miniSize(16 / 9, const Size(300, 600)).width, 276);
    expect(miniSize(16 / 9, const Size(1000, 100)).height, 76);
  });

  testWidgets('the shell shows the card only while the mini player is on', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(LumtubApp(controller: controller));
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);

    controller.enterMini();
    await tester.pump();
    expect(find.byType(MiniPlayer), findsOneWidget);

    controller.stopWatching();
    await tester.pump();
    expect(find.byType(MiniPlayer), findsNothing);
    expect(tester.takeException(), isNull);
    controller.player = null;
  });
}
