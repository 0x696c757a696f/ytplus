// Player controls adapted from PiliNara (lib/plugin/pl_player/view/view.dart,
// widgets/bottom_control.dart, app_bar_ani.dart, play_pause_btn.dart,
// common_btn.dart, models/video_fit_type.dart and
// lib/pages/video/widgets/header_control.dart).
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: the controls drive media_kit through Lumtub's
// AppController instead of PiliNara's PlPlayerController and GetX; touch
// gestures, danmaku and Bilibili-only buttons are left out, and desktop
// mouse handling (hover to show, wheel for volume) is kept.

import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app/app_controller.dart';
import '../heatmap.dart';
import '../keep_awake.dart';
import '../picture_transform.dart';
import '../storyboard.dart';
import '../models.dart' show Chapter, SubtitleKind, SubtitleOption;
import '../subtitle_translation.dart';
import '../translation.dart';
import '../format_policy.dart';
import '../player_settings.dart';
import '../widgets/pilinara_settings_tiles.dart';
import '../widgets/mini_progress_line.dart';
import '../widgets/video_progress_bar.dart';
import 'cast_ui.dart';
import 'common.dart';
import 'format_policy_dialogs.dart';
import 'pages/settings_sections.dart' show trimSpeed, qualityLabel;
import 'pages/settings_subpages.dart';
import 'player_shortcuts.dart';
import 'player_stats.dart';
import 'screenshot_action.dart';
import 'storyboard_preview.dart';
import 'theater_mode.dart';
import 'video_texture_size.dart';
import '../l10n/l10n.dart';

/// Picture sizing, from PiliNara's `VideoFitType`.
enum VideoFit {
  contain('自动', BoxFit.contain),
  fill('拉伸', BoxFit.fill),
  cover('裁剪', BoxFit.cover),
  fitWidth('等宽', BoxFit.fitWidth),
  fitHeight('等高', BoxFit.fitHeight),
  none('原始', BoxFit.none),
  ratio4x3('4:3', BoxFit.fill, 4 / 3),
  ratio16x9('16:9', BoxFit.fill, 16 / 9);

  const VideoFit(this._label, this.fit, [this.aspectRatio]);
  final String _label;
  String get label => tr(_label);
  final BoxFit fit;
  final double? aspectRatio;
}

/// The chosen [VideoFit]; kept for the session like PiliNara keeps it per
/// player.
final videoFit = ValueNotifier(VideoFit.contain);

/// Colours of the SponsorBlock categories on the progress bar, as the
/// SponsorBlock extension draws them.
const _segmentColors = {
  'sponsor': Color(0xFF00D400),
  'selfpromo': Color(0xFFFFFF00),
  'interaction': Color(0xFFCC00FF),
  'intro': Color(0xFF00FFFF),
  'outro': Color(0xFF0202ED),
  'preview': Color(0xFF008FD6),
  'music_offtopic': Color(0xFFFF9900),
  'filler': Color(0xFF7300FF),
};

const _menuText = TextStyle(color: Colors.white, fontSize: 13);

