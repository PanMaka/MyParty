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
  final List<Map<String, Object>> signUps = [];
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
    required String firstName,
    required String lastName,
    required String gender,
  }) async {
    signUps.add({
      'email': email,
      'dateOfBirth': dateOfBirth,
      'firstName': firstName,
      'lastName': lastName,
      'gender': gender,
    });
    return AuthResponse();
  }
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
        find.descendant(
          of: find.byType(AuthFieldsBox),
          matching: find.byType(AuthDateOfBirthField),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byType(AuthFieldsBox), matching: find.byType(AuthGenderField)),
        findsOneWidget,
      );
    });

    testWidgets('first and last name are the first fields, right below the picture', (
      tester,
    ) async {
      await tester.pumpWidget(_app(RegisterScreen(authService: _FakeAuthService())));

      final first = find.widgetWithText(TextField, 'First name');
      final last = find.widgetWithText(TextField, 'Last name');
      final email = find.widgetWithText(TextField, 'Email');
      expect(tester.getTopLeft(find.byType(AuthHeader)).dy, lessThan(tester.getTopLeft(first).dy));
      expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(last).dy));
      expect(tester.getTopLeft(last).dy, lessThan(tester.getTopLeft(email).dy));
    });

    testWidgets('an empty form names every missing field and sends nothing', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(RegisterScreen(authService: auth)));

      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pump();

      expect(find.text('Please enter your first name.'), findsOneWidget);
      expect(find.text('Please enter your last name.'), findsOneWidget);
      expect(find.text('Please enter your date of birth.'), findsOneWidget);
      expect(find.text('Please choose an option.'), findsOneWidget);
      expect(auth.signUps, isEmpty);
    });

    testWidgets('a complete form sends trimmed names and the gender value', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => RegisterScreen(authService: auth)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Finder dob(String hint) =>
          find.ancestor(of: find.text(hint), matching: find.byType(DropdownButton<int>));

      Future<void> pick(Finder field, String item) async {
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(item).hitTestable(),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text(item).hitTestable().last);
        await tester.pumpAndSettle();
      }

      await tester.enterText(find.widgetWithText(TextField, 'First name'), ' Maria ');
      await tester.enterText(find.widgetWithText(TextField, 'Last name'), ' Papadopoulou ');
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'm@p.gr');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
      await pick(dob('Day'), '9');
      await pick(dob('Month'), 'March');
      await pick(dob('Year'), '${DateTime.now().year - 20}');
      await pick(find.byType(AuthGenderField), 'Prefer not to say');

      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      expect(auth.signUps, hasLength(1));
      expect(auth.signUps.single['firstName'], 'Maria');
      expect(auth.signUps.single['lastName'], 'Papadopoulou');
      expect(auth.signUps.single['gender'], 'prefer_not_to_say');
      expect(auth.signUps.single['dateOfBirth'], DateTime(DateTime.now().year - 20, 3, 9));
    });

    testWidgets('fits a narrow phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(RegisterScreen(authService: _FakeAuthService())));

      expect(tester.takeException(), isNull);
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
