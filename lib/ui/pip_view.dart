// The picture-in-picture window's content, after PiliNara's desktop
// picture in picture (lib/plugin/pl_player/view/view.dart, controller.dart):
// only the video, dragged by the picture, with controls that show while the
// pointer is over it.
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: the window is moved and sized through lib/app_window.dart
// instead of window_manager; the controls are a small set of buttons.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:media_kit_video/media_kit_video.dart';

import '../app/app_controller.dart';
import '../app_window.dart';
import '../l10n/l10n.dart';
import '../widgets/video_progress_bar.dart';
import 'pages/watch_page.dart' show subtitleViewFor;
import 'player_shortcuts.dart';

class PipView extends StatefulWidget {
  const PipView({super.key, required this.controller});
  final AppController controller;

  @override
  State<PipView> createState() => _PipViewState();
}

class _PipViewState extends State<PipView> {
  AppController get _controller => widget.controller;
  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _hideTimer;
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    final player = _controller.player;
    // Another video may have another ratio.
    if (player != null) {
      _subscriptions
        ..add(player.stream.width.listen((_) => _controller.updatePipAspect()))
        ..add(player.stream.height.listen((_) => _controller.updatePipAspect()));
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  void _show() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () => _setHovering(false));
    _setHovering(true);
  }

  void _setHovering(bool on) {
    if (mounted && on != _hovering) setState(() => _hovering = on);
  }

  void _leave() => _controller.setPip(false);

  @override
  Widget build(BuildContext context) {
    final player = _controller.player!;
    final scale = (MediaQuery.sizeOf(context).shortestSide / 280).clamp(0.6, 2.0);
    final subtitles = subtitleViewFor(_controller.settings);
    return CallbackShortcuts(
      bindings: {
        ...playerShortcuts(_controller, () => null),
        const SingleActivator(LogicalKeyboardKey.escape): _leave,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black,
          child: MouseRegion(
            onEnter: (_) => _show(),
            onHover: (_) => _show(),
            onExit: (_) {
              _hideTimer?.cancel();
              _setHovering(false);
            },
            child: Stack(fit: StackFit.expand, children: [
              Video(
                controller: _controller.videoController!,
                controls: NoVideoControls,
                subtitleViewConfiguration: SubtitleViewConfiguration(
                  visible: subtitles.visible,
                  style: subtitles.style.copyWith(fontSize: 14 * scale),
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                ),
              ),
              // Press and move to drag the window; double-click to go back.
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => AppWindow.startDrag(),
                onTap: () => unawaited(player.playOrPause()),
                onDoubleTap: _leave,
              ),
              IgnorePointer(
                ignoring: !_hovering,
                child: AnimatedOpacity(
                  opacity: _hovering ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: PipControls(controller: _controller, player: player, scale: scale),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => AppWindow.startResize(),
                    child: const SizedBox(width: 18, height: 18),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The buttons over the picture: title (also a drag handle), back to the
/// full window, play/pause with seeking, and a progress bar.
class PipControls extends StatelessWidget {
  const PipControls({super.key, required this.controller, required this.player, this.scale = 1});
  final AppController controller;
  final Player player;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final seek = controller.preferences.longSeekSeconds;
    final title = controller.details?.title.isNotEmpty == true ? controller.details!.title : controller.playing?.title ?? '';
    const shade = BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x99000000), Colors.transparent]),
    );
    return Column(children: [
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => AppWindow.startDrag(),
        onDoubleTap: () => controller.setPip(false),
        child: DecoratedBox(
          decoration: shade,
          child: Row(children: [
            const SizedBox(width: 8),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12))),
            _button(tr('退出画中画'), Icons.open_in_full_rounded, () => controller.setPip(false), 18),
          ]),
        ),
      ),
      Expanded(
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _button(tr('快退{0}秒', [seek]), Icons.replay_10_rounded, () => unawaited(controller.seekBy(Duration(seconds: -seek))), 26 * scale),
            StreamBuilder<bool>(
              stream: player.stream.playing,
              initialData: player.state.playing,
              builder: (context, snapshot) => _button(
                tr('播放/暂停 (空格)'),
                snapshot.data == true ? Icons.pause_circle_rounded : Icons.play_circle_rounded,
                () => unawaited(player.playOrPause()),
                38 * scale,
              ),
            ),
            _button(tr('快进{0}秒', [seek]), Icons.forward_10_rounded, () => unawaited(controller.seekBy(Duration(seconds: seek))), 26 * scale),
          ]),
        ),
      ),
      Container(
        color: Colors.black.withValues(alpha: .70),
        padding: const EdgeInsets.fromLTRB(6, 0, 20, 2),
        child: StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, _) => VideoProgressBar(
            position: player.state.position,
            buffered: player.state.buffer,
            total: player.state.duration,
            color: Colors.white,
            onSeek: (time) => unawaited(player.seek(time)),
          ),
        ),
      ),
    ]);
  }

  Widget _button(String tooltip, IconData icon, VoidCallback onTap, double size) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white, size: size),
        onPressed: onTap,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: .70),
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
}
