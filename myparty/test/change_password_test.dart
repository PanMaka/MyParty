import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/change_password_screen.dart';
import 'package:myparty/utils/password.dart';

/// Overrides only the two network halves, so the real [AuthService.changePassword]
/// runs: the order of the checks and the mapping of GoTrue's error codes are
/// what is under test, not a fake's copy of them.
class _FakeAuth extends AuthService {
  _FakeAuth({this.currentIsCorrect = true, this.writeError});

  final bool currentIsCorrect;
  final Object? writeError;

  final verified = <String>[];
  final written = <({String current, String next})>[];

  @override
  String? get currentEmail => 'me@example.com';

  @override
  Future<bool> verifyPassword({required String email, required String password}) async {
    verified.add(password);
    return currentIsCorrect;
  }

  @override
  Future<void> writePassword({required String currentPassword, required String newPassword}) async {
    if (writeError != null) throw writeError!;
    written.add((current: currentPassword, next: newPassword));
  }
}

const _current = 'old-Password!';
const _next = 'fresh-Password!';

/// Pushes the screen over a host page and records what it popped with.
Future<List<Object?>> _pump(WidgetTester tester, _FakeAuth auth) async {
  final popped = <Object?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => popped.add(await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => ChangePasswordScreen(auth: auth)),
          )),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return popped;
}

Future<void> _fill(WidgetTester tester, {String current = _current, String next = _next, String? confirm}) async {
  await tester.enterText(find.widgetWithText(TextField, 'Current password'), current);
  await tester.enterText(find.widgetWithText(TextField, 'New password'), next);
  await tester.enterText(find.widgetWithText(TextField, 'Confirm new password'), confirm ?? next);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(changePasswordSubmitKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the button does nothing until all three fields are filled', (tester) async {
    final auth = _FakeAuth();
    await _pump(tester, auth);

    await tester.enterText(find.widgetWithText(TextField, 'Current password'), _current);
    await tester.enterText(find.widgetWithText(TextField, 'New password'), _next);
    await tester.pump();
    await _submit(tester);

    expect(auth.verified, isEmpty);
    expect(find.byType(ChangePasswordScreen), findsOneWidget);
  });

  testWidgets('a success sends the current and the new password, then pops with true', (tester) async {
    final auth = _FakeAuth();
    final popped = await _pump(tester, auth);

    await _fill(tester);
    await _submit(tester);

    expect(auth.verified, [_current], reason: 'the current password is checked first');
    expect(auth.written, [(current: _current, next: _next)],
        reason: 'and sent again with the write, for the server to check where it is configured to');
    expect(popped, [true]);
    expect(find.byType(ChangePasswordScreen), findsNothing);
  });

  testWidgets('says up front that other devices will be signed out', (tester) async {
    await _pump(tester, _FakeAuth());
    expect(find.text("You'll stay signed in here. Your other devices will be signed out."), findsOneWidget);
  });

  group('refused before anything is sent', () {
    testWidgets('a new password that breaks the register rules', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth);

      await _fill(tester, next: 'short1!');
      await _submit(tester);
      expect(find.text(passwordTooShortMessage), findsOneWidget);

      await _fill(tester, next: 'abc123-Password');
      await _submit(tester);
      expect(find.text(passwordPatternMessage), findsOneWidget);

      expect(auth.verified, isEmpty);
    });

    testWidgets('a confirmation that does not match', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth);

      await _fill(tester, confirm: 'fresh-Password?');
      await _submit(tester);

      expect(find.text(passwordsDontMatchMessage), findsOneWidget);
      expect(auth.verified, isEmpty);
    });

    testWidgets('a new password equal to the current one', (tester) async {
      final auth = _FakeAuth();
      await _pump(tester, auth);

      await _fill(tester, next: _current);
      await _submit(tester);

      expect(find.text(samePasswordMessage), findsOneWidget);
      expect(auth.verified, isEmpty);
    });
  });

  testWidgets('a wrong current password is refused before the write, under its own field', (tester) async {
    final auth = _FakeAuth(currentIsCorrect: false);
    final popped = await _pump(tester, auth);

    await _fill(tester);
    await _submit(tester);

    expect(find.text(wrongCurrentPasswordMessage), findsOneWidget);
    expect(auth.written, isEmpty, reason: 'nothing is written when the check fails');
    expect(popped, isEmpty);

    // Typing again clears it.
    await tester.enterText(find.widgetWithText(TextField, 'Current password'), 'retyped-Password!');
    await tester.pump();
    expect(find.text(wrongCurrentPasswordMessage), findsNothing);
  });

  group("the server's refusals land under the right field", () {
    Future<void> refusedWith(WidgetTester tester, String code, String message) async {
      final auth = _FakeAuth(writeError: AuthApiException('refused', statusCode: '422', code: code));
      final popped = await _pump(tester, auth);
      await _fill(tester);
      await _submit(tester);
      expect(find.text(message), findsOneWidget, reason: code);
      expect(popped, isEmpty);
    }

    testWidgets('current_password_invalid (the hosted check)', (tester) async {
      await refusedWith(tester, 'current_password_invalid', wrongCurrentPasswordMessage);
    });

    testWidgets('same_password', (tester) async {
      await refusedWith(tester, 'same_password', samePasswordMessage);
    });

    testWidgets('weak_password', (tester) async {
      await refusedWith(tester, 'weak_password', passwordTooShortMessage);
    });

    testWidgets('over_request_rate_limit', (tester) async {
      await refusedWith(tester, 'over_request_rate_limit', passwordChangeRateLimitedMessage);
    });
  });

  testWidgets('any other failure says so and leaves the form usable', (tester) async {
    final auth = _FakeAuth(writeError: Exception('socket closed'));
    await _pump(tester, auth);

    await _fill(tester);
    await _submit(tester);

    expect(find.text(passwordChangeFailedMessage), findsOneWidget);
    final field = tester.widget<TextField>(find.widgetWithText(TextField, 'Current password'));
    expect(field.enabled, isTrue, reason: 'the busy state is cleared');
  });

  testWidgets('the fields are obscured, and each can be shown', (tester) async {
    await _pump(tester, _FakeAuth());

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(3));
    expect(fields.every((f) => f.obscureText), isTrue);

    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(tester.widgetList<TextField>(find.byType(TextField)).first.obscureText, isFalse);
  });
}