/// PiliNara's control layer over the video: a title bar and a bottom bar
/// that slide in on hover, with the progress bar, play, time, fit,
/// subtitle, speed, quality and fullscreen buttons.
class PlayerControls extends StatefulWidget {
  const PlayerControls({super.key, required this.player, required this.state, required this.controller});
  final Player player;
  /// The video these controls sit on; null in tests, where there is no
  /// video surface.
  final VideoState? state;
  final AppController controller;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 200), value: 1);
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _focus = FocusNode(debugLabel: 'player controls');
  Timer? _hideTimer;
  Timer? _feedbackTimer;
  (IconData, String)? _feedback;
  int _menus = 0;
  bool _hoveringBars = false;
  late final _transform = PictureTransform(_player);
  // What yt-dlp's extraction of the playing video offers for the bar.
  String? _infoFor;
  bool _infoBusy = false;
  Heatmap? _heatmap;
  ProgressPreview? _preview;

  AppController get _controller => widget.controller;
  Player get _player => widget.player;

  @override
  void initState() {
    super.initState();
    videoFit.addListener(_applyFit);
    _controller.addListener(_syncVideo);
    KeepAwake.hold(this, _player.state.playing && !_controller.audioOnly);
    // Hides the pointer together with the bars.
    _animation.addStatusListener((_) {
      if (mounted) setState(() {});
    });
    _subscriptions.addAll([
      // The next video may have another shape; the ratio set for the last
      // one would stretch it.
      _player.stream.width.listen((_) => _applyFit()),
      _player.stream.height.listen((_) => _applyFit()),
      _player.stream.duration.listen((_) => _syncVideo()),
      _player.stream.playing.listen((playing) {
        KeepAwake.hold(this, playing && !_controller.audioOnly);
        if (!playing) {
          _show();
        } else {
          _scheduleHide();
        }
      }),
      _player.stream.completed.listen((completed) {
        if (!completed || !_controller.preferences.exitFullscreenOnEnd || !mounted) return;
        if (isFullscreen(context) && _controller.stopsAfterEnd) unawaited(widget.state?.exitFullscreen());
      }),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyFit());
    _scheduleHide();
  }

  @override
  void dispose() {
    videoFit.removeListener(_applyFit);
    _controller.removeListener(_syncVideo);
    KeepAwake.hold(this, false);
    _transform.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    _animation.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Loads the bar's preview frames and replay curve once per video, from
  /// the extraction already made for playback, and resets mirroring and zoom
  /// for a new one. Tried again until the extraction is there.
  void _syncVideo() {
    final id = _controller.playing?.id;
    if (!mounted || id == null) return;
    if (_infoFor != id) {
      _infoFor = id;
      _heatmap = null;
      _preview = null;
      _transform.reset();
      if (mounted) setState(() {});
    } else if (_heatmap != null || _preview != null) {
      return;
    }
    if (_infoBusy) return;
    _infoBusy = true;
    _controller.playingInfo().then((info) {
      _infoBusy = false;
      if (!mounted || info == null || _controller.playing?.id != id) return;
      final board = Storyboard.from(info);
      setState(() {
        _heatmap = Heatmap.from(info);
        _preview = board == null ? null : storyboardPreview(board, _controller.storyboardSheets);
      });
    });
  }

  void _applyFit() {
    final fit = videoFit.value;
    // update() cannot clear an aspect ratio, so the automatic modes pass
    // the video's own one.
    final ratio = videoAspectFor(fit.aspectRatio, _player.state.width, _player.state.height);
    widget.state?.update(fit: fit.fit, aspectRatio: ratio);
  }

  void _show() {
    _hideTimer?.cancel();
    if (_animation.status != AnimationStatus.forward && _animation.value < 1) _animation.forward();
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(Duration(seconds: _controller.preferences.controlsHideSeconds), () {
      if (!mounted || !_player.state.playing || _menus > 0 || _hoveringBars) return;
      _animation.reverse();
    });
  }

  /// The rate before a long press sped playback up, while it is held.
  double? _heldRate;

  void _holdSpeed(bool hold) {
    if (hold) {
      if (_heldRate != null || !_player.state.playing) return;
      final rate = _heldRate = _player.state.rate;
      final fast = max(2.0, rate * 2).clamp(0.25, 4.0);
      unawaited(_player.setRate(fast));
      _showFeedback(Icons.fast_forward_rounded, tr('{0}x 倍速中', [_trimRate(fast)]));
    } else if (_heldRate case final rate?) {
      _heldRate = null;
      unawaited(_player.setRate(rate));
    }
  }

  static String _trimRate(double rate) => rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

  void _showFeedback(IconData icon, String text) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = (icon, text));
    _feedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final step = _controller.preferences.volumeStep.toDouble();
    unawaited(_controller.changeVolume(event.scrollDelta.dy < 0 ? step : -step).then((_) {
      final volume = _player.state.volume.round();
      _showFeedback(volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, '$volume%');
    }));
  }

  /// Keeps the bars up while one of their menus is open.
  void _menuOpened() {
    _menus++;
    _show();
  }

  void _menuClosed() {
    if (_menus > 0) _menus--;
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = isFullscreen(context);
    final shortcuts = playerShortcuts(_controller, () => widget.state, onFeedback: _showFeedback, onScreenshot: () => unawaited(captureScreenshot(context, _controller, onFeedback: _showFeedback)));
    final controls = _controls(fullscreen, shortcuts);
    final video = _controller.videoController;
    return video == null ? controls : VideoTextureSize(controller: video, fullscreen: fullscreen, child: controls);
  }

  Widget _controls(bool fullscreen, Map<ShortcutActivator, VoidCallback> shortcuts) {
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => MouseRegion(
            onHover: (_) => _show(),
            cursor: _animation.value == 0 ? SystemMouseCursors.none : MouseCursor.defer,
            child: Listener(
              onPointerSignal: _onScroll,
              child: Stack(fit: StackFit.expand, children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _focus.requestFocus();
                    unawaited(_player.playOrPause());
                    _show();
                  },
                  onDoubleTap: () => unawaited(widget.state?.toggleFullscreen()),
                  // Hold for 2x, as on YouTube and in PiliNara.
                  onLongPressStart: (_) => _holdSpeed(true),
                  onLongPressEnd: (_) => _holdSpeed(false),
                  onLongPressCancel: () => _holdSpeed(false),
                ),
                _buffering(),
                if (_feedback case (final icon, final text)) Center(child: IgnorePointer(child: _FeedbackBubble(icon: icon, text: text))),
                if (_controller.showStats) Positioned(left: 12, top: fullscreen ? 64 : 52, child: PlayerStats(player: _player)),
                if (_controller.preferences.progressLine.shows(fullscreen: fullscreen))
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: FadeTransition(
                        opacity: _animation.drive(Tween(begin: 1.0, end: 0.0)),
                        child: MiniProgressLine(player: _player, color: Theme.of(context).colorScheme.inversePrimary),
                      ),
                    ),
                  ),
                Positioned(left: 0, right: 0, top: 0, child: _bar(top: true, child: _topBar(context, fullscreen))),
                Positioned(left: 0, right: 0, bottom: 0, child: _bar(top: false, child: _bottomBar(context, fullscreen))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  List<Chapter> get _chapters => _controller.details?.chapters ?? const [];

  /// The current chapter's title; opens the chapter list, as on YouTube.
  Widget _chapterMenu() {
    if (_chapters.isEmpty) return const SizedBox.shrink();
    // Rebuilt only when the position enters another chapter.
    int chapterAt(Duration position) {
      final chapters = _chapters;
      final current = Chapter.at(chapters, position);
      return current == null ? -1 : chapters.indexOf(current);
    }

    return StreamBuilder<int>(
        stream: _player.stream.position.map(chapterAt).distinct(),
        initialData: chapterAt(_player.state.position),
        builder: (context, _) {
          final chapters = _chapters;
          final current = Chapter.at(chapters, _player.state.position);
          return _PopupMenu<int>(
            tooltip: tr('章节'),
            value: current == null ? -1 : chapters.indexOf(current),
            items: [for (final (i, c) in chapters.indexed) (i, '${formatPlaybackTime(c.start)}  ${c.title}')],
            onSelected: (i) => unawaited(_player.seek(chapters[i].start)),
            onOpened: _menuOpened,
            onClosed: _menuClosed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Text('·  ${current?.title ?? chapters.first.title}  ›', style: _menuText, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          );
        },
      );
  }

  Widget _buffering() => StreamBuilder<bool>(
        stream: _player.stream.buffering,
        initialData: _player.state.buffering,
        builder: (context, snapshot) => snapshot.data == true
            ? const Center(child: IgnorePointer(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))))
            : const SizedBox.shrink(),
      );

  /// PiliNara's `AppBarAni`: a gradient bar that slides out of the edge.
  Widget _bar({required bool top, required Widget child}) => MouseRegion(
        onEnter: (_) => _hoveringBars = true,
        onExit: (_) {
          _hoveringBars = false;
          _scheduleHide();
        },
        child: SlideTransition(
          position: _animation.drive(Tween(begin: Offset(0, top ? -1 : 1.2), end: Offset.zero)),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.bottomCenter : Alignment.topCenter,
                end: top ? Alignment.topCenter : Alignment.bottomCenter,
                colors: const [Colors.transparent, Color(0xBF000000)],
              ),
            ),
            child: child,
          ),
        ),
      );

  /// Laid out as PiliNara's: 返回 and 主页 on the left, the title, then a
  /// row of switches.
  Widget _topBar(BuildContext context, bool fullscreen) {
    final item = _controller.playing;
    final details = _controller.details;
    final title = details?.title.isNotEmpty == true ? details!.title : item?.title ?? '';
    Future<void> leaveFullscreen() async {
      if (fullscreen) await widget.state?.exitFullscreen();
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(fullscreen ? 8 : 6, fullscreen ? 10 : 4, 8, 16),
      child: Row(children: [
        _IconButton(
          tooltip: fullscreen ? tr('退出全屏') : tr('返回'),
          icon: Icons.arrow_back_rounded,
          size: 20,
          onTap: () => fullscreen ? unawaited(leaveFullscreen()) : _controller.goBack(),
        ),
        _IconButton(
          tooltip: tr('主页'),
          icon: Icons.home_rounded,
          size: 20,
          onTap: () async {
            await leaveFullscreen();
            _controller.navigate(PageMode.home);
          },
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: fullscreen ? 16 : 14)),
        ),
        if (_controller.sleepAt != null || _controller.sleepAfterCurrent)
          Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Tooltip(message: tr('定时关闭已开启'), child: Icon(Icons.bedtime_outlined, color: Colors.white, size: 18))),
        _IconButton(
          tooltip: tr('投屏'),
          icon: _controller.cast.active ? Icons.cast_connected_rounded : Icons.cast_rounded,
          size: 19,
          active: _controller.cast.active,
          onTap: () => unawaited(showCastDialog(context, _controller)),
        ),
        _IconButton(
          tooltip: _controller.pinned ? tr('取消置顶') : tr('窗口置顶'),
          icon: _controller.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
          size: 19,
          active: _controller.pinned,
          onTap: _controller.togglePinned,
        ),
        _IconButton(
          tooltip: _controller.audioOnly ? tr('恢复画面') : tr('听视频（只放声音）'),
          icon: Icons.headphones_rounded,
          size: 19,
          active: _controller.audioOnly,
          onTap: () => unawaited(_controller.toggleAudioOnly()),
        ),
        _IconButton(
          tooltip: _controller.settings.sponsorBlock ? tr('SponsorBlock 已开启，点击关闭') : tr('SponsorBlock 已关闭，点击开启'),
          icon: _controller.settings.sponsorBlock ? Icons.shield_rounded : Icons.shield_outlined,
          size: 19,
          active: _controller.settings.sponsorBlock,
          onTap: () => unawaited(_controller.toggleSponsorBlock()),
        ),
        _IconButton(
          tooltip: tr('应用内小窗'),
          icon: Icons.picture_in_picture_rounded,
          size: 19,
          onTap: () async {
            await leaveFullscreen();
            _controller.enterMini();
          },
        ),
        _IconButton(
          tooltip: tr('画中画'),
          icon: Icons.picture_in_picture_alt_rounded,
          size: 19,
          onTap: () async {
            await leaveFullscreen();
            _controller.setPip(true);
          },
        ),
        _IconButton(tooltip: tr('播放信息 (I)'), icon: Icons.info_outline_rounded, size: 19, active: _controller.showStats, onTap: _controller.toggleStats),
        _IconButton(tooltip: tr('更多设置'), icon: Icons.more_vert_rounded, size: 20, onTap: () => _showMore(context)),
      ]),
    );
  }

  Widget _bottomBar(BuildContext context, bool fullscreen) {
    final primary = Theme.of(context).colorScheme.inversePrimary;
    final width = fullscreen ? 42.0 : 35.0;
    // Keep the action cluster anchored to the physical bottom-right edge in
    // fullscreen. The progress and playback information remain on the left.
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(fullscreen ? 18 : 10, 16, fullscreen ? 18 : 10, fullscreen ? 14 : 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: StreamBuilder<Duration>(
            stream: _player.stream.position,
            initialData: _player.state.position,
            builder: (context, _) => VideoProgressBar(
              position: _player.state.position,
              buffered: _player.state.buffer,
              total: _player.state.duration,
              color: primary,
              segments: [
                for (final s in _controller.segments) ProgressSegment(s.start, s.end, _segmentColors[s.category] ?? const Color(0xFF00D400)),
              ],
              chapterStarts: [for (final c in _chapters) c.start],
              preview: _preview,
              heatmap: _controller.preferences.showHeatmap ? _heatmap?.values : null,
              labelOf: _chapters.isEmpty ? null : (time) => '${formatPlaybackTime(time)} · ${Chapter.at(_chapters, time)?.title ?? ''}',
              onSeek: (time) => unawaited(_player.seek(time)),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(children: [
          _PlayPauseButton(player: _player),
          if (_controller.hasNext)
            _IconButton(tooltip: tr('下一个 (Shift+N)'), icon: Icons.skip_next_rounded, size: 22, width: width, onTap: () => unawaited(_controller.playNext())),
          const SizedBox(width: 4),
          StreamBuilder<Duration>(
            stream: _player.stream.position,
            initialData: _player.state.position,
            builder: (context, _) => Text(
              '${formatPlaybackTime(_player.state.position)} / ${formatPlaybackTime(_player.state.duration)}',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          if (_chapters.isNotEmpty) Flexible(child: _chapterMenu()),
          const Spacer(),
          _VolumeButton(player: _player, controller: _controller, onMenuOpened: _menuOpened, onMenuClosed: _menuClosed),
          ValueListenableBuilder(
            valueListenable: videoFit,
            builder: (context, fit, _) => _TextMenu<VideoFit>(
              tooltip: tr('画面比例'),
              label: fit.label,
              value: fit,
              values: [for (final f in VideoFit.values) (f, f.label)],
              onSelected: (f) => videoFit.value = f,
              onOpened: _menuOpened,
              onClosed: _menuClosed,
            ),
          ),
          _subtitleMenu(width),
          StreamBuilder<double>(
            stream: _player.stream.rate,
            initialData: _player.state.rate,
            builder: (context, _) => _TextMenu<double>(
              tooltip: tr('倍速'),
              label: '${trimSpeed(_player.state.rate)}X',
              value: _player.state.rate,
              values: [for (final speed in _controller.settings.speeds) (speed, '${trimSpeed(speed)}X')],
              onSelected: (speed) => unawaited(_player.setRate(speed)),
              onOpened: _menuOpened,
              onClosed: _menuClosed,
            ),
          ),
          StreamBuilder<int?>(
            stream: _player.stream.height,
            initialData: _player.state.height,
            builder: (context, _) {
              final height = _player.state.height ?? 0;
              final max = _controller.settings.maxHeight;
              final choices = _controller.qualityChoices;
              return _TextMenu<int>(
                tooltip: tr('画质'),
                label: height > 0 ? '${height}P' : (max == 0 ? tr('自动') : '${max}P'),
                // A limit above what this video offers plays its highest.
                value: choices.contains(max) ? max : height,
                values: [for (final h in choices) (h, h == 0 ? tr('自动') : '${h}P')],
                onSelected: (h) => unawaited(_controller.setMaxHeight(h)),
                onOpened: _menuOpened,
                onClosed: _menuClosed,
              );
            },
          ),
          if (!fullscreen)
            ValueListenableBuilder(
              valueListenable: theaterMode,
              builder: (context, theater, _) => _IconButton(
                tooltip: theater ? tr('退出剧场模式 (T)') : tr('剧场模式 (T)'),
                icon: Icons.crop_16_9_rounded,
                size: 22,
                width: width,
                active: theater,
                onTap: () => theaterMode.value = !theater,
              ),
            ),
          _IconButton(
            tooltip: fullscreen ? tr('退出全屏 (F)') : tr('全屏 (F)'),
            icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
            size: 24,
            width: width,
            onTap: () => unawaited(widget.state?.toggleFullscreen()),
          ),
        ]),
        ]),
      ),
    );
  }

  Widget _subtitleMenu(double width) => StreamBuilder<Track>(
        stream: _player.stream.track,
        initialData: _player.state.track,
        builder: (context, _) {
          final tracks = _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
          final current = _player.state.track.subtitle;
          final on = current.id != 'no' && current.id != 'auto';
          final offered = _controller.details?.subtitles ?? const <SubtitleOption>[];
          if (tracks.isEmpty && offered.isEmpty) return const SizedBox.shrink();
          const more = '\u0000more';
          const translate = '\u0000translate';
          const bilingual = '\u0000bilingual';
          const secondary = '\u0000secondary';
          final target = TranslationLanguage.byCode(_controller.preferences.translateLanguage);
          final translation = translationOf(offered, target);
          final secondaryOn = _controller.secondarySubtitle != null;
          return _PopupMenu<String>(
            tooltip: tr('字幕'),
            value: current.id,
            items: [
              ('no', tr('关闭字幕')),
              for (final t in tracks) (t.id, _trackLabel(t.id, t.title, t.language)),
              if (offered.isNotEmpty) (more, tr('全部字幕（{0}）…', [offered.length])),
              if (translation != null) (translate, tr('翻译字幕为{0}', [target.label])),
              if (translation != null || secondaryOn) (bilingual, secondaryOn ? tr('关闭双语字幕') : tr('双语字幕（加{0}副字幕）', [target.label])),
              if (offered.isNotEmpty) (secondary, tr('副字幕…')),
            ],
            onSelected: (id) {
              if (id == more) {
                unawaited(_pickSubtitle(context, offered));
              } else if (id == secondary) {
                unawaited(_pickSubtitle(context, offered, secondary: true));
              } else if (id == translate) {
                unawaited(_controller.showSubtitle(translation!));
              } else if (id == bilingual) {
                unawaited(_controller.setSecondarySubtitle(secondaryOn ? null : translation));
              } else {
                unawaited(_player.setSubtitleTrack(id == 'no' ? SubtitleTrack.no() : tracks.firstWhere((t) => t.id == id)));
              }
            },
            onOpened: _menuOpened,
            onClosed: _menuClosed,
            child: SizedBox(
              width: width,
              height: 30,
              child: Icon(on ? Icons.closed_caption_rounded : Icons.closed_caption_off_outlined, size: 22, color: Colors.white),
            ),
          );
        },
      );

  /// PiliNara's header "更多" sheet: format, order, subtitles, sleep timer,
  /// playback info and reload.
  Future<void> _showMore(BuildContext context) async {
    _menuOpened();
    final settings = _controller.settings;
    final audio = _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    String sleepLabel() {
      if (_controller.sleepAfterCurrent) return tr('播完当前视频后暂停');
      final at = _controller.sleepAt;
      if (at == null) return tr('未开启');
      final left = at.difference(DateTime.now());
      return tr('{0} 分钟后暂停', [left.inMinutes + 1]);
    }

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (sheet) {
        Widget item(IconData icon, String title, String? subtitle, VoidCallback onTap) => ListTile(
              dense: true,
              leading: Icon(icon, size: 20),
              title: Text(title),
              subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(color: Theme.of(sheet).colorScheme.outline, fontSize: 12)),
              onTap: () {
                Navigator.pop(sheet);
                onTap();
              },
            );
        return SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 12), children: [
            item(Icons.high_quality_outlined, tr('选择画质'), qualityLabel(settings.maxHeight), () {
              pickFromDialog<int>(context, title: tr('选择画质'), value: settings.maxHeight, values: [for (final h in _controller.qualityChoices) (h, qualityLabel(h))], onSelected: _controller.setMaxHeight);
            }),
            item(Icons.music_note_outlined, tr('选择音质'), settings.audioQuality.label, () {
              pickFromDialog<AudioQuality>(
                context,
                title: tr('选择音质'),
                value: settings.audioQuality,
                values: [for (final q in AudioQuality.values) (q, q.label)],
                onSelected: (q) => _controller.reloadVideo(_controller.settings.copyWith(audioQuality: q)),
              );
            }),
            item(Icons.movie_filter_outlined, tr('播放策略'), settings.strategy.label, () {
              pickPlaybackStrategy(context, settings.strategy, (v) => _controller.reloadVideo(_controller.settings.copyWith(strategy: v)));
            }),
            item(Icons.block_outlined, tr('禁用视频编码'), FormatPolicy.disabledNames(settings).isEmpty ? tr('无') : FormatPolicy.disabledNames(settings), () {
              pickDisabledCodecs(context, settings.disabledCodecs, (v) => _controller.reloadVideo(_controller.settings.copyWith(disabledCodecs: v)));
            }),
            if (audio.length > 1)
              item(Icons.audiotrack_rounded, tr('选择音轨'), _trackLabel(_player.state.track.audio.id, _player.state.track.audio.title, _player.state.track.audio.language), () {
                pickFromDialog<String>(
                  context,
                  title: tr('选择音轨'),
                  value: _player.state.track.audio.id,
                  values: [for (final t in audio) (t.id, _trackLabel(t.id, t.title, t.language))],
                  onSelected: (id) => _player.setAudioTrack(audio.firstWhere((t) => t.id == id)),
                );
              }),
            item(Icons.repeat_rounded, tr('播放顺序'), settings.playOrder.label, () {
              pickFromDialog<PlayOrder>(context, title: tr('播放顺序'), value: settings.playOrder, values: [for (final o in PlayOrder.values) (o, o.label)], onSelected: _controller.setPlayOrder);
            }),
            item(Icons.subtitles_outlined, tr('字幕设置'), '${settings.subtitleMode.label} · ${settings.subtitleLanguage.label}', () => openSubtitleSettings(context, _controller)),
            item(Icons.tune_rounded, tr('画面与音画同步调节'), null, () => openPictureSettings(context, _controller)),
            item(Icons.photo_camera_outlined, tr('截图 (S)'), tr('保存到“图片\\Lumtub”并复制'), () => unawaited(captureScreenshot(context, _controller, onFeedback: _showFeedback))),
            item(Icons.flip_rounded, tr('镜像翻转'), _transform.mirrored ? tr('已开启') : tr('未开启'), () => unawaited(_transform.setMirrored(!_transform.mirrored))),
            item(Icons.zoom_in_rounded, tr('画面缩放'), _transform.zoom == 1 ? tr('原始大小') : '${trimSpeed(_transform.zoom)}x', () {
              pickFromDialog<double>(
                context,
                title: tr('画面缩放'),
                value: _transform.zoom,
                values: [for (final z in PictureTransform.zoomLevels) (z, z == 1 ? tr('原始大小') : '${trimSpeed(z)}x')],
                onSelected: (z) => unawaited(_transform.setZoom(z)),
              );
            }),
            item(Icons.bedtime_outlined, tr('定时关闭'), sleepLabel(), () => _pickSleepTimer(context)),
            item(Icons.info_outline_rounded, tr('播放信息'), _controller.showStats ? tr('显示中') : null, _controller.toggleStats),
            item(Icons.refresh_rounded, tr('重载视频'), tr('从当前位置重新加载'), () => unawaited(_controller.reloadVideo())),
            item(Icons.keyboard_outlined, tr('快捷键'), null, () => showShortcutHelp(context, _controller.preferences)),
          ]),
        );
      },
    );
    _menuClosed();
  }

  Future<void> _pickSleepTimer(BuildContext context) async {
    const off = -1;
    const afterCurrent = 0;
    final current = _controller.sleepAfterCurrent ? afterCurrent : (_controller.sleepAt == null ? off : null);
    await pickFromDialog<int?>(
      context,
      title: tr('定时关闭'),
      value: current,
      values: [(off, tr('不开启')), (afterCurrent, tr('播完当前视频后')), (15, tr('15 分钟')), (30, tr('30 分钟')), (45, tr('45 分钟')), (60, tr('60 分钟')), (90, tr('90 分钟'))],
      onSelected: (minutes) {
        if (minutes == null || minutes == off) {
          _controller.setSleepTimer(null);
        } else if (minutes == afterCurrent) {
          _controller.setSleepTimer(null, afterCurrent: true);
        } else {
          _controller.setSleepTimer(Duration(minutes: minutes));
        }
      },
    );
  }

  /// Every subtitle the video offers, with a filter; the pick is added to
  /// the player.
  Future<void> _pickSubtitle(BuildContext context, List<SubtitleOption> offered, {bool secondary = false}) async {
    _menuOpened();
    final picked = await showDialog<SubtitleOption>(context: context, builder: (context) => _SubtitlePicker(options: offered, title: secondary ? tr('副字幕（显示在主字幕上方）') : null));
    _menuClosed();
    if (picked != null) await (secondary ? _controller.setSecondarySubtitle(picked) : _controller.showSubtitle(picked));
  }

  static String _trackLabel(String id, String? title, String? language) {
    final parts = [if (title != null && title.isNotEmpty) title, if (language != null && language.isNotEmpty) language];
    return parts.isEmpty ? tr('轨道 {0}', [id]) : parts.join(' · ');
  }
}

