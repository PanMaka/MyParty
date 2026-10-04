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

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(obscured(), isTrue);
    expect(controller.text, 'secret', reason: 'toggling never touches the value');
  });

  testWidgets('date of birth: tapping opens a calendar, and a pick is reported', (tester) async {
    DateTime? picked;
    await tester.pumpWidget(_host(AuthDateOfBirthField(value: null, onChanged: (d) => picked = d)));

    await tester.tap(find.byType(AuthDateOfBirthField));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, isNotNull);
  });

  testWidgets('date of birth: shows dd/MM/yyyy, and no error by default', (tester) async {
    await tester.pumpWidget(_host(AuthDateOfBirthField(value: DateTime(2001, 3, 9), onChanged: (_) {})));

    expect(find.text('09/03/2001'), findsOneWidget);
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
