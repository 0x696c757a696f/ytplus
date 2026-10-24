// Desktop progress bar modeled on PiliNara's player (lib/plugin/pl_player/
// widgets/bottom_control.dart and its _DesktopProgressHoverPainter): a thin
// bar with buffered and played parts, a thumb, SponsorBlock segments, and
// hover markers with the time under the pointer.
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: rewritten as one self-contained widget without GetX or
// the audio_video_progress_bar package.

import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A segment of the bar drawn in [color], such as a sponsor segment.
class ProgressSegment {
  const ProgressSegment(this.start, this.end, this.color);
  final Duration start;
  final Duration end;
  final Color color;
}

/// A picture shown above the pointer, such as the frame at that time.
class ProgressPreview {
  const ProgressPreview(this.size, this.builder);
  final Size size;
  final Widget Function(Duration time) builder;
}

class VideoProgressBar extends StatefulWidget {
  const VideoProgressBar({
    super.key,
    required this.position,
    required this.buffered,
    required this.total,
    required this.onSeek,
    required this.color,
    this.segments = const [],
    this.chapterStarts = const [],
    this.labelOf,
    this.preview,
    this.heatmap,
  });

  final Duration position;
  final Duration buffered;
  final Duration total;
  final ValueChanged<Duration> onSeek;
  final Color color;
  final List<ProgressSegment> segments;
  /// Where chapters begin; the bar shows a gap at each.
  final List<Duration> chapterStarts;
  /// The hover label for a time; the time itself by default.
  final String Function(Duration time)? labelOf;
  /// A frame shown above the time label while the pointer is on the bar.
  final ProgressPreview? preview;
  /// Samples 0..1 over the whole bar, drawn as a faint curve above it.
  final List<double>? heatmap;

  static const barHeight = 3.5;
  static const height = 20.0;
  static const heatmapHeight = 16.0;

  @override
  State<VideoProgressBar> createState() => _VideoProgressBarState();
}

class _VideoProgressBarState extends State<VideoProgressBar> {
  double? _hover;
  double? _drag;

  double _fractionAt(double dx, double width) => width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  Duration _timeAt(double fraction) => widget.total * fraction;

  void _seek(double fraction) {
    if (widget.total > Duration.zero) widget.onSeek(_timeAt(fraction));
  }

  double _fractionOf(Duration time) => widget.total > Duration.zero ? (time.inMilliseconds / widget.total.inMilliseconds).clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final played = _drag ?? _fractionOf(widget.position);
        final pointer = _drag ?? _hover;
        return SizedBox(
          height: VideoProgressBar.height,
          child: Stack(clipBehavior: Clip.none, children: [
            if (widget.heatmap case final heat? when heat.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: VideoProgressBar.height / 2 + VideoProgressBar.barHeight / 2 + 1,
                height: VideoProgressBar.heatmapHeight,
                child: IgnorePointer(child: CustomPaint(painter: _HeatmapPainter(heat, widget.color))),
              ),
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (event) => setState(() => _hover = _fractionAt(event.localPosition.dx, width)),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _seek(_fractionAt(details.localPosition.dx, width)),
                  onHorizontalDragStart: (details) => setState(() => _drag = _fractionAt(details.localPosition.dx, width)),
                  onHorizontalDragUpdate: (details) => setState(() => _drag = _fractionAt(details.localPosition.dx, width)),
                  onHorizontalDragEnd: (_) {
                    final drag = _drag;
                    setState(() => _drag = null);
                    if (drag != null) _seek(drag);
                  },
                  onHorizontalDragCancel: () => setState(() => _drag = null),
                  child: CustomPaint(
                    painter: _BarPainter(
                      played: played,
                      buffered: _fractionOf(widget.buffered),
                      segments: [for (final s in widget.segments) (_fractionOf(s.start), _fractionOf(s.end), s.color)],
                      chapters: [for (final start in widget.chapterStarts) if (start > Duration.zero) _fractionOf(start)],
                      pointer: pointer,
                      color: widget.color,
                      active: pointer != null,
                    ),
                  ),
                ),
              ),
            ),
            if (pointer != null && widget.total > Duration.zero) _label(pointer, width),
          ]),
        );
      });

  Widget _label(double pointer, double width) {
    final text = (widget.labelOf ?? _clock)(_timeAt(pointer));
    const style = TextStyle(color: Colors.white, fontSize: 12);
    final painter = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout(maxWidth: 320);
    final labelWidth = painter.width + 16;
    painter.dispose();
    final preview = widget.preview;
    final boxWidth = max(labelWidth, preview?.size.width ?? 0);
    final heat = widget.heatmap != null ? VideoProgressBar.heatmapHeight : 0.0;
    return Positioned(
      left: (pointer * width - boxWidth / 2).clamp(0.0, width - boxWidth < 0 ? 0.0 : width - boxWidth),
      bottom: VideoProgressBar.height + 4 + heat,
      child: IgnorePointer(
        child: SizedBox(
          width: boxWidth,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (preview != null)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(border: Border.all(color: Colors.white70), borderRadius: BorderRadius.circular(4)),
                child: ClipRRect(borderRadius: BorderRadius.circular(3), child: SizedBox.fromSize(size: preview.size, child: preview.builder(_timeAt(pointer)))),
              ),
            Container(
              width: labelWidth,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(4)),
              child: Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      ),
    );
  }

  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }
}