/// PiliNara's `ComBtn`: a bare white icon with a tooltip.
class _IconButton extends StatelessWidget {
  const _IconButton({required this.tooltip, required this.icon, required this.onTap, this.size = 22, this.width = 34, this.active = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double width;
  /// A switch that is on, drawn in the theme's color.
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox(width: width, height: 34, child: Icon(icon, size: size, color: active ? Theme.of(context).colorScheme.inversePrimary : Colors.white)),
          ),
        ),
      );
}

/// PiliNara's `PlayOrPauseButton`, animating between the two icons.
class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({required this.player});
  final Player player;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this, value: widget.player.state.playing ? 1 : 0, duration: const Duration(milliseconds: 200));
  late final StreamSubscription<bool> _subscription = widget.player.stream.playing.listen((playing) => playing ? _animation.forward() : _animation.reverse());

  @override
  void initState() {
    super.initState();
    _subscription;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tr('播放/暂停 (空格)'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(widget.player.playOrPause()),
            child: SizedBox(
              width: 42,
              height: 34,
              child: Center(child: AnimatedIcon(progress: _animation, icon: AnimatedIcons.play_pause, color: Colors.white, size: 20)),
            ),
          ),
        ),
      );
}

/// PiliNara's dark popup menu: 0.8 black, 35 high rows, 13px white text.
class _PopupMenu<T> extends StatelessWidget {
  const _PopupMenu({
    required this.tooltip,
    required this.value,
    required this.items,
    required this.onSelected,
    required this.onOpened,
    required this.onClosed,
    required this.child,
  });

