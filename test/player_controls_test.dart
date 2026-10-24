import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/pip_view.dart';
import 'package:lumtub/ui/player_controls.dart';
import 'package:lumtub/ui/theme.dart';
import 'package:lumtub/widgets/video_progress_bar.dart';

/// A player without libmpv: state changes are pushed through the streams
/// the controls listen to.
class FakePlayer implements Player {
  FakePlayer() {
    stream = PlayerStream(
      const Stream.empty(),
      _playing.stream,
      _completed.stream,
      _position.stream,
      const Stream.empty(),
      _volume.stream,
      _rate.stream,
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
      const Stream.empty(),
    );
  }

  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _rate = StreamController<double>.broadcast();

  @override
  PlayerState state = const PlayerState(duration: Duration(minutes: 10), position: Duration(minutes: 1), height: 1080, width: 1920);

  @override
  late final PlayerStream stream;

  final seeks = <Duration>[];

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    _playing.add(state.playing);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    _playing.add(false);
  }

  /// Unloads the video, as libmpv's stop does.
  @override
  Future<void> stop({bool open = false}) async {
    state = state.copyWith(playing: false);
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    state = state.copyWith(position: duration);
    _position.add(duration);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    _rate.add(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    _volume.add(volume);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppController controller;
  late FakePlayer player;

  setUp(() {
    controller = AppController();
    player = FakePlayer();
    controller.player = player;
    controller.playing = const VideoItem(id: 'dQw4w9WgXcQ', title: '测试视频标题', channel: '频道', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
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
  }

  testWidgets('shows the title, time and PiliNara bottom bar', (tester) async {
    await pump(tester);
    expect(find.text('测试视频标题'), findsOneWidget);
    expect(find.text('1:00 / 10:00'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget, reason: '画面比例');
    expect(find.text('1X'), findsOneWidget, reason: '倍速');
    expect(find.text('1080P'), findsOneWidget, reason: '画质');
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the top bar is PiliNara\'s: back and home, then the switches', (tester) async {
    await pump(tester);
    for (final tip in ['返回', '主页', '窗口置顶', '听视频（只放声音）', 'SponsorBlock 已关闭，点击开启', '画中画', '更多设置']) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picture-in-picture buttons play, seek and show the way back', (tester) async {
    tester.view.physicalSize = const Size(498, 280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Scaffold(body: ColoredBox(color: Colors.black, child: PipControls(controller: controller, player: player))),
    ));
    await tester.pump();
    expect(find.text('测试视频标题'), findsOneWidget);
    expect(find.byTooltip('退出画中画'), findsOneWidget);
    expect(find.byTooltip('主页'), findsNothing);
    await tester.tap(find.byTooltip('播放/暂停 (空格)'));
    await tester.pump();
    expect(player.state.playing, isTrue);
    await tester.tap(find.byIcon(Icons.pause_circle_rounded));
    await tester.pump();
    expect(player.state.playing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the speed menu uses the speeds from settings', (tester) async {
    await pump(tester);
    await tester.tap(find.text('1X'));
    await tester.pumpAndSettle();
    for (final speed in ['0.5X', '0.75X', '1.25X', '1.5X', '1.75X', '2X', '3X']) {
      expect(find.text(speed), findsOneWidget);
    }
    await tester.tap(find.text('1.5X'));
    await tester.pumpAndSettle();
    expect(player.state.rate, 1.5);
    expect(find.text('1.5X'), findsOneWidget);
  });

  testWidgets('the fit menu changes the picture fit', (tester) async {
    await pump(tester);
    await tester.tap(find.text('自动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16:9'));
    await tester.pumpAndSettle();
    expect(videoFit.value, VideoFit.ratio16x9);
    videoFit.value = VideoFit.contain;
  });

  testWidgets('clicking the progress bar seeks', (tester) async {
    await pump(tester);
    final bar = tester.getRect(find.byType(VideoProgressBar));
    await tester.tapAt(Offset(bar.left + bar.width / 2, bar.center.dy));
    await tester.pump();
    expect(player.seeks.single.inSeconds, closeTo(300, 2));
  });

  testWidgets('keys seek by the configured step and show feedback', (tester) async {
    await controller.savePreferences(controller.preferences.copyWith(seekSeconds: 7));
    await pump(tester);
    await tester.tap(find.byType(PlayerControls), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('快进7秒'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('快进7秒'), findsNothing);
  });

  testWidgets('the more sheet lists PiliNara\'s player settings', (tester) async {
    await pump(tester);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    final sheet = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable));
    for (final item in ['选择画质', '选择音质', '播放策略', '禁用视频编码', '播放顺序', '字幕设置', '截图 (S)', '镜像翻转', '画面缩放', '定时关闭', '播放信息', '重载视频']) {
      await tester.scrollUntilVisible(find.text(item), 60, scrollable: sheet);
      expect(find.text(item), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text('定时关闭'), 60, scrollable: sheet);
    await tester.tap(find.text('定时关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 分钟'));
    await tester.pumpAndSettle();
    expect(controller.sleepAt, isNotNull);
    expect(find.byIcon(Icons.bedtime_outlined), findsOneWidget);
    controller.setSleepTimer(null);
  });
}
