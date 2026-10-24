import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/heatmap.dart';
import 'package:lumtub/keep_awake.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/picture_transform.dart';
import 'package:lumtub/progress_line.dart';
import 'package:lumtub/screenshot.dart';
import 'package:lumtub/storyboard.dart';
import 'package:lumtub/ui/player_controls.dart';
import 'package:lumtub/ui/player_shortcuts.dart';
import 'package:lumtub/ui/theater_mode.dart';
import 'package:lumtub/ui/theme.dart';
import 'package:lumtub/widgets/mini_progress_line.dart';
import 'package:lumtub/widgets/video_progress_bar.dart';

import 'player_controls_test.dart' show FakePlayer;

Map<String, dynamic> _board(String id, int width, {double fps = 0.5, List<num> durations = const [50, 50, 20]}) => {
      'format_id': id,
      'format_note': 'storyboard',
      'ext': 'mhtml',
      'width': width,
      'height': width * 9 ~/ 16,
      'rows': 5,
      'columns': 5,
      'fps': fps,
      'fragments': [for (final (i, d) in durations.indexed) {'url': 'https://i.ytimg.com/sb/$id/M$i.jpg', 'duration': d}],
    };

void main() {
  group('storyboard', () {
    test('picks the widest storyboard up to 200 px, else the smallest', () {
      final info = {
        'formats': [
          {'format_id': '18', 'height': 360},
          _board('sb3', 48),
          _board('sb2', 80),
          _board('sb1', 160),
          _board('sb0', 320),
        ],
      };
      expect(Storyboard.from(info)!.width, 160);
      expect(Storyboard.from({'formats': [_board('sb0', 320)]})!.width, 320);
      expect(Storyboard.from({'formats': [{'format_id': '18'}]}), isNull);
      expect(Storyboard.from({}), isNull);
    });

    test('ignores storyboards without usable fragments', () {
      final broken = _board('sb1', 160)..['fragments'] = <Object>[];
      expect(Storyboard.from({'formats': [broken]}), isNull);
    });

    test('finds the tile for a time across sheets, clamping at both ends', () {
      final board = Storyboard.from({'formats': [_board('sb1', 160)]})!;
      expect(board.interval, const Duration(seconds: 2));
      StoryboardTile at(int seconds) => board.tileAt(Duration(seconds: seconds));
      expect((at(0).sheet, at(0).row, at(0).column), (0, 0, 0));
      expect((at(3).sheet, at(3).row, at(3).column), (0, 0, 1));
      expect((at(10).sheet, at(10).row, at(10).column), (0, 1, 0));
      expect((at(49).sheet, at(49).row, at(49).column), (0, 4, 4));
      expect((at(50).sheet, at(50).row, at(50).column), (1, 0, 0));
      // The last sheet covers 20 s, so it holds ten frames.
      expect((at(119).sheet, at(119).row, at(119).column), (2, 1, 4));
      expect((at(5000).sheet, at(5000).row, at(5000).column), (2, 1, 4));
      expect(board.tileAt(const Duration(seconds: -4)).sheet, 0);
    });

    test('works without fps from the first sheet', () {
      final json = _board('sb1', 160)..remove('fps');
      expect(Storyboard.from({'formats': [json]})!.interval, const Duration(seconds: 2));
    });
  });

  group('heatmap', () {
    test('resamples yt-dlp\'s bins over the video', () {
      final heat = Heatmap.from({
        'heatmap': [
          {'start_time': 0.0, 'end_time': 50.0, 'value': 1.0},
          {'start_time': 50.0, 'end_time': 100.0, 'value': 0.25},
        ],
      }, samples: 10)!;
      expect(heat.values, [1, 1, 1, 1, 1, 0.25, 0.25, 0.25, 0.25, 0.25]);
    });

    test('is null when missing or too short to draw', () {
      expect(Heatmap.from({}), isNull);
      expect(Heatmap.from({'heatmap': null}), isNull);
      expect(Heatmap.from({'heatmap': [{'start_time': 0, 'end_time': 5, 'value': 1}]}), isNull);
      expect(Heatmap.from({'heatmap': [{'start_time': 'a'}, 3, {}]}), isNull);
    });

    test('clamps values', () {
      final heat = Heatmap.from({
        'heatmap': [
          {'start_time': 0, 'end_time': 1, 'value': 4},
          {'start_time': 1, 'end_time': 2, 'value': -1},
        ],
      }, samples: 2)!;
      expect(heat.values, [1, 0]);
    });
  });

  group('small helpers', () {
    test('screenshot names are safe and sorted by time', () {
      final name = screenshotName('A/B: "C"? <D>', const Duration(hours: 1, minutes: 2, seconds: 3), DateTime(2026, 3, 4, 5, 6, 7));
      expect(name, 'A B C D_01-02-03_20260304-050607.png');
      expect(screenshotName('', Duration.zero, DateTime(2026)), startsWith('Lumtub_00-00-00_'));
      expect(screenshotName('x' * 100, Duration.zero, DateTime(2026)).split('_').first.length, 40);
    });

    test('screenshots go to Pictures\\Lumtub under the user profile', () {
      final dir = screenshotDirectory({'USERPROFILE': 'C:\\Users\\me'});
      expect(dir.path, endsWith('Pictures${dir.path.contains('/') ? '/' : '\\'}Lumtub'));
      expect(dir.path, startsWith('C:\\Users\\me'));
    });

    test('keep awake holds the display until every holder lets go', () {
      final calls = <int>[];
      KeepAwake.apply = calls.add;
      addTearDown(() => KeepAwake.apply = null);
      final a = Object(), b = Object();
      KeepAwake.hold(a, true);
      KeepAwake.hold(a, true);
      expect(calls, [0x80000002], reason: 'asking twice changes nothing');
      KeepAwake.hold(b, true);
      KeepAwake.hold(a, false);
      expect(calls.last, 0x80000002, reason: 'still held by b');
      KeepAwake.hold(b, false);
      expect(calls.last, 0x80000000, reason: 'released: only ES_CONTINUOUS');
      final count = calls.length;
      KeepAwake.hold(b, false);
      expect(calls.length, count);
    });

    test('mpv zoom is a power of two', () {
      expect(PictureTransform.zoomProperty(1), 0);
      expect(PictureTransform.zoomProperty(2), closeTo(1, 1e-9));
      expect(PictureTransform.zoomProperty(1.5), closeTo(0.585, 0.001));
    });

    test('the new preferences have defaults and survive saving', () {
      const defaults = AppPreferences();
      expect(defaults.showHeatmap, isTrue);
      expect(defaults.progressLine, ProgressLine.always);
      final saved = AppPreferences.fromJson(const AppPreferences(showHeatmap: false, progressLine: ProgressLine.fullscreen).toJson());
      expect(saved.showHeatmap, isFalse);
      expect(saved.progressLine, ProgressLine.fullscreen);
      expect(AppPreferences.fromJson({'progressLine': 'bogus'}).progressLine, ProgressLine.always);
    });

    test('the progress line setting decides where it shows', () {
      expect(ProgressLine.always.shows(fullscreen: false), isTrue);
      expect(ProgressLine.fullscreen.shows(fullscreen: false), isFalse);
      expect(ProgressLine.fullscreen.shows(fullscreen: true), isTrue);
      expect(ProgressLine.never.shows(fullscreen: true), isFalse);
    });
  });

  group('shortcuts', () {
    late AppController controller;
    late FakePlayer player;

    setUp(() {
      controller = AppController();
      player = FakePlayer();
      controller.player = player;
      controller.playing = const VideoItem(id: 'dQw4w9WgXcQ', title: '测试视频标题', channel: '频道', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    });

    test('maps the YouTube keys without clashing with the old ones', () {
      final keys = playerShortcuts(controller, () => null, onScreenshot: () {}).keys.whereType<SingleActivator>().toList();
      final seen = <String>{};
      for (final k in keys) {
        expect(seen.add('${k.trigger.keyId}/${k.shift}/${k.control}/${k.alt}'), isTrue, reason: 'duplicate ${k.trigger.keyLabel}');
      }
      for (final key in [
        LogicalKeyboardKey.comma, LogicalKeyboardKey.period, LogicalKeyboardKey.bracketLeft, LogicalKeyboardKey.bracketRight,
        LogicalKeyboardKey.home, LogicalKeyboardKey.end, LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyS, LogicalKeyboardKey.digit0, LogicalKeyboardKey.digit9, LogicalKeyboardKey.numpad5,
      ]) {
        expect(keys.any((k) => k.trigger == key && !k.shift), isTrue, reason: key.keyLabel);
      }
      // Shift + , and . still change the speed.
      expect(keys.any((k) => k.trigger == LogicalKeyboardKey.period && k.shift), isTrue);
      expect(playerShortcuts(controller, () => null).keys.whereType<SingleActivator>().any((k) => k.trigger == LogicalKeyboardKey.keyS), isFalse, reason: 'no screenshot without a handler');
    });

    test('the help lists the new keys', () {
      final keys = playerShortcutHelp(controller.preferences).map((e) => e.$1).join(' | ');
      for (final k in ['0 - 9', 'Home / End', ', / .', 'T', 'S']) {
        expect(keys, contains(k));
      }
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Colors.red, Brightness.light),
        home: Scaffold(body: ColoredBox(color: Colors.black, child: PlayerControls(player: player, state: null, controller: controller))),
      ));
      await tester.pump();
      await tester.tap(find.byType(PlayerControls), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('number keys jump to tenths, Home and End to the ends', (tester) async {
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.pump();
      expect(player.seeks.last, const Duration(minutes: 5));
      expect(find.text('50%'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad9);
      await tester.pump();
      expect(player.seeks.last, const Duration(minutes: 9));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(player.seeks.last, Duration.zero);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(player.seeks.last, const Duration(minutes: 10));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('T toggles theater mode and the bottom bar has its button', (tester) async {
      addTearDown(() => theaterMode.value = false);
      await pump(tester);
      expect(find.byTooltip('剧场模式 (T)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      expect(theaterMode.value, isTrue);
      expect(find.byTooltip('退出剧场模式 (T)'), findsOneWidget);
      await tester.tap(find.byTooltip('退出剧场模式 (T)'));
      await tester.pump();
      expect(theaterMode.value, isFalse);
    });

    testWidgets('the thin progress line follows the setting', (tester) async {
      await pump(tester);
      expect(find.byType(MiniProgressLine), findsOneWidget, reason: 'always, the default');
      await controller.savePreferences(controller.preferences.copyWith(progressLine: ProgressLine.never));
      await tester.pump();
      expect(find.byType(MiniProgressLine), findsNothing);
      await controller.savePreferences(controller.preferences.copyWith(progressLine: ProgressLine.fullscreen));
      await tester.pump();
      expect(find.byType(MiniProgressLine), findsNothing, reason: 'not fullscreen');
    });
  });

  group('progress bar', () {
    Future<void> pumpBar(WidgetTester tester, {List<double>? heatmap, ProgressPreview? preview}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: VideoProgressBar(
                position: const Duration(seconds: 10),
                buffered: const Duration(seconds: 20),
                total: const Duration(seconds: 100),
                color: Colors.red,
                heatmap: heatmap,
                preview: preview,
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      ));
    }

    testWidgets('draws the replay curve and the preview with the time while hovering', (tester) async {
      Duration? previewed;
      await pumpBar(tester, heatmap: [for (var i = 0; i < 20; i++) i / 19], preview: ProgressPreview(const Size(160, 90), (time) {
        previewed = time;
        return const ColoredBox(color: Colors.blue, key: Key('tile'));
      }));
      expect(find.byKey(const Key('tile')), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final bar = tester.getRect(find.byType(VideoProgressBar));
      await mouse.moveTo(Offset(bar.left + bar.width / 4, bar.center.dy));
      await tester.pump();
      expect(find.byKey(const Key('tile')), findsOneWidget);
      expect(previewed!.inSeconds, closeTo(25, 1));
      expect(find.text('00:25'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('works without either', (tester) async {
      await pumpBar(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
