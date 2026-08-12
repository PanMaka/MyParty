import 'package:flutter/material.dart';

/// Small overlapping avatar circles, optionally followed by a caption.
class AvatarStack extends StatelessWidget {
  final List<Color> colors;
  final double size;
  final String? caption;
  final TextStyle? captionStyle;

  const AvatarStack({
    super.key,
    this.colors = const [Color(0xFF2A2340), Color(0xFF3A2A3C), Color(0xFF232C40)],
    this.size = 21,
    this.caption,
    this.captionStyle,
  });

  @override
  Widget build(BuildContext context) {
    final overlap = size * 0.33;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size + overlap * (colors.length - 1),
          height: size,
          child: Stack(
            children: [
              for (var i = 0; i < colors.length; i++)
                Positioned(
                  left: i * overlap,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: colors[i],
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0B0A10), width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (caption != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              caption!,
              style: captionStyle ??
                  const TextStyle(color: Color(0x8CF4F1F8), fontSize: 11.5, height: 1.35),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
