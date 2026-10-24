import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/playback_recovery.dart';

void main() {
  late DateTime now;
  late PlaybackRecovery recovery;
  const resume = Duration(hours: 1, minutes: 16, seconds: 39);

  setUp(() {
    now = DateTime(2026);
    recovery = PlaybackRecovery(maxAttempts: 1, clock: () => now);
    expect(recovery.tryAttempt(position: resume), isTrue);
  });

  bool progress(Duration position, {bool playing = true, bool buffering = false, bool decoded = true, double rate = 1}) =>
      recovery.observeProgress(position, playing: playing, buffering: buffering, decoded: decoded, rate: rate);

  test('reopening and returning to the resume position do not reset attempts', () {
    now = now.add(const Duration(seconds: 1));
    expect(progress(resume), isFalse);
    expect(recovery.awaitingProgress, isTrue);
    expect(recovery.tryAttempt(position: resume), isFalse);
  });

  test('ten seconds of decoded progress resets the recovery budget', () {
    for (var second = 1; second <= 10; second++) {
      now = now.add(const Duration(seconds: 1));
      expect(progress(resume + Duration(seconds: second)), second == 10);
    }
    expect(recovery.awaitingProgress, isFalse);
    expect(recovery.tryAttempt(position: resume + const Duration(seconds: 10)), isTrue);
  });

  test('a seek cannot prove successful playback', () {
    now = now.add(const Duration(milliseconds: 250));
    expect(progress(resume + const Duration(seconds: 30)), isFalse);
    expect(recovery.awaitingProgress, isTrue);
    expect(recovery.tryAttempt(position: resume), isFalse);
  });

  test('paused, buffering and undecoded positions cannot prove recovery', () {
    for (var second = 1; second <= 12; second++) {
      now = now.add(const Duration(seconds: 1));
      expect(progress(resume + Duration(seconds: second), playing: false), isFalse);
    }
    for (var second = 13; second <= 24; second++) {
      now = now.add(const Duration(seconds: 1));
      expect(progress(resume + Duration(seconds: second), buffering: true), isFalse);
    }
    for (var second = 25; second <= 36; second++) {
      now = now.add(const Duration(seconds: 1));
      expect(progress(resume + Duration(seconds: second), decoded: false), isFalse);
    }
    expect(recovery.awaitingProgress, isTrue);
    expect(recovery.tryAttempt(position: resume), isFalse);
  });

  test('slow playback advances without being treated as a stalled recovery', () {
    for (var second = 1; second <= 40; second++) {
      now = now.add(const Duration(seconds: 1));
      expect(progress(resume + Duration(milliseconds: second * 250), rate: .25), second == 40);
      expect(recovery.stalled, isFalse);
    }
  });

  test('position notifications without progress still time out', () {
    now = now.add(PlaybackRecovery.stallTimeout);
    expect(progress(resume), isFalse);
    expect(recovery.stalled, isTrue);
    recovery.reset();
    expect(recovery.awaitingProgress, isFalse);
    expect(recovery.stalled, isFalse);
  });
}
