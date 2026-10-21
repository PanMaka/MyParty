import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:myparty/services/auth_service.dart';
import 'package:myparty/services/reset_request_store.dart';
import 'package:myparty/ui/screens/change_email_screen.dart';
import 'package:myparty/ui/screens/change_password_screen.dart';
import 'package:myparty/ui/screens/confirm_email_screen.dart';
import 'package:myparty/ui/screens/forgot_password_screen.dart';
import 'package:myparty/ui/screens/login_screen.dart';
import 'package:myparty/ui/widgets/auth_link_handler.dart';
import 'package:myparty/utils/auth_link.dart';
import 'package:myparty/utils/auth_messages.dart';
import 'package:myparty/utils/password.dart';

const _resetCode = '56237d44-469d-4f57-9a17-633ff098517d';

AuthResponse _signedIn(String email) => AuthResponse(
      session: Session(
        accessToken: 'token',
        tokenType: 'bearer',
        user: User(id: 'u1', appMetadata: const {}, userMetadata: const {}, aud: 'authenticated', createdAt: '', email: email),
      ),
    );

/// Overrides only the network halves of [AuthService], so the real public
/// methods run: error mapping, the reset-request store, the guards.
class _FakeAuth extends AuthService {
  _FakeAuth({this.email, this.pending, ResetRequestStore? store})
      : super(resetRequests: store ?? ResetRequestStore());

  static const correctPassword = 'Current-pass1!';

  String? email;
  String? pending;

  /// Codes the "server" accepts, per (type, address). Email-change codes are
  /// consumed; the second one accepted completes the change.
  final codes = <(OtpType, String), String>{};
  int emailChangeConfirmations = 0;

  String? writeEmailError;
  bool exchangeFails = false;
  String? sendErrorCode;

  final calls = <String>[];

  @override
  String? get currentEmail => email;

  @override
  String? get pendingNewEmail => pending;

  @override
  Future<bool> verifyPassword({required String email, required String password}) async {
    calls.add('verifyPassword');
    return password == correctPassword;
  }

  @override
  Future<AuthResponse> verifyEmailCode({required String email, required String code, required OtpType type}) async {
    calls.add('verify:${type.name}:$email:$code');
    if (codes[(type, email)] != code) throw const AuthApiException('bad', statusCode: '403', code: 'otp_expired');
    codes.remove((type, email));
    if (type == OtpType.emailChange) {
      emailChangeConfirmations++;
      if (emailChangeConfirmations < 2) return AuthResponse();
      this.email = pending;
      pending = null;
      return _signedIn(this.email!);
    }
    this.email = email;
    return _signedIn(email);
  }

  @override
  Future<void> sendSignUpCode(String email) async {
    calls.add('sendSignUpCode:$email');
    if (sendErrorCode != null) throw AuthApiException('limit', statusCode: '429', code: sendErrorCode);
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    calls.add('sendPasswordReset:$email');
    if (sendErrorCode != null) throw AuthApiException('limit', statusCode: '429', code: sendErrorCode);
  }

  @override
  Future<void> exchangeResetCode(String code) async {
    calls.add('exchange:$code');
    if (exchangeFails) throw const AuthApiException('bad', statusCode: '400', code: 'bad_code_verifier');
  }

  @override
  Future<void> writeNewPassword(String newPassword) async => calls.add('writeNewPassword:$newPassword');

  @override
  Future<void> writeEmail(String newEmail) async {
    calls.add('writeEmail:$newEmail');
    if (writeEmailError != null) throw AuthApiException('refused', statusCode: '422', code: writeEmailError);
    pending = newEmail;
    emailChangeConfirmations = 0;
  }

  @override
  Future<void> refreshAuthSession() async => calls.add('refresh');

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required DateTime dateOfBirth,
    required String gender,
  }) async {
    calls.add('signUp:$email');
    return AuthResponse(); // confirmation on: no session
  }

  @override
  Future<AuthResponse> signIn({required String email, required String password}) async {
    calls.add('signIn:$email');
    throw const AuthApiException('Email not confirmed', statusCode: '400', code: 'email_not_confirmed');
  }

  @override
  Future<void> signOut() async => calls.add('signOut');
}

