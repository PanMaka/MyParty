import 'package:flutter/material.dart';

/// Dashed rounded-rect border, used to mark private-party pins on the map
/// (continuous purple border = public, dashed pink border = private).
class DashedRRectBorder extends StatelessWidget {
  final Widget child;
  final Color color;
  final double radius;
  final double strokeWidth;

  const DashedRRectBorder({
    super.key,
    required this.child,
    required this.color,
    this.radius = 12,
    this.strokeWidth = 1.5,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(color: color, radius: radius, strokeWidth: strokeWidth),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;

  const _DashedRRectPainter({required this.color, required this.radius, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(strokeWidth / 2, strokeWidth / 2, size.width - strokeWidth, size.height - strokeWidth),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final dashed = Path();
    const dashWidth = 4.0;
    const gapWidth = 3.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        dashed.addPath(metric.extractPath(distance, next.clamp(0, metric.length)), Offset.zero);
        distance = next + gapWidth;
      }
    }
    canvas.drawPath(dashed, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = strokeWidth);
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius || oldDelegate.strokeWidth != strokeWidth;
}
