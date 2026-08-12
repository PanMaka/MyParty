import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Stand-in for the design's repeating diagonal-stripe backgrounds, used
/// everywhere a real photo/video isn't available yet (stories, covers, avatars).
class DiagonalStripePlaceholder extends StatelessWidget {
  final List<Color> colors;
  final String? label;
  final BorderRadius? borderRadius;
  final Widget? child;
  final AlignmentGeometry childAlignment;

  const DiagonalStripePlaceholder({
    super.key,
    this.colors = const [Color(0xFF1A1522), Color(0xFF141020)],
    this.label,
    this.borderRadius,
    this.child,
    this.childAlignment = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: CustomPaint(
        painter: _StripePainter(colors[0], colors.length > 1 ? colors[1] : colors[0]),
        child: Container(
          alignment: childAlignment,
          padding: const EdgeInsets.all(8),
          child: child ??
              (label != null
                  ? Text(
                      label!,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono(
                        size: 9,
                        weight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                    )
                  : null),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  final Color colorA;
  final Color colorB;

  const _StripePainter(this.colorA, this.colorB);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colorA);
    final diag = size.longestSide * 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-0.61);
    final paint = Paint()..color = colorB;
    const stripe = 9.0;
    for (double x = -diag; x < diag; x += stripe * 2) {
      canvas.drawRect(Rect.fromLTWH(x, -diag, stripe, diag * 2), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StripePainter oldDelegate) =>
      oldDelegate.colorA != colorA || oldDelegate.colorB != colorB;
}