  final String tooltip;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onSelected;
  final VoidCallback onOpened;
  final VoidCallback onClosed;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
        tooltip: tooltip,
        requestFocus: false,
        initialValue: value,
        color: Colors.black.withValues(alpha: 0.8),
        menuPadding: EdgeInsets.zero,
        position: PopupMenuPosition.over,
        onOpened: onOpened,
        onCanceled: onClosed,
        onSelected: (v) {
          onClosed();
          onSelected(v);
        },
        itemBuilder: (context) => [
          for (final (item, label) in items)
            PopupMenuItem<T>(
              height: 35,
              padding: const EdgeInsets.only(left: 30, right: 30),
              value: item,
              child: Text(label, style: item == value ? _menuText.copyWith(color: Theme.of(context).colorScheme.inversePrimary) : _menuText),
            ),
        ],
        child: child,
      );
}

/// A menu shown as its current value in text, like PiliNara's speed, fit
/// and quality buttons.
class _TextMenu<T> extends StatelessWidget {
  const _TextMenu({
    required this.tooltip,
    required this.label,
    required this.value,
    required this.values,
    required this.onSelected,
    required this.onOpened,
    required this.onClosed,
  });

  final String tooltip;
  final String label;
  final T value;
  final List<(T, String)> values;
  final ValueChanged<T> onSelected;
  final VoidCallback onOpened;
  final VoidCallback onClosed;

