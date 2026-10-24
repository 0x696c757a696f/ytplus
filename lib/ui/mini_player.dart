// The in-app mini player: a small floating card over the pages while the
// video keeps playing, after PiliNara's in-app picture in picture
// (lib/services/pip_overlay_service.dart,
// lib/common/widgets/pip_mini_video_content.dart).
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: a widget in the shell's page area instead of a navigator
// overlay entry; it shares the player's one VideoController with the watch
// page, which is unmounted while the card shows.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:media_kit_video/media_kit_video.dart';

import '../app/app_controller.dart';
import '../app_window.dart' show pipAspectOf;
import '../l10n/l10n.dart';
import '../widgets/video_progress_bar.dart';

/// The corners the card snaps to.
enum MiniCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Where the card's top left is, in an area of [area] for a card of [size].
Offset miniPosition(MiniCorner corner, Size area, Size size, {double margin = MiniPlayer.margin}) {
  final left = corner == MiniCorner.topLeft || corner == MiniCorner.bottomLeft;
  final top = corner == MiniCorner.topLeft || corner == MiniCorner.topRight;
  return Offset(left ? margin : area.width - size.width - margin, top ? margin : area.height - size.height - margin);
}

/// The corner nearest to a card whose top left is at [offset].
MiniCorner nearestMiniCorner(Offset offset, Size area, Size size) {
  final center = offset + Offset(size.width / 2, size.height / 2);
  final left = center.dx < area.width / 2;
  final top = center.dy < area.height / 2;
  return left ? (top ? MiniCorner.topLeft : MiniCorner.bottomLeft) : (top ? MiniCorner.topRight : MiniCorner.bottomRight);
}

/// The card's size: [MiniPlayer.width] wide in the video's [aspect], made
/// smaller to fit in [area].
Size miniSize(double aspect, Size area) {
  final ratio = pipAspectOf(aspect);
  var width = MiniPlayer.width.clamp(0.0, area.width - 2 * MiniPlayer.margin);
  final maxHeight = area.height - 2 * MiniPlayer.margin;
  if (width / ratio > maxHeight) width = maxHeight * ratio;
  return Size(width, width / ratio);
}

/// The floating card. Put it in a [Stack] that fills the page area; it
/// sizes itself to that area.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, required this.controller, this.videoBuilder});
  final AppController controller;

  /// Builds the picture; tests replace it, as they have no libmpv.
  final WidgetBuilder? videoBuilder;

  static const width = 320.0;
  static const margin = 12.0;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final _subscriptions = <StreamSubscription<void>>[];
  Timer? _hideTimer;
  Timer? _mountTimer;
  bool _hovering = false;
  // The watch page's Video is still fading out for a moment after the card
  // appears; two Videos of one controller must not overlap.
  bool _videoMounted = false;
  MiniCorner _corner = MiniCorner.bottomRight;
  Offset? _dragging;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _mountTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _videoMounted = true);
    });
    final player = _controller.player;
    // Another video may have another ratio.
    if (player != null) {
      _subscriptions
        ..add(player.stream.width.listen((_) => _refresh()))
        ..add(player.stream.height.listen((_) => _refresh()));
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _mountTimer?.cancel();
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _show() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () => _setHovering(false));
    _setHovering(true);
  }

  void _setHovering(bool on) {
    if (mounted && on != _hovering) setState(() => _hovering = on);
  }

  Widget _video(BuildContext context) {
    if (!_videoMounted) return const SizedBox.expand();
    final builder = widget.videoBuilder;
    if (builder != null) return builder(context);
    final controller = _controller.videoController;
    if (controller == null) return const SizedBox.expand();
    return Video(
      controller: controller,
      controls: NoVideoControls,
      subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = _controller.player;
    if (player == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final area = constraints.biggest;
      final size = miniSize(_controller.videoAspect, area);
      final dragging = _dragging;
      final offset = dragging ?? miniPosition(_corner, area, size);
      return Stack(children: [
        AnimatedPositioned(
          duration: dragging == null ? const Duration(milliseconds: 180) : Duration.zero,
          curve: Curves.easeOut,
          left: offset.dx,
          top: offset.dy,
          width: size.width,
          height: size.height,
          child: _card(context, player, area, size),
        ),
      ]);
    });
  }

  Widget _card(BuildContext context, Player player, Size area, Size size) {
    final title = _controller.details?.title.isNotEmpty == true ? _controller.details!.title : _controller.playing?.title ?? '';
    return MouseRegion(
      onEnter: (_) => _show(),
      onHover: (_) => _show(),
      onExit: (_) {
        _hideTimer?.cancel();
        _setHovering(false);
      },
      child: Material(
        color: Colors.black,
        elevation: 8,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Stack(fit: StackFit.expand, children: [
          RepaintBoundary(child: _video(context)),
          // Under the controls, so their buttons do not wait for a double tap.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => setState(() => _dragging = miniPosition(_corner, area, size)),
            onPanUpdate: (details) {
              final next = (_dragging ?? Offset.zero) + details.delta;
              setState(() => _dragging = Offset(next.dx.clamp(0.0, area.width - size.width), next.dy.clamp(0.0, area.height - size.height)));
            },
            onPanEnd: (_) => setState(() {
              _corner = nearestMiniCorner(_dragging ?? miniPosition(_corner, area, size), area, size);
              _dragging = null;
            }),
            onTap: () {
              _show();
              unawaited(player.playOrPause());
            },
            onDoubleTap: _controller.expandMini,
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: IgnorePointer(child: _ProgressLine(player: player))),
          IgnorePointer(
            ignoring: !_hovering,
            child: AnimatedOpacity(
              opacity: _hovering ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: _Controls(controller: _controller, player: player, title: title),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A thin line of how far the video is, always visible.
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, _) {
          final total = player.state.duration.inMilliseconds;
          return LinearProgressIndicator(
            value: total > 0 ? (player.state.position.inMilliseconds / total).clamp(0.0, 1.0) : 0,
            minHeight: 2,
            color: Theme.of(context).colorScheme.inversePrimary,
            backgroundColor: Colors.white24,
          );
        },
      );
}

/// What shows while the pointer is over the card: the title with 展开 and
/// 关闭, play/pause, and a progress bar to seek with.
class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.player, required this.title});
  final AppController controller;
  final Player player;
  final String title;

  @override
  Widget build(BuildContext context) {
    const shade = BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xB3000000), Colors.transparent]),
    );
    return Column(children: [
      // Only the buttons take pointer events; the rest drags the card.
      Stack(children: [
        const Positioned.fill(child: IgnorePointer(child: DecoratedBox(decoration: shade))),
        Row(children: [
          const SizedBox(width: 8),
          Expanded(child: IgnorePointer(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12)))),
          _button(tr('展开到播放页'), Icons.open_in_full_rounded, controller.expandMini, 18),
          _button(tr('关闭小窗并停止播放'), Icons.close_rounded, controller.stopWatching, 18),
        ]),
      ]),
      Expanded(
        child: Center(
          child: StreamBuilder<bool>(
            stream: player.stream.playing,
            initialData: player.state.playing,
            builder: (context, snapshot) => _button(
              tr('播放/暂停 (空格)'),
              snapshot.data == true ? Icons.pause_circle_rounded : Icons.play_circle_rounded,
              () => unawaited(player.playOrPause()),
              40,
            ),
          ),
        ),
      ),
      Container(
        color: Colors.black.withValues(alpha: .70),
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
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
