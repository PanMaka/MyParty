import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/models/host_party_stats.dart';
import 'package:myparty/ui/widgets/gender_mix_bar.dart';

Widget _host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    );

void main() {
  testWidgets('prints every category with its count and percentage', (tester) async {
    await tester.pumpWidget(_host(const GenderMixBar(
      label: 'Going',
      mix: GenderMix(male: 1, female: 2, nonBinary: 1, unspecified: 1),
    )));

    expect(find.text('Going'), findsOneWidget);
    expect(find.text('5 guests'), findsOneWidget);
    expect(find.text('Men 1 · 20%'), findsOneWidget);
    expect(find.text('Women 2 · 40%'), findsOneWidget);
    expect(find.text('Non-binary 1 · 20%'), findsOneWidget);
    expect(find.text('Not specified 1 · 20%'), findsOneWidget);
    expect(find.text(GenderMixBar.notEnough), findsNothing);
  });

  testWidgets('a zero category is still listed, and draws no segment', (tester) async {
    await tester.pumpWidget(_host(const GenderMixBar(
      label: 'Coming',
      mix: GenderMix(male: 1, female: 1, nonBinary: 1, unspecified: 0),
    )));

    expect(find.text('Not specified 0 · 0%'), findsOneWidget);
    // Three fills and the two gaps between them: Expanded only for non-zero.
    final bar = find.descendant(of: find.byType(ClipRRect), matching: find.byType(Expanded));
    expect(bar, findsNWidgets(3));
    // 1/1/1 rounds to 34/33/33, not 33/33/33.
    expect(find.text('Men 1 · 34%'), findsOneWidget);
    expect(find.text('Women 1 · 33%'), findsOneWidget);
  });

  testWidgets('a withheld group says "Not enough guests yet" and shows no numbers', (tester) async {
    await tester.pumpWidget(_host(const GenderMixBar(label: 'Interested', mix: null)));

    expect(find.text('Not enough guests yet'), findsOneWidget);
    expect(find.textContaining('Men'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('guests', findRichText: true), findsOneWidget, reason: 'only the notice');
  });

  testWidgets('fits a narrow phone at a large text scale without overflow', (tester) async {
    for (final mix in [null, const GenderMix(male: 12, female: 30, nonBinary: 3, unspecified: 41)]) {
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: _host(GenderMixBar(label: 'Interested', mix: mix), width: 300),
      ));
      expect(tester.takeException(), isNull);
    }
  });

  group('percentages', () {
    test('always add up to 100', () {
      for (final counts in [
        [1, 1, 1, 0],
        [2, 2, 1, 3],
        [1, 2, 1, 1],
        [7, 0, 0, 0],
        [3, 3, 3, 3],
        [12, 30, 3, 41],
      ]) {
        final p = GenderMixBar.percentages(counts);
        expect(p.fold<int>(0, (a, b) => a + b), 100, reason: '$counts -> $p');
      }
    });

    test('a tie goes to the larger count, deterministically', () {
      // 2/8, 2/8, 1/8, 3/8 = 25, 25, 12.5, 37.5: the spare point goes to 3/8.
      expect(GenderMixBar.percentages([2, 2, 1, 3]), [25, 25, 12, 38]);
    });

    test('nothing to divide gives zeros', () {
      expect(GenderMixBar.percentages([0, 0, 0, 0]), [0, 0, 0, 0]);
    });
  });
}
