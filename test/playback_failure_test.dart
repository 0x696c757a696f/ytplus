import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/playback_failure.dart';

void main() {
  FailureKind kind(List<String> messages) => PlaybackFailure.classify(messages).kind;

  test('names the cause from yt-dlp and libmpv messages', () {
    expect(kind(['ERROR: [youtube] dQw4w9WgXcQ: Private video. Sign in if you\'ve been granted access']), FailureKind.unavailable);
    expect(kind(['ERROR: [youtube] x: Sign in to confirm your age. This video may be inappropriate']), FailureKind.unavailable);
    expect(kind(['ERROR: [youtube] x: Sign in to confirm you’re not a bot. Use --cookies-from-browser']), FailureKind.botCheck);
    expect(kind(['ERROR: Unable to download API page: HTTP Error 429: Too Many Requests']), FailureKind.rateLimited);
    expect(kind(['WARNING: [youtube] x: n challenge solving failed: Some formats may be missing']), FailureKind.challenge);
    expect(kind(['Failed to open edl://…', 'HTTP error 403 Forbidden']), FailureKind.forbidden);
    expect(kind(['tcp: Connection reset by peer']), FailureKind.network);
    expect(kind(['Connection terminated unexpectedly']), FailureKind.network);
    expect(kind(['something odd']), FailureKind.unknown);
  });

  test('only retries what a retry can fix, and says what to do', () {
    expect(PlaybackFailure.classify(['HTTP Error 429']).retryable, isFalse);
    expect(PlaybackFailure.classify(['Video unavailable']).retryable, isFalse);
    expect(PlaybackFailure.classify(['403 Forbidden']).retryable, isTrue);
    expect(PlaybackFailure.classify(['timed out']).retryable, isTrue);
    expect(PlaybackFailure.classify(['HTTP Error 429']).message, startsWith('YouTube 暂时限制了请求频率'));
    expect(PlaybackFailure.classify(['odd']).message, 'odd');
  });

  test('names the disabled codecs when no stream matches the format rules', () {
    final failure = PlaybackFailure.classify(['ERROR: [youtube] x: Requested format is not available. Use --list-formats for a list of available formats']);
    expect(failure.kind, FailureKind.noFormat);
    expect(failure.retryable, isFalse);
    final named = PlaybackFailure(failure.kind, failure.detail, disabled: 'AV1、VP9');
    expect(named.message, startsWith('没有符合格式规则的可播放视频流（已禁用：AV1、VP9）。可在设置的「视频设置」中调整。'));
  });

  test('says which servers were tried after a 429', () {
    final limited = PlaybackFailure.classify(['HTTP Error 429']);
    final tried = PlaybackFailure(limited.kind, limited.detail, tried: const ['Piped', 'Invidious']);
    expect(tried.message, contains('改用 Piped、Invidious 也没有成功'));
    expect(limited.message, isNot(contains('改用')));
  });

  test('subtitle rate limits cannot replace the media failure', () {
    final failure = PlaybackFailure.classify([
      'Unable to download video subtitles: HTTP Error 429: Too Many Requests',
      'Failed to open https://www.youtube.com/api/timedtext?v=x: HTTP 429',
      'Failed to open https://rr1.googlevideo.com/videoplayback: HTTP 403 Forbidden',
    ]);
    expect(failure.kind, FailureKind.forbidden);
    expect(failure.detail, contains('googlevideo.com'));
    expect(PlaybackFailure.classify(['Failed to open subtitle: HTTP 429']).kind, FailureKind.unknown);
  });

  test('HTTP diagnostics without request addresses have no media attribution', () {
    expect(isUnattributedHttpError('https: HTTP error 429 Too Many Requests'), isTrue);
    expect(isUnattributedHttpError('HTTP error 403 Forbidden'), isTrue);
    expect(isUnattributedHttpError('Failed to open https://rr1.googlevideo.com/x: HTTP 403'), isFalse);
    expect(isSubtitleError('Failed to open https://www.youtube.com/API/TIMEDTEXT?v=x'), isTrue);
    expect(isSubtitleError('sub-add failed'), isTrue);
    expect(isSubtitleError('Failed to open https://rr1.googlevideo.com/x'), isFalse);
  });
}
