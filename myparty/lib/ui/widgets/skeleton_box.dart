import 'package:flutter/material.dart';

/// A static placeholder block in the shape of content that is still loading.
///
/// Static on purpose, no shimmer: a repeating animation never lets
/// `pumpAndSettle` settle, and the block only has to say "something goes
/// here". Used where the shape of what is coming is known (the dashboard's
/// tiles and chart). [HostPostStrip] deliberately does NOT use one, for its
/// own reason: most parties have no posts, so it is "photos or nothing".
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, required this.height, this.radius = 12});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
