import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/host_party_stats.dart';
import '../theme/app_theme.dart';

/// RSVPs over time on the host dashboard: cumulative Going and Interested as
/// two lines, or Coming alone on a private party.
///
/// Going sits on or under Interested at every point, because interested is
/// the superset (20260826093437) — the gap between the lines is the people
/// who are interested but not (yet) going. The lines are never stacked or
/// summed.
///
/// Colours, validated for the dark surface (OKLab ΔE ≥ 14.8 under every CVD
/// simulation, ≥ 5:1 contrast on [AppColors.bg]): Going [AppColors.purple],
/// Interested [AppColors.pink]; Coming [AppColors.private], the app's one
/// colour for private. Two series carry a legend; one does not, because the
/// section title names it.
class RsvpTimelineChart extends StatelessWidget {
  const RsvpTimelineChart({super.key, required this.timeline, required this.isPrivate});

  final RsvpTimeline timeline;
  final bool isPrivate;

  static const goingColor = AppColors.purple;
  static const interestedColor = AppColors.pink;
  static const comingColor = AppColors.private;

  @override
  Widget build(BuildContext context) {
    final points = timeline.points;
    final maxY = points.fold<int>(0, (m, p) => math.max(m, isPrivate ? p.going : p.interested));
    // A little headroom, and never a zero-height axis.
    final top = math.max(4, (maxY * 1.2).ceil()).toDouble();
    final single = points.length == 1;

    LineChartBarData line(List<int> values, Color color) => LineChartBarData(
          spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i].toDouble())],
          color: color,
          barWidth: 2,
          isCurved: false,
          // One bucket draws no line at all, so it needs its marker.
          dotData: FlDotData(
            show: single,
            getDotPainter: (_, _, _, _) => FlDotCirclePainter(
              radius: 4,
              color: color,
              strokeWidth: 2,
              strokeColor: AppColors.sheet,
            ),
          ),
        );

    final bars = isPrivate
        ? [line([for (final p in points) p.going], comingColor)]
        : [
            line([for (final p in points) p.interested], interestedColor),
            line([for (final p in points) p.going], goingColor),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isPrivate) ...[
          Row(
            children: [
              _legend('Going', goingColor, points.last.going),
              const SizedBox(width: 16),
              _legend('Interested', interestedColor, points.last.interested),
            ],
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 180,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: math.max(1, points.length - 1).toDouble(),
              minY: 0,
              maxY: top,
              lineBarsData: bars,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: _yInterval(top),
                getDrawingHorizontalLine: (_) => FlLine(color: Colors.white.withValues(alpha: 0.06), strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: _yInterval(top),
                    getTitlesWidget: (value, meta) => SideTitleWidget(
                      meta: meta,
                      child: Text(value.toInt().toString(), style: _axisStyle),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: _xInterval(points.length),
                    getTitlesWidget: (value, meta) {
                      final i = value.round();
                      if (value != i.toDouble() || i < 0 || i >= points.length) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        child: Text(_bucketLabel(points[i].at), style: _axisStyle),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => const Color(0xFF221E2E),
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      LineTooltipItem(
                        // Text wears text tokens; the coloured line beside it
                        // carries which series this is.
                        '${_seriesName(s.bar.color)} ${s.y.toInt()}'
                        '${identical(s, spots.last) ? '\n${_bucketLabel(points[s.x.toInt()].at, full: true)}' : ''}',
                        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.textAlpha(0.9)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _seriesName(Color? color) {
    if (color == comingColor) return 'Coming';
    if (color == goingColor) return 'Going';
    return 'Interested';
  }

  Widget _legend(String label, Color color, int value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 2, color: color),
        const SizedBox(width: 6),
        Text('$label $value', style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.7))),
      ],
    );
  }

  static double _yInterval(double top) {
    if (top <= 5) return 1;
    return (top / 4).ceilToDouble();
  }

  /// At most ~4 x labels, whatever the series length.
  static double _xInterval(int n) => math.max(1, (n / 4).ceil()).toDouble();

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _bucketLabel(DateTime at, {bool full = false}) {
    final day = '${at.day} ${_months[at.month - 1]}';
    if (timeline.bucket == StatsBucket.day) return day;
    final hour = '${at.hour.toString().padLeft(2, '0')}:00';
    return full ? '$day, $hour' : hour;
  }

  static final _axisStyle = TextStyle(fontSize: 10, color: AppColors.textAlpha(0.45));
}
