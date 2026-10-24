import 'l10n/l10n.dart';
/// Why a video could not be resolved or played, read from yt-dlp's and
/// libmpv's messages, so each cause is handled its own way instead of all
/// being retried alike.
enum FailureKind {
  /// Private, removed, members-only, region- or age-restricted: retrying
  /// cannot help.
  unavailable,
  /// HTTP 429: more requests only extend the limit.
  rateLimited,
  /// "Sign in to confirm you're not a bot": YouTube distrusts this IP.
  botCheck,
  /// yt-dlp could not solve YouTube's JavaScript challenge; usually an
  /// outdated yt-dlp.
  challenge,
  /// HTTP 403 on a stream: the address expired or lacks a PO Token.
  forbidden,
  /// yt-dlp found no stream the format rules allow (every codec of the
  /// video is disabled, or none is left at the chosen height): retrying with
  /// the same rules cannot help and the rules are never lifted.
  noFormat,
  /// Timeouts, resets, DNS: worth reconnecting.
  network,
  unknown,
}

class PlaybackFailure {
  const PlaybackFailure(this.kind, this.detail, {this.tried = const [], this.disabled = ''});

  final FailureKind kind;
  /// The Piped or Invidious servers that were tried after YouTube said 429.
  final List<String> tried;
  /// Names of the codecs the user disabled, for [FailureKind.noFormat].
  final String disabled;
  /// The message it was read from.
  final String detail;

  static final _patterns = <(FailureKind, RegExp)>[
    (FailureKind.unavailable, RegExp(
      r"Video unavailable|Private video|video is private|members.only|join this channel|has been removed|"
      r"account[^.]{0,40}terminated|copyright|not available in your country|geo.?restrict|age.?restrict|confirm your age|"
      r"inappropriate|Premieres in|live event will begin|This live stream recording is not available",
      caseSensitive: false,
    )),
    (FailureKind.noFormat, RegExp(r'Requested format is not available', caseSensitive: false)),
    (FailureKind.rateLimited, RegExp(r'\b429\b|Too Many Requests|rate.?limit', caseSensitive: false)),
    (FailureKind.botCheck, RegExp(r"not a bot|confirm you.?re not|Sign in to confirm", caseSensitive: false)),
    (FailureKind.challenge, RegExp(r'n challenge|nsig|signature (solving|extraction|function)|JavaScript runtime|js.?runtime', caseSensitive: false)),
    (FailureKind.forbidden, RegExp(r'\b403\b|Forbidden|PO Token', caseSensitive: false)),
    (FailureKind.network, RegExp(
      r'timed? ?out|connection|tcp|tls|ssl|network|unreachable|getaddrinfo|resolve host|reset by peer|\b5\d\d\b|stream ended|failed to open',
      caseSensitive: false,
    )),
  ];

  /// The first cause any of [messages] names, most specific first.
  static PlaybackFailure classify(Iterable<String> messages) {
    final all = messages.where((m) => m.trim().isNotEmpty && !isSubtitleError(m)).toList();
    for (final (kind, pattern) in _patterns) {
      final hit = all.where(pattern.hasMatch).firstOrNull;
      if (hit != null) return PlaybackFailure(kind, hit.trim());
    }
    return PlaybackFailure(FailureKind.unknown, all.isEmpty ? '' : all.first.trim());
  }

  /// Whether reopening the video, or resolving it another way, can help.
  bool get retryable => kind == FailureKind.network || kind == FailureKind.forbidden || kind == FailureKind.unknown;

  /// What the watch page shows: the cause and what to do about it.
  String get message {
    final reason = switch (kind) {
      FailureKind.unavailable => tr('这个视频无法观看（私享、已删除、会员专属、地区或年龄限制）'),
      FailureKind.rateLimited => tried.isEmpty
          ? tr('YouTube 暂时限制了请求频率（429）。已暂停预加载 10 分钟，请过几分钟再播放，或换一个代理节点')
          : tr('YouTube 暂时限制了请求频率（429），改用 {0} 也没有成功。已暂停预加载 10 分钟，请过几分钟再播放，或换一个代理节点', [tried.join('、')]),
      FailureKind.botCheck => tr('YouTube 要求验证“不是机器人”，说明当前 IP 被怀疑。可以换一个代理节点，或在 设置 › 播放 › 播放来源 选 Piped 或 Invidious'),
      FailureKind.challenge => tr('解不开 YouTube 的 JavaScript 验证，通常是 yt-dlp 过旧。已开始检查组件更新，更新后重启 Lumtub 生效'),
      FailureKind.forbidden => tr('YouTube 拒绝了视频地址（403）。已重新解析仍失败，可以换一个代理节点，或在 设置 › 播放 › 播放来源 选 Piped 或 Invidious'),
      FailureKind.noFormat => disabled.isEmpty ? tr('没有可播放的视频流。') : tr('没有符合格式规则的可播放视频流（已禁用：{0}）。可在设置的「视频设置」中调整。', [disabled]),
      FailureKind.network => tr('网络连接失败，请检查网络或代理'),
      FailureKind.unknown => '',
    };
    final shown = detail.length > 300 ? '${detail.substring(0, 300)}…' : detail;
    if (reason.isEmpty) return shown;
    return shown.isEmpty ? reason : '$reason\n$shown';
  }
}

/// Whether an mpv error is about a subtitle track (YouTube's timedtext),
/// which never stops the video itself.
bool isSubtitleError(String message) => _subtitleError.hasMatch(message);

final _subtitleError = RegExp(r'/api/timedtext\b|\bsubtitles?\b|\bsub-add\b', caseSensitive: false);

/// FFmpeg's bare HTTP diagnostics do not identify the failed request.
/// Only the later URL-bearing error can attribute it to media or subtitles.
bool isUnattributedHttpError(String message) =>
    !RegExp(r'https?://|edl://', caseSensitive: false).hasMatch(message) &&
    RegExp(r'\b[45]\d\d\b|too many requests|forbidden', caseSensitive: false).hasMatch(message);