/// A root page under the screen under test, so "pop to the first route" has
/// somewhere to land, the way AuthGate is under every auth screen.
Future<void> _pumpOver(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
          child: const Text('ROOT'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('ROOT'));
  await tester.pumpAndSettle();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('sign-up confirmation', () {
    testWidgets('a wrong code says so; the right one signs in and pops to the root', (tester) async {
      final auth = _FakeAuth()..codes[(OtpType.signup, 'new@example.com')] = '12345670';
      await _pumpOver(tester, ConfirmEmailScreen(email: 'new@example.com', authService: auth));

      await tester.enterText(find.byType(TextField), '1234');
      await _tapText(tester, 'Confirm');
      expect(find.text(codeLengthMessage), findsOneWidget);

      await tester.enterText(find.byType(TextField), '99999999');
      await _tapText(tester, 'Confirm');
      expect(find.text(codeWrongOrExpiredMessage), findsOneWidget);

      await tester.enterText(find.byType(TextField), '12345670');
      await _tapText(tester, 'Confirm');
      expect(find.byType(ConfirmEmailScreen), findsNothing);
      expect(find.text('ROOT'), findsOneWidget);
    });

    testWidgets('the code field takes digits only, at most 8', (tester) async {
      await _pumpOver(tester, ConfirmEmailScreen(email: 'a@b.gr', authService: _FakeAuth()));
      await tester.enterText(find.byType(TextField), '12 34-56ab7890');
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '12345678');
    });

    testWidgets('resend waits out its cooldown, then sends', (tester) async {
      final auth = _FakeAuth();
      await _pumpOver(tester, ConfirmEmailScreen(email: 'a@b.gr', authService: auth));

      expect(find.textContaining('Send a new code ('), findsOneWidget);
      await tester.tap(find.textContaining('Send a new code ('));
      await tester.pump();
      expect(auth.calls.where((c) => c.startsWith('sendSignUpCode')), isEmpty);

      await tester.pump(const Duration(seconds: 61));
      await tester.tap(find.text('Send a new code'));
      await tester.pump();
      expect(auth.calls, contains('sendSignUpCode:a@b.gr'));
    });

    testWidgets('Login with an unconfirmed address opens the code screen and sends a fresh code', (tester) async {
      final auth = _FakeAuth();
      await tester.pumpWidget(MaterialApp(home: LoginScreen(authService: auth)));
      await tester.enterText(_field('Email'), 'late@example.com');
      await tester.enterText(_field('Password'), 'Party!Time9');
      await _tapText(tester, 'Login');

      expect(find.byType(ConfirmEmailScreen), findsOneWidget);
      expect(auth.calls, contains('sendSignUpCode:late@example.com'));
    });
  });

  group('forgot password', () {
    testWidgets('Login offers it, with the typed email carried over', (tester) async {
      await tester.pumpWidget(MaterialApp(home: LoginScreen(authService: _FakeAuth())));
      await tester.enterText(_field('Email'), 'ada@example.com');
      await _tapText(tester, 'Forgot password?');

      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(_field('ada@example.com'), findsOneWidget);
    });

    testWidgets('the whole code path: email, code, new password, back to the root', (tester) async {
      final auth = _FakeAuth()..codes[(OtpType.recovery, 'ada@example.com')] = '24681357';
      await _pumpOver(tester, ForgotPasswordScreen(authService: auth));

      await tester.enterText(_field('Email'), 'not-an-email');
      await _tapText(tester, 'Send code');
      expect(find.text(invalidEmailMessage), findsOneWidget);
      expect(auth.calls, isEmpty);

      await tester.enterText(_field('Email'), 'ada@example.com');
      await _tapText(tester, 'Send code');
      expect(auth.calls, ['sendPasswordReset:ada@example.com']);
      // One sentence whether or not there is an account.
      expect(find.text(resetCodeSentTo('ada@example.com')), findsOneWidget);
      expect(await ResetRequestStore().pendingEmail(), 'ada@example.com', reason: 'this phone asked');

      await tester.enterText(find.byType(TextField), '11111111');
      await _tapText(tester, 'Continue');
      expect(find.text(codeWrongOrExpiredMessage), findsOneWidget);

      await tester.enterText(find.byType(TextField), '24681357');
      await _tapText(tester, 'Continue');
      expect(find.text(newPasswordTitle), findsWidgets);

      await tester.enterText(_field('New password'), 'short');
      await tester.enterText(_field('Confirm new password'), 'short');
      await _tapText(tester, 'Set password');
      expect(find.text(passwordTooShortMessage), findsOneWidget);

      await tester.enterText(_field('New password'), 'Fresh-Pass-9!');
      await tester.enterText(_field('Confirm new password'), 'Fresh-Pass-9?');
      await _tapText(tester, 'Set password');
      expect(find.text(passwordsDontMatchMessage), findsOneWidget);

      await tester.enterText(_field('Confirm new password'), 'Fresh-Pass-9!');
      await _tapText(tester, 'Set password');
      expect(auth.calls.last, 'writeNewPassword:Fresh-Pass-9!');
      expect(find.text('ROOT'), findsOneWidget);
      expect(find.text(passwordChangedMessage), findsOneWidget);
      expect(await ResetRequestStore().pendingEmail(), isNull, reason: 'a finished reset forgets the request');
    });

    testWidgets('a rate-limited send says so and stays on the email step', (tester) async {
      final auth = _FakeAuth()..sendErrorCode = 'over_email_send_rate_limit';
      await _pumpOver(tester, ForgotPasswordScreen(authService: auth, initialEmail: 'ada@example.com'));
      await _tapText(tester, 'Send code');
      expect(find.text(tooManyAttemptsMessage), findsOneWidget);
      expect(find.text('Send code'), findsOneWidget);
    });

    testWidgets('leaving the new-password step signs out the recovery session', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com');
      await _pumpOver(tester, ForgotPasswordScreen(authService: auth, startAtNewPassword: true));

      await _tapText(tester, 'Cancel');
      expect(auth.calls, contains('signOut'));
      expect(find.text('ROOT'), findsOneWidget);
    });

    testWidgets('so does the system back button', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com');
      await _pumpOver(tester, ForgotPasswordScreen(authService: auth, startAtNewPassword: true));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(auth.calls, contains('signOut'));
      expect(find.byType(ForgotPasswordScreen), findsNothing);
    });
  });

  group('AuthLinkHandler', () {
    Future<(ValueNotifier<AuthLink?>, _FakeAuth)> pumpHandler(WidgetTester tester, _FakeAuth auth) async {
      final links = ValueNotifier<AuthLink?>(null);
      await tester.pumpWidget(MaterialApp(
        home: AuthLinkHandler(authService: auth, links: links, child: const Scaffold(body: Text('GATE'))),
      ));
      await tester.pumpAndSettle();
      return (links, auth);
    }

    testWidgets('a reset link this phone asked for opens the new-password step', (tester) async {
      final store = ResetRequestStore();
      await store.record('ada@example.com');
      final (links, auth) = await pumpHandler(tester, _FakeAuth(store: store));

      links.value = const ResetLink(_resetCode);
      await tester.pumpAndSettle();

      expect(auth.calls, ['exchange:$_resetCode']);
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(find.text(newPasswordTitle), findsWidgets);
      expect(links.value, isNull, reason: 'consumed, so it never runs twice');
    });

    testWidgets('a reset link this phone did NOT ask for is refused before any exchange', (tester) async {
      final (links, auth) = await pumpHandler(tester, _FakeAuth());

      links.value = const ResetLink(_resetCode);
      await tester.pumpAndSettle();

      expect(auth.calls, isEmpty, reason: 'nothing is sent to the server at all');
      expect(find.text(resetLinkNotRequestedHere), findsOneWidget);
      expect(find.byType(ForgotPasswordScreen), findsNothing);
    });

    testWidgets('never over a different signed-in account', (tester) async {
      final store = ResetRequestStore();
      await store.record('ada@example.com');
      final (links, auth) = await pumpHandler(tester, _FakeAuth(email: 'someone.else@example.com', store: store));

      links.value = const ResetLink(_resetCode);
      await tester.pumpAndSettle();

      expect(auth.calls, isEmpty);
      expect(find.text(resetLinkNotRequestedHere), findsOneWidget);
    });

    testWidgets('a dead link (exchange refused) points to the code instead', (tester) async {
      final store = ResetRequestStore();
      await store.record('ada@example.com');
      final (links, _) = await pumpHandler(tester, _FakeAuth(store: store)..exchangeFails = true);

      links.value = const ResetLink(_resetCode);
      await tester.pumpAndSettle();
      expect(find.text(resetLinkExpiredMessage), findsOneWidget);

      links.value = const ResetLinkFailed();
      await tester.pumpAndSettle();
      expect(find.text(resetLinkExpiredMessage), findsWidgets);
    });

    testWidgets('an email-change link re-reads the account and says where it stands', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com', pending: 'ada@new.example');
      final (links, _) = await pumpHandler(tester, auth);

      links.value = const EmailChangeLink(confirmedOne: true);
      await tester.pumpAndSettle();
      expect(auth.calls, ['refresh']);
      expect(find.text(emailChangeLinkConfirmedOne), findsOneWidget);

      ScaffoldMessenger.of(tester.element(find.text('GATE'))).clearSnackBars();
      auth
        ..email = 'ada@new.example'
        ..pending = null;
      links.value = const EmailChangeLink();
      await tester.pumpAndSettle();
      expect(find.text(emailChangedMessage('ada@new.example')), findsOneWidget);
    });

    testWidgets('signed out, or a failed email-change link, only explains', (tester) async {
      final auth = _FakeAuth();
      final (links, _) = await pumpHandler(tester, auth);

      links.value = const EmailChangeLink();
      await tester.pumpAndSettle();
      expect(find.text(emailChangeLinkSignedOut), findsOneWidget);

      ScaffoldMessenger.of(tester.element(find.text('GATE'))).clearSnackBars();
      links.value = const EmailChangeLink(failed: true);
      await tester.pumpAndSettle();
      expect(find.text(emailChangeLinkFailed), findsOneWidget);
      expect(auth.calls, isEmpty);
    });
  });

  group('change email', () {
    Future<void> fillAndSend(WidgetTester tester, {String email = 'ada@new.example', String password = 'Current-pass1!'}) async {
      await tester.enterText(find.byKey(changeEmailAddressKey), email);
      await tester.enterText(find.byKey(changeEmailPasswordKey), password);
      await tester.pump();
      await tester.tap(find.byKey(changeEmailSendKey));
      await tester.pumpAndSettle();
    }

    testWidgets('refusals land under the right field, and nothing is sent', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com');
      await _pumpOver(tester, ChangeEmailScreen(auth: auth));

      await fillAndSend(tester, email: 'nope');
      expect(find.text(invalidEmailMessage), findsOneWidget);

      await fillAndSend(tester, email: 'ADA@example.com');
      expect(find.text(sameEmailMessage), findsOneWidget);

      await fillAndSend(tester, password: 'wrong-Pass1!');
      expect(find.text(wrongCurrentPasswordMessage), findsOneWidget);

      expect(auth.calls.where((c) => c.startsWith('writeEmail')), isEmpty);
    });

    testWidgets('an address another account uses is refused by the server', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com')..writeEmailError = 'email_exists';
      await _pumpOver(tester, ChangeEmailScreen(auth: auth));
      await fillAndSend(tester);
      expect(find.text(emailTakenByOtherMessage), findsOneWidget);
    });

    testWidgets('both codes are needed, in either order, and the screen pops with the new address', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com');
      final popped = <Object?>[];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                popped.add(await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChangeEmailScreen(auth: auth)))),
            child: const Text('ROOT'),
          ),
        ),
      ));
      await tester.tap(find.text('ROOT'));
      await tester.pumpAndSettle();

      await fillAndSend(tester);
      expect(auth.calls, ['verifyPassword', 'writeEmail:ada@new.example']);
      expect(find.text(emailChangeCodesSent('ada@example.com', 'ada@new.example')), findsOneWidget);

      auth.codes[(OtpType.emailChange, 'ada@new.example')] = '22222222';
      auth.codes[(OtpType.emailChange, 'ada@example.com')] = '11111111';

      // The NEW address first.
      await tester.enterText(find.byKey(newEmailCodeKey), '00000000');
      await tester.tap(find.byKey(confirmNewEmailKey));
      await tester.pumpAndSettle();
      expect(find.textContaining(emailChangeConfirmedHint), findsOneWidget);

      await tester.enterText(find.byKey(newEmailCodeKey), '22222222');
      await tester.tap(find.byKey(confirmNewEmailKey));
      await tester.pumpAndSettle();
      expect(find.text(emailChangeWaitingMessage), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(popped, isEmpty, reason: 'one confirmation changes nothing');

      await tester.enterText(find.byKey(oldEmailCodeKey), '11111111');
      await tester.tap(find.byKey(confirmOldEmailKey));
      await tester.pumpAndSettle();
      expect(popped, ['ada@new.example']);
    });

    testWidgets('opened while a change is pending, it starts at the codes', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com', pending: 'ada@new.example');
      await _pumpOver(tester, ChangeEmailScreen(auth: auth));

      expect(find.text('ada@new.example'), findsWidgets);
      expect(find.byKey(oldEmailCodeKey), findsOneWidget);
      expect(find.byKey(newEmailCodeKey), findsOneWidget);

      await _tapText(tester, 'Use a different address');
      expect(find.byKey(changeEmailAddressKey), findsOneWidget);
    });

    testWidgets('new codes repeat the request and reopen both rows', (tester) async {
      final auth = _FakeAuth(email: 'ada@example.com', pending: 'ada@new.example');
      auth.codes[(OtpType.emailChange, 'ada@new.example')] = '22222222';
      await _pumpOver(tester, ChangeEmailScreen(auth: auth));

      await tester.enterText(find.byKey(newEmailCodeKey), '22222222');
      await tester.tap(find.byKey(confirmNewEmailKey));
      await tester.pumpAndSettle();
      expect(find.text('Confirmed'), findsOneWidget);

      await tester.pump(const Duration(seconds: 61));
      await _tapText(tester, 'Send new codes');
      expect(auth.calls.last, 'writeEmail:ada@new.example');
      expect(find.text('Confirmed'), findsNothing);
      expect(find.byKey(newEmailCodeKey), findsOneWidget);
    });
  });

  test('looksLikeEmail is loose on purpose', () {
    expect(looksLikeEmail(' ada@example.com '), isTrue);
    expect(looksLikeEmail('ada@example'), isFalse);
    expect(looksLikeEmail('ada example.com'), isFalse);
    expect(minimumPasswordLength, 9);
  });
}
