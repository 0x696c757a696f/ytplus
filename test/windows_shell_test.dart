import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/windows_shell.dart';

VideoItem _video(String id) => VideoItem(id: id, title: 'T $id', channel: 'C $id', url: 'https://www.youtube.com/watch?v=$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late MethodChannel channel;

  setUp(() {
    calls = [];
    channel = const MethodChannel(WindowsShell.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('metadata, status and buttons go to the runner', () async {
    final shell = WindowsShell();
    await shell.setMetadata(title: 'Song', artist: 'Band', thumbnail: 'https://i.ytimg.com/vi/a/hqdefault.jpg');
    await shell.setStatus('playing');
    await shell.setButtons(next: true, previous: false);
    expect(calls.map((c) => c.method), ['setMetadata', 'setStatus', 'setButtons']);
    expect(calls[0].arguments, {'title': 'Song', 'artist': 'Band', 'thumbnail': 'https://i.ytimg.com/vi/a/hqdefault.jpg'});
    expect(calls[1].arguments, 'playing');
    expect(calls[2].arguments, {'next': true, 'previous': false});
  });

  test('the timeline is throttled unless forced', () async {
    final shell = WindowsShell(timelineInterval: const Duration(hours: 1));
    await shell.setTimeline(const Duration(seconds: 1), const Duration(minutes: 3));
    await shell.setTimeline(const Duration(seconds: 2), const Duration(minutes: 3));
    await shell.setTimeline(const Duration(seconds: 30), const Duration(minutes: 3), force: true);
    expect(calls.map((c) => c.arguments), [
      {'position': 1000, 'duration': 180000},
      {'position': 30000, 'duration': 180000},
    ]);
  });

  test('the tray setting carries the menu labels', () async {
    await WindowsShell().setTray(enabled: true);
    final args = calls.single.arguments as Map;
    expect(args['enabled'], isTrue);
    expect(args.keys, containsAll(['show', 'playPause', 'next', 'exit']));
  });

  test('buttons and seeks from the runner reach the callbacks', () async {
    final shell = WindowsShell();
    final buttons = <String>[];
    Duration? seek;
    shell
      ..onButton = buttons.add
      ..onSeek = (p) => seek = p;
    Future<void> fromNative(String method, Object? arguments) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(WindowsShell.channelName, const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)), (_) {});
    await fromNative('button', 'next');
    await fromNative('seek', 12000);
    expect(buttons, ['next']);
    expect(seek, const Duration(seconds: 12));
  });

  test('without a native side every call is ignored', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final shell = WindowsShell();
    await shell.setStatus('paused');
    await shell.setTray(enabled: false);
  });

  test('the sync describes the playing video and queue neighbours', () async {
    final controller = AppController()
      ..preferences = const AppPreferences(closeToTray: true)
      ..queue = [_video('a'), _video('b'), _video('c')]
      ..playing = _video('b');
    final sync = WindowsShellSync(controller, WindowsShell());
    await Future<void>.delayed(Duration.zero);
    expect(controller.previousInQueue?.id, 'a');
    final byMethod = {for (final c in calls) c.method: c.arguments};
    expect((byMethod['setMetadata'] as Map)['title'], 'T b');
    expect((byMethod['setMetadata'] as Map)['artist'], 'C b');
    expect((byMethod['setMetadata'] as Map)['thumbnail'], contains('/b/'));
    expect(byMethod['setButtons'], {'next': true, 'previous': true});
    expect((byMethod['setTray'] as Map)['enabled'], isTrue);
    sync.dispose();
  });

  test('previous is unavailable at the head of the queue', () {
    final controller = AppController()
      ..queue = [_video('a'), _video('b')]
      ..playing = _video('a');
    expect(controller.previousInQueue, isNull);
  });

  test('the new window settings are off by default and round trip', () {
    const defaults = AppPreferences();
    expect((defaults.closeToTray, defaults.audioOnlyInBackground), (false, false));
    final copy = AppPreferences.fromJson(defaults.copyWith(closeToTray: true, audioOnlyInBackground: true).toJson());
    expect((copy.closeToTray, copy.audioOnlyInBackground), (true, true));
  });
}
