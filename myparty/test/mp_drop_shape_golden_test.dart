import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/models/map_party_pin.dart';
import 'package:myparty/ui/theme/app_theme.dart';
import 'package:myparty/ui/widgets/mp_drop_shape.dart';
import 'package:myparty/ui/widgets/mp_map_pin.dart';

/// Renders the bubble silhouette at the four sizes that matter, with a
/// crosshair on each apex so the anchor can be checked rather than assumed.
///
/// The golden is the *shape only* — no count. Under `flutter test` there is no
/// real font and text renders in fallback metrics that look nothing like a
/// handset, so including it would make the picture less honest, not more. What
/// is being reviewed here is the outline, the size progression and where the
/// apex lands.
///
/// The chip outline this sheet used to draw is gone with the chip: the marker
/// box is now the bubble exactly, so the box outline alone says everything the
/// two rectangles used to.
class _DropSheet extends StatelessWidget {
  const _DropSheet();

  @override
  Widget build(BuildContext context) {
    final drops = <(String, MpDropGeometry)>[
      ('public · 0', MpDropGeometry.forCount(0)),
      ('public · 25', MpDropGeometry.forCount(25)),
      ('public · 100+', MpDropGeometry.forCount(100)),
      ('private · fixed', MpDropGeometry.private()),
    ];

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: 880,
        height: 210,
        color: const Color(0xFF0B0910),
        child: Stack(
          children: [
            for (var i = 0; i < drops.length; i++)
              Positioned(
                left: 40 + i * 200.0 - drops[i].$2.width / 2,
                top: 40,
                width: drops[i].$2.width,
                height: drops[i].$2.height,
                child: CustomPaint(
                  painter: MpDropPainter(
                    geometry: drops[i].$2,
                    accent: drops[i].$2.isPrivate ? AppColors.pink : AppColors.purple,
                    fill: const Color(0xFF0E0C14),
                  ),
                ),
              ),

            // THE CONTENT BUDGET, drawn to scale: the largest square that
            // fits inside the body circle. Only the count lives in here now --
            // the thumbnail and the title are gone -- and at the smallest
            // public size it is a ~22px box holding at most two digits, which
            // is the whole argument for moving the label inside.
            for (var i = 0; i < drops.length; i++)
              Positioned(
                left: 40 + i * 200.0 - drops[i].$2.contentExtent / 2,
                top: 40 + drops[i].$2.radius - drops[i].$2.contentExtent / 2,
                width: drops[i].$2.contentExtent,
                height: drops[i].$2.contentExtent,
                child: const _ContentBox(),
              ),

            // THE MARKER BOX, to scale. It used to be worth drawing next to a
            // chip outline to show the two pieces sitting in one box; now it
            // is worth drawing because it should be invisible — the box and
            // the bubble are the same rectangle, and any gap between them is
            // slack the anchor would be wrong by.
            for (var i = 0; i < drops.length; i++)
              Positioned.fromRect(
                rect: (Offset.zero & Size(_metrics[i].width, _metrics[i].height))
                    .shift(_origin(i) - _metrics[i].tip),
                child: const _Outline(Color(0x33FFFFFF)),
              ),

            // The anchor. Every apex must land on the SAME y, whatever the
            // bubble's size -- that is the property the shape exists for, and
            // the one a size change can silently break.
            for (var i = 0; i < drops.length; i++)
              Positioned(
                left: 40 + i * 200.0 - 6,
                top: 40 + drops[i].$2.height - 6,
                width: 12,
                height: 12,
                child: const _Crosshair(),
              ),
          ],
        ),
      ),
    );
  }
}

/// The full metrics for the same four states, so the chip and box outlines
/// come from the SHIPPING geometry rather than from numbers retyped here.
final _metrics = <MpPinMetrics>[
  MpPinMetrics.forCount(0),
  MpPinMetrics.forCount(25),
  MpPinMetrics.forCount(100),
  MpPinMetrics.private(),
];

/// Where the coordinate sits for column [i] -- the same anchor line the bubbles
/// are laid out against.
Offset _origin(int i) => Offset(40 + i * 200.0, 40 + _metrics[i].drop.height);

class _Outline extends StatelessWidget {
  const _Outline(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) =>
      DecoratedBox(decoration: BoxDecoration(border: Border.all(color: color)));
}

