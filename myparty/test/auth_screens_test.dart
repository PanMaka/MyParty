import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/login_screen.dart';
import 'package:myparty/ui/screens/register_screen.dart';
import 'package:myparty/ui/screens/username_setup_screen.dart';
import 'package:myparty/ui/widgets/auth_branding.dart';

/// Records sign-ins instead of reaching GoTrue.
class _FakeAuthService extends AuthService {
  final List<String> signIns = [];
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  Future<AuthResponse> signIn({required String email, required String password}) async {
    signIns.add(email);
    return AuthResponse();
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required DateTime dateOfBirth,
  }) async =>
      AuthResponse();
}

/// Answers the availability check from [taken] and records onboarding writes.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({this.taken = const {}});

  final Set<String> taken;
  final List<String> checked = [];
  final List<String> onboarded = [];

  /// Never completes, so a successful submit stops short of navigating to
  /// HomeScreen, which needs a real Supabase.
  final _parked = Completer<void>();

  @override
  Future<bool> isUsernameAvailable(String username) async {
    checked.add(username);
    return !taken.contains(username);
  }

  @override
  Future<void> completeOnboarding(String username) {
    onboarded.add(username);
    return _parked.future;
  }
}

Widget _app(Widget home) => MaterialApp(home: home);

String _headerAsset(WidgetTester tester) {
  final image = tester.widget<Image>(
    find.descendant(of: find.byType(AuthHeader), matching: find.byType(Image)),
  );
  return (image.image as AssetImage).assetName;
}

void _expectCircularHeader(WidgetTester tester) {
  final circle = find.descendant(of: find.byType(AuthHeader), matching: find.byType(ClipOval));
  expect(circle, findsOneWidget);
  final size = tester.getSize(circle);
  expect(size.width, size.height);
}

void main() {
  group('login', () {
    testWidgets('shows the logo in a circle, the caption and the boxed fields', (tester) async {
      await tester.pumpWidget(_app(LoginScreen(authService: _FakeAuthService())));

      expect(_headerAsset(tester), 'assets/images/content.png');
      _expectCircularHeader(tester);
      expect(find.text('Are you ready to party?'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AuthFieldsBox), matching: find.byType(TextField)),
        findsNWidgets(2),
      );
    });

    testWidgets('logs in through the injected AuthService', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(LoginScreen(authService: auth)));

      await tester.enterText(find.widgetWithText(TextField, 'Email'), '  a@b.gr ');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
      await tester.pump();

      expect(auth.signIns, ['a@b.gr']);
    });

    testWidgets('"Register here" opens register with the same logo', (tester) async {
      await tester.pumpWidget(_app(LoginScreen(authService: _FakeAuthService())));

      await tester.tap(find.text('Need an account? Register here'));
      await tester.pumpAndSettle();

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(_headerAsset(tester), 'assets/images/content.png');
    });
  });

  group('register', () {
    testWidgets('shows the logo in a circle, the caption and the boxed fields', (tester) async {
      await tester.pumpWidget(_app(RegisterScreen(authService: _FakeAuthService())));

      expect(_headerAsset(tester), 'assets/images/content.png');
      _expectCircularHeader(tester);
      expect(find.text('Are you ready to party?'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AuthFieldsBox), matching: find.byType(AuthDateOfBirthField)),
        findsOneWidget,
      );
    });
  });

  group('username setup', () {
    testWidgets('shows the party picture in a circle, its caption and the boxed field', (tester) async {
      await tester.pumpWidget(_app(UsernameSetupScreen(repository: _FakeProfileRepository())));

      expect(_headerAsset(tester), 'assets/images/username_party.png');
      _expectCircularHeader(tester);
      expect(find.text("What's your name? People need it to find you in the party!"), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AuthFieldsBox), matching: find.widgetWithText(TextField, 'Username')),
        findsOneWidget,
      );
      expect(find.text('Are you ready to party?'), findsNothing);
    });

    testWidgets('a username under 3 characters never reaches the server', (tester) async {
      final repo = _FakeProfileRepository();
      await tester.pumpWidget(_app(UsernameSetupScreen(repository: repo)));

      await tester.enterText(find.byType(TextField), 'ab');
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(find.text('Username must be at least 3 characters'), findsOneWidget);
      expect(repo.checked, isEmpty);
      expect(repo.onboarded, isEmpty);
    });

    testWidgets('a taken username shows the error and writes nothing', (tester) async {
      final repo = _FakeProfileRepository(taken: {'nikos'});
      await tester.pumpWidget(_app(UsernameSetupScreen(repository: repo)));

      await tester.enterText(find.byType(TextField), 'nikos');
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(find.text('That username is already taken'), findsOneWidget);
      expect(repo.checked, ['nikos']);
      expect(repo.onboarded, isEmpty);
    });

    testWidgets('a free username is trimmed and written', (tester) async {
      final repo = _FakeProfileRepository();
      await tester.pumpWidget(_app(UsernameSetupScreen(repository: repo)));

      await tester.enterText(find.byType(TextField), ' maria ');
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(repo.onboarded, ['maria']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the back arrow signs out and opens register', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(
        UsernameSetupScreen(repository: _FakeProfileRepository(), authService: auth),
      ));

      await tester.tap(find.byTooltip('Back to sign up'));
      await tester.pumpAndSettle();

      expect(auth.signOuts, 1, reason: 'with the session alive AuthGate would only rebuild this screen');
      expect(find.byType(RegisterScreen), findsOneWidget);
    });

    testWidgets('the system back button does the same, and never pops a bare route', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(
        UsernameSetupScreen(repository: _FakeProfileRepository(), authService: auth),
      ));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(auth.signOuts, 1);
      expect(find.byType(RegisterScreen), findsOneWidget);
    });

    testWidgets('fits a narrow phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(UsernameSetupScreen(repository: _FakeProfileRepository())));

      expect(tester.takeException(), isNull);
    });
  });
}
