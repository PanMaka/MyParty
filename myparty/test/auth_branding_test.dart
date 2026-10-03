import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/ui/widgets/auth_branding.dart';

/// The login and register screens themselves construct `AuthService`, which
/// reaches for `Supabase.instance` and so cannot be built here. Everything the
/// two screens share visually lives in these widgets, which can.
Widget _host(Widget child, {double width = 400}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  testWidgets('header shows the logo in a circle and the caption', (tester) async {
    await tester.pumpWidget(_host(const AuthHeader()));

    expect(find.text('Are you ready to party?'), findsOneWidget);

    final logo = tester.widget<Image>(find.byType(Image));
    expect((logo.image as AssetImage).assetName, 'assets/images/content.png');
    expect(find.ancestor(of: find.byType(Image), matching: find.byType(ClipOval)), findsOneWidget);
    expect(find.bySemanticsLabel('MyParty'), findsOneWidget);

    final circle = tester.getSize(find.byType(ClipOval));
    expect(circle.width, circle.height);
  });

  testWidgets('fields box wraps its inputs in a bordered, rounded box', (tester) async {
    await tester.pumpWidget(_host(const AuthFieldsBox(children: [
      TextField(decoration: InputDecoration(labelText: 'Email')),
      TextField(decoration: InputDecoration(labelText: 'Password')),
    ])));

    final box = find.byType(AuthFieldsBox);
    expect(find.descendant(of: box, matching: find.byType(TextField)), findsNWidgets(2));

    final decoration = tester
        .widget<Container>(find.descendant(of: box, matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.borderRadius, isNotNull);
  });

  testWidgets('header and box fit a narrow phone without overflow', (tester) async {
    await tester.pumpWidget(_host(
      const Column(children: [
        AuthHeader(),
        AuthFieldsBox(children: [TextField(), TextField()]),
      ]),
      width: 320,
    ));

    expect(tester.takeException(), isNull);
  });
}