  @override
  Widget build(BuildContext context) => _PopupMenu<T>(
        tooltip: tooltip,
        value: value,
        items: values,
        onSelected: onSelected,
        onOpened: onOpened,
        onClosed: onClosed,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Text(label, style: _menuText)),
      );
}

/// Volume icon that mutes on click and shows a slider on hover.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.player, required this.controller, required this.onMenuOpened, required this.onMenuClosed});
  final Player player;
  final AppController controller;
  final VoidCallback onMenuOpened;
  final VoidCallback onMenuClosed;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  bool _open = false;

  void _setOpen(bool open) {
    if (open == _open) return;
    setState(() => _open = open);
    open ? widget.onMenuOpened() : widget.onMenuClosed();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => _setOpen(true),
        onExit: (_) => _setOpen(false),
        child: StreamBuilder<double>(
          stream: widget.player.stream.volume,
          initialData: widget.player.state.volume,
          builder: (context, _) {
            final volume = widget.player.state.volume;
            final max = widget.controller.settings.volumeMax.toDouble();
            return Row(mainAxisSize: MainAxisSize.min, children: [
              _IconButton(
                tooltip: volume == 0 ? tr('取消静音 (M)') : tr('静音 (M)'),
                icon: volume == 0 ? Icons.volume_off_rounded : (volume < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                onTap: () => unawaited(widget.controller.toggleMute()),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                child: _open
                    ? SizedBox(
                        width: 96,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape: SliderComponentShape.noOverlay,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor: Colors.white30,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(value: volume.clamp(0, max), max: max, onChanged: (v) => unawaited(widget.player.setVolume(v))),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ]);
          },
        ),
      );
}

/// The seek, volume and mute indicator in the middle of the video.
class _FeedbackBubble extends StatelessWidget {
  const _FeedbackBubble({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: const Color(0x88000000), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ]),
      );
}

/// Lists [options] by kind, with a filter by language name or code.
class _SubtitlePicker extends StatefulWidget {
  const _SubtitlePicker({required this.options, this.title});
  final List<SubtitleOption> options;
  final String? title;

  @override
  State<_SubtitlePicker> createState() => _SubtitlePickerState();
}

class _SubtitlePickerState extends State<_SubtitlePicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final shown = widget.options.where((o) => query.isEmpty || o.label.toLowerCase().contains(query) || o.language.toLowerCase().contains(query) || o.name.toLowerCase().contains(query)).toList();
    final headings = {SubtitleKind.uploaded: tr('上传的字幕'), SubtitleKind.automatic: tr('自动生成'), SubtitleKind.translated: tr('自动翻译')};
    return AlertDialog(
      title: Text(widget.title ?? tr('选择字幕')),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 420,
        height: 520,
        child: Column(children: [
          TextField(
            autofocus: true,
            decoration: InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 20), hintText: tr('搜索语言，如 中文、ja')),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Expanded(child: ListView(children: [
            for (final kind in SubtitleKind.values)
              if (shown.where((o) => o.kind == kind).toList() case final group when group.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Text(headings[kind]!, style: Theme.of(context).textTheme.labelLarge!.copyWith(color: Theme.of(context).colorScheme.primary)),
                ),
                for (final option in group) ListTile(dense: true, title: Text(option.label), subtitle: Text(option.language), onTap: () => Navigator.of(context).pop(option)),
              ],
            if (shown.isEmpty) Padding(padding: EdgeInsets.all(24), child: Center(child: Text(tr('没有匹配的语言')))),
          ])),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('取消')))],
    );
  }
}