class _BarPainter extends CustomPainter {
  const _BarPainter({required this.played, required this.buffered, required this.segments, this.chapters = const [], required this.pointer, required this.color, required this.active});

  final double played;
  final double buffered;
  final List<(double, double, Color)> segments;
  final List<double> chapters;
  final double? pointer;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    const cap = VideoProgressBar.barHeight / 2;
    final barHeight = active ? VideoProgressBar.barHeight + 1.5 : VideoProgressBar.barHeight;
    final centerY = size.height / 2;
    final top = centerY - barHeight / 2;
    void bar(double from, double to, Color color) {
      if (to <= from) return;
      canvas.drawRRect(
        RRect.fromLTRBR(from * size.width, top, to * size.width, top + barHeight, const Radius.circular(cap)),
        Paint()..color = color,
      );
    }

    bar(0, 1, const Color(0x33FFFFFF));
    bar(0, buffered, color.withValues(alpha: 0.4));
    for (final (start, end, segmentColor) in segments) {
      bar(start, end, segmentColor);
    }
    bar(0, played, color);
    // Chapter gaps across the bar, as on YouTube.
    final divider = Paint()..color = const Color(0xCC000000);
    for (final chapter in chapters) {
      final x = chapter * size.width;
      canvas.drawRect(Rect.fromLTRB(x - 1, top - 0.5, x + 1, top + barHeight + 0.5), divider);
    }
    canvas.drawCircle(Offset(played * size.width, centerY), active ? 7 : 5.5, Paint()..color = color);

    // PiliNara's hover marker: two small triangles pointing at the bar.
    final value = pointer;
    if (value == null) return;
    final dx = value * size.width;
    const half = 4.5;
    const height = 5.0;
    const gap = 4.0;
    final paint = Paint()..color = color;
    canvas
      ..drawPath(
        Path()
          ..moveTo(dx - half, centerY - gap - height)
          ..lineTo(dx + half, centerY - gap - height)
          ..lineTo(dx, centerY - gap)
          ..close(),
        paint,
      )
      ..drawPath(
        Path()
          ..moveTo(dx - half, centerY + gap + height)
          ..lineTo(dx + half, centerY + gap + height)
          ..lineTo(dx, centerY + gap)
          ..close(),
        paint,
      );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.played != played || old.buffered != buffered || old.pointer != pointer || old.color != color || old.active != active || !listEquals(old.segments, segments) || !listEquals(old.chapters, chapters);
}

/// The "most replayed" curve: a smooth filled area, faint enough to leave
/// the bar readable.
class _HeatmapPainter extends CustomPainter {
  const _HeatmapPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    final peak = values.reduce(max);
    if (n < 2 || peak <= 0) return;
    Offset point(int i) => Offset(i / (n - 1) * size.width, size.height - (values[i] / peak).clamp(0.0, 1.0) * (size.height - 1) - 1);
    final line = Path()..moveTo(0, point(0).dy);
    for (var i = 1; i < n; i++) {
      final a = point(i - 1), b = point(i);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      line.quadraticBezierTo(a.dx, a.dy, mid.dx, mid.dy);
    }
    line.lineTo(size.width, point(n - 1).dy);
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(area, Paint()..color = Colors.white.withValues(alpha: 0.14))
      ..drawPath(line, Paint()..color = Colors.white.withValues(alpha: 0.3)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) => !identical(old.values, values) || old.color != color;
}
