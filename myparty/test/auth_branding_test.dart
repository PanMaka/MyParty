import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myparty/ui/theme/app_theme.dart';
import 'package:myparty/ui/widgets/auth_branding.dart';

/// The shared auth widgets in isolation. The screens that compose them are
/// covered in auth_screens_test.dart.
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

  testWidgets('password eye shows and hides what was typed', (tester) async {
    final controller = TextEditingController(text: 'secret');
    await tester.pumpWidget(_host(AuthPasswordField(controller: controller)));

    bool obscured() => tester.widget<TextField>(find.byType(TextField)).obscureText;

    expect(obscured(), isTrue, reason: 'hidden by default');
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget,
        reason: 'the icon shows the current state: closed eye while hidden');

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget,
        reason: 'open eye while the password is readable');

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(obscured(), isTrue);
    expect(controller.text, 'secret', reason: 'toggling never touches the value');
  });

  Future<void> pick(WidgetTester tester, String hint, String item) async {
    await tester.tap(
      find.ancestor(of: find.text(hint), matching: find.byType(DropdownButton<int>)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(item).hitTestable(),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text(item).hitTestable().last);
    await tester.pumpAndSettle();
  }

  testWidgets('date of birth: day, month and year dropdowns report the date once all are set', (
    tester,
  ) async {
    final picked = <DateTime>[];
    await tester.pumpWidget(
      _host(
        AuthDateOfBirthField(value: null, onChanged: picked.add, today: DateTime(2026, 10, 10)),
      ),
    );

    await pick(tester, 'Day', '9');
    await pick(tester, 'Month', 'March');
    expect(picked, isEmpty);

    // 2001 sits 25 rows down a newest-first list: it has to be reachable
    // without a calendar's year grid.
    await pick(tester, 'Year', '2001');

    expect(picked, [DateTime(2001, 3, 9)]);
  });

  testWidgets('date of birth: a day the new month lacks is clamped, not rolled over', (
    tester,
  ) async {
    DateTime? picked;
    await tester.pumpWidget(
      _host(AuthDateOfBirthField(value: DateTime(2001, 3, 31), onChanged: (d) => picked = d)),
    );

    await pick(tester, 'March', 'February');

    expect(picked, DateTime(2001, 2, 28));
  });

  testWidgets('date of birth: shows the given date, and no error by default', (tester) async {
    await tester.pumpWidget(
      _host(AuthDateOfBirthField(value: DateTime(2001, 3, 9), onChanged: (_) {})),
    );

    expect(find.text('9'), findsOneWidget);
    expect(find.text('March'), findsOneWidget);
    expect(find.text('2001'), findsOneWidget);
    final decoration = tester.widget<InputDecorator>(find.byType(InputDecorator)).decoration;
    expect(decoration.errorText, isNull);
  });

  testWidgets('date of birth: an error turns the outline red and shows the message', (tester) async {
    const message =
        'The Date Of Birth is not on par with the guidelines. You need to be 13+ to own a MyParty Account.';
    await tester.pumpWidget(_host(AuthDateOfBirthField(
      value: DateTime(2020, 1, 1),
      onChanged: (_) {},
      errorText: message,
    )));

    expect(find.text(message), findsOneWidget);
    final decoration = tester.widget<InputDecorator>(find.byType(InputDecorator)).decoration;
    expect((decoration.errorBorder! as OutlineInputBorder).borderSide.color, AppColors.formError);
    expect(decoration.errorStyle!.color, AppColors.formError);
  });

  testWidgets('gender offers the four options and reports the choice', (tester) async {
    Gender? picked;
    await tester.pumpWidget(_host(AuthGenderField(value: null, onChanged: (g) => picked = g)));

    await tester.tap(find.byType(AuthGenderField));
    await tester.pumpAndSettle();
    for (final label in ['Male', 'Female', 'Non-binary', 'Prefer not to say']) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text('Non-binary').last);
    await tester.pumpAndSettle();

    expect(picked, Gender.nonBinary);
    expect(picked!.value, 'non_binary');
  });

  testWidgets('date of birth and gender fit a narrow phone without overflow', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            AuthDateOfBirthField(value: DateTime(2001, 9, 30), onChanged: (_) {}),
            AuthGenderField(value: Gender.preferNotToSay, onChanged: (_) {}),
          ],
        ),
        width: 288,
      ),
    );

    expect(tester.takeException(), isNull);
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
