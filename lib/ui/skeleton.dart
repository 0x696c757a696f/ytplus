import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shimmer for loading placeholders, adapted from PiliNara's Skeleton.
///
/// Copyright (C) PiliNara contributors.
/// Adapted for Lumtub under GPL-3.0-or-later. Wrap a whole placeholder grid in
/// one Skeleton so a single animation drives every card.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child});
  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(vsync: this)
    ..repeat(min: -0.5, max: 1.5, period: const Duration(milliseconds: 1200));
  final _matrix = Matrix4.identity();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlight = Theme.of(context).colorScheme.surface.withAlpha(60);
    final colors = [Colors.transparent, highlight, highlight, Colors.transparent];
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) {
          _matrix[12] = bounds.width * _controller.value;
          return ui.Gradient.linear(
            Offset(0, 0.35 * bounds.height),
            Offset(bounds.width, 0.95 * bounds.height),
            colors,
            const [0.1, 0.3, 0.5, 0.7],
            TileMode.clamp,
            _matrix.storage,
          );
        },
        child: child,
      ),
    );
  }
}

/// A rounded block in the skeleton colour.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 12, this.radius = 4});
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}