class _ContentBox extends StatelessWidget {
  const _ContentBox();

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0x66FFFFFF)),
        ),
      );
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _CrosshairPainter());
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF00E5A0)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), p);
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void main() {
  testWidgets('the bubble at min / mid / max public size and fixed private', (tester) async {
    // Size the surface to the sheet so the golden is the drawing and not a
    // drawing in the corner of an 800x600 page.
    tester.view.physicalSize = const Size(880 * 3, 210 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const _DropSheet());
    await expectLater(
      find.byType(_DropSheet),
      matchesGoldenFile('goldens/mp_bubble_shapes.png'),
    );
  });

  group('MpDropGeometry', () {
    test('a private drop is identical at every count, and never reads one', () {
      // THE CONTROL FOR THE FIXED SIZE. Five counts spanning the whole public
      // range, including both sides of the saturation point. If any of them
      // moved the radius, the private branch would be reading a number it must
      // not read.
      final radii = <double>{
        for (final count in [0, 1, 99, 100, 5000])
          MpDropGeometry.forPin(
            MapPartyPin(
              id: 'p',
              lat: 0,
              lng: 0,
              title: 'x',
              isPrivate: true,
              goingCount: count,
              interestedCount: count,
              startsAt: DateTime(2026, 1, 1),
              endsAt: DateTime(2036, 1, 1),
            ),
            DateTime(2026, 6, 1),
          ).radius,
      };

      expect(radii, hasLength(1));
      expect(radii.single, MpDropGeometry.maxRadius);
    });

    test('a public drop grows with the count and saturates', () {
      final r0 = MpDropGeometry.forCount(0).radius;
      final r25 = MpDropGeometry.forCount(25).radius;
      final r100 = MpDropGeometry.forCount(100).radius;
      final r5000 = MpDropGeometry.forCount(5000).radius;

      expect(r0, MpDropGeometry.minRadius);
      expect(r25, greaterThan(r0));
      expect(r100, greaterThan(r25));
      expect(r100, MpDropGeometry.maxRadius);
      // Saturated, not merely slowed: the map draws up to 200 of these.
      expect(r5000, r100);
    });

    test('the tip is at the bottom centre of the box at every size', () {
      for (final count in [0, 25, 100]) {
        final g = MpDropGeometry.forCount(count);
        expect(g.tip.dy, g.height);
        expect(g.tip.dx, g.width / 2);
      }
      final priv = MpDropGeometry.private();
      expect(priv.tip.dy, priv.height);
      expect(priv.tip.dx, priv.width / 2);
    });

    test('the outline stays inside the box it declares, and fills it', () {
      // The marker box is declared per Marker up front and nothing clips the
      // child to it, so an outline wider than `width` paints over its
      // neighbours and one taller than `height` moves the tip off the
      // coordinate.
      //
      // SAMPLED ALONG THE CURVE, not read off Path.getBounds(). getBounds()
      // returns the control hull of the cubics Skia approximates the arc with,
      // which for a 234-degree sweep bulges well outside the arc itself -- it
      // reported left = -5.5 on a shape whose leftmost drawn point is 0. A
      // conservative bound is the right answer to a different question; this
      // one is about what is painted.
      for (final g in [
        MpDropGeometry.forCount(0),
        MpDropGeometry.forCount(100),
        MpDropGeometry.private(),
      ]) {
        final metric = g.build().computeMetrics().single;
        var minX = double.infinity, maxX = -double.infinity;
        var minY = double.infinity, maxY = -double.infinity;
        // Sampled at a fixed ~0.05px spacing rather than a fixed COUNT, so
        // the resolution does not silently degrade on the larger drops -- the
        // extremes here are the tip, a sharp corner, where the error is the
        // sample spacing times the flank's dy/ds (~0.89) rather than the
        // vanishing second-order error of a smooth extremum. At 720 fixed
        // samples the r=36 drop reported its tip 0.15px short.
        final samples = (metric.length * 20).ceil();
        for (var i = 0; i <= samples; i++) {
          final p = metric.getTangentForOffset(metric.length * i / samples)!.position;
          minX = math.min(minX, p.dx);
          maxX = math.max(maxX, p.dx);
          minY = math.min(minY, p.dy);
          maxY = math.max(maxY, p.dy);
        }

        expect(minX, greaterThanOrEqualTo(-0.01), reason: 'left of the box');
        expect(minY, greaterThanOrEqualTo(-0.01), reason: 'above the box');
        expect(maxX, lessThanOrEqualTo(g.width + 0.01), reason: 'right of the box');
        expect(maxY, lessThanOrEqualTo(g.height + 0.01), reason: 'below the box');

        // And it FILLS the box rather than merely fitting in it -- a shape
        // that fitted with room to spare would put the tip above the
        // coordinate, and the anchor would be a lie by exactly that slack.
        //
        // Tolerance is the sampling resolution, not the shape's error: the
        // containment checks above are one-sided and unaffected by it.
        expect(maxY, closeTo(g.height, 0.05));
        expect(minY, closeTo(0, 0.05));
        expect(maxX - minX, closeTo(g.width, 0.05));
      }
    });
  });
}
