import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/services/auth_drafts.dart';
import 'package:myparty/services/auth_service.dart';
import 'package:myparty/ui/screens/login_screen.dart';
import 'package:myparty/ui/screens/register_screen.dart';
import 'package:myparty/ui/screens/username_setup_screen.dart';
import 'package:myparty/ui/theme/app_theme.dart';
import 'package:myparty/ui/widgets/auth_branding.dart';

/// Records sign-ins instead of reaching GoTrue.
class _FakeAuthService extends AuthService {
  _FakeAuthService({this.signUpError, this.answerTaken = false});

  /// When set, signUp throws an [AuthException] carrying this code.
  final String? signUpError;

  /// When true, signUp answers the way GoTrue does for a taken email with
  /// confirmation on: a user with no identities, and no error.
  final bool answerTaken;

  final List<String> signIns = [];
  final List<Map<String, Object>> signUps = [];
  int signOuts = 0;
  int abandons = 0;
  final List<(String, String)> savedNames = [];

  /// When true, abandonSignup fails the way the server refuses it.
  bool refuseAbandon = false;

  @override
  Future<void> abandonSignup() async {
    if (refuseAbandon) {
      throw const PostgrestException(message: 'sign-up is already complete', code: '55000');
    }
    abandons++;
  }

  @override
  Future<void> saveNames({required String firstName, required String lastName}) async =>
      savedNames.add((firstName, lastName));

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
    required String gender,
  }) async {
    if (signUpError != null) {
      throw AuthException('refused', statusCode: '422', code: signUpError);
    }
    signUps.add({
      'email': email,
      'password': password,
      'dateOfBirth': dateOfBirth,
      'gender': gender,
    });
    if (answerTaken) {
      return AuthResponse(
        user: User(
          id: 'u',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-10-10T00:00:00Z',
          identities: const [],
        ),
      );
    }
    return AuthResponse();
  }
}

/// Answers the availability check from [taken] and records onboarding writes.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({this.taken = const {}, this.parkOnboarding = true});

  /// When false, completeOnboarding completes and the screen goes on to
  /// navigate — which a test can only allow if it never pumps that far.
  final bool parkOnboarding;

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
    return parkOnboarding ? _parked.future : Future.value();
  }
}

Widget _app(Widget home) => MaterialApp(home: home);

/// Pushes register over a placeholder, so a successful submit has somewhere
/// to pop back to.
Future<void> _openRegister(WidgetTester tester, AuthService auth) async {
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
}

/// Fills every register field with an acceptable value, [password] aside.
Future<void> _fillRegister(WidgetTester tester, {String password = 'Party!Time9'}) async {
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

  await tester.enterText(find.widgetWithText(TextField, 'Email'), 'm@p.gr');
  await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
  await pick(dob('Day'), '9');
  await pick(dob('Month'), 'March');
  await pick(dob('Year'), '${DateTime.now().year - 20}');
  await pick(find.byType(AuthGenderField), 'Prefer not to say');
}

Future<void> _submitRegister(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Create Account'));
  await tester.tap(find.text('Create Account'));
  await tester.pumpAndSettle();
}

InputDecoration _decoration(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.widgetWithText(TextField, label)).decoration!;

String? _errorText(WidgetTester tester, String label) => _decoration(tester, label).errorText;

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
  // The drafts outlive widgets by design, so they would leak between tests.
  setUp(AuthDrafts.instance.clear);

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

    testWidgets('names are not asked here any more: they moved to the username screen',
        (tester) async {
      await tester.pumpWidget(_app(RegisterScreen(authService: _FakeAuthService())));

      expect(find.widgetWithText(TextField, 'First name'), findsNothing);
      expect(find.widgetWithText(TextField, 'Last name'), findsNothing);
    });

    testWidgets('an empty form names every missing field and sends nothing', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(RegisterScreen(authService: auth)));

      await tester.ensureVisible(find.text('Create Account'));
      await tester.tap(find.text('Create Account'));
      await tester.pump();

      expect(find.text('Please enter your date of birth.'), findsOneWidget);
      expect(find.text('Please choose an option.'), findsOneWidget);
      expect(auth.signUps, isEmpty);
    });

    testWidgets('a complete form sends the password untrimmed and the gender value', (tester) async {
      final auth = _FakeAuthService();
      await _openRegister(tester, auth);
      await _fillRegister(tester);

      await _submitRegister(tester);

      expect(auth.signUps, hasLength(1));
      expect(auth.signUps.single['gender'], 'prefer_not_to_say');
      expect(auth.signUps.single['password'], 'Party!Time9');
      expect(auth.signUps.single['dateOfBirth'], DateTime(DateTime.now().year - 20, 3, 9));
    });

    for (final c in [
      ('a password under 9 characters', 'Short!8x', 'The password must be at least 9 characters long'),
      ('a space in the password', 'Party Time9',
          'Only Lowercase, Uppercase letters, Numbers and Punctuation marks are allowed'),
      ('a predictable run of digits', 'Party!Time123',
          'Predictable patterns like "123" is not allowed'),
    ]) {
      testWidgets('${c.$1} is refused under the field and never reaches the server',
          (tester) async {
        final auth = _FakeAuthService();
        await _openRegister(tester, auth);
        await _fillRegister(tester, password: c.$2);

        await _submitRegister(tester);

        expect(find.text(c.$3), findsOneWidget);
        expect(_errorText(tester, 'Password'), c.$3);
        expect(auth.signUps, isEmpty);

        // Typing again clears the complaint.
        await tester.enterText(find.widgetWithText(TextField, 'Password'), 'Party!Time9');
        await tester.pump();
        expect(find.text(c.$3), findsNothing);
      });
    }

    for (final c in [
      ('a refusal from the server', _FakeAuthService(signUpError: 'user_already_exists')),
      ('an identity-less user (email confirmation on)', _FakeAuthService(answerTaken: true)),
    ]) {
      testWidgets('a taken email turns the email field red and says so: ${c.$1}', (tester) async {
        await _openRegister(tester, c.$2);
        await _fillRegister(tester);

        await _submitRegister(tester);

        const message = 'There is already an account that is linked with this email.';
        expect(find.text(message), findsOneWidget);
        expect(_errorText(tester, 'Email'), message);
        final decoration = _decoration(tester, 'Email');
        expect(
          (decoration.errorBorder! as UnderlineInputBorder).borderSide.color,
          AppColors.formError,
        );
        // Still on the register screen: nothing claimed success.
        expect(find.byType(RegisterScreen), findsOneWidget);
        expect(find.text('Registration successful! Please log in.'), findsNothing);
      });
    }

    testWidgets('fits a narrow phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(RegisterScreen(authService: _FakeAuthService())));

      expect(tester.takeException(), isNull);
    });
  });

  group('username setup', () {
    Widget screen(_FakeProfileRepository repo, [_FakeAuthService? auth]) =>
        _app(UsernameSetupScreen(repository: repo, authService: auth ?? _FakeAuthService()));

    Future<void> fillNames(WidgetTester tester) async {
      await tester.enterText(find.widgetWithText(TextField, 'First name'), ' Maria ');
      await tester.enterText(find.widgetWithText(TextField, 'Last name'), ' Papadopoulou ');
    }

    Future<void> submit(WidgetTester tester, String username) async {
      await tester.enterText(find.widgetWithText(TextField, 'Username'), username);
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pump();
    }

    testWidgets('shows the party picture in a circle, its caption and the boxed field', (tester) async {
      await tester.pumpWidget(screen(_FakeProfileRepository()));

      expect(_headerAsset(tester), 'assets/images/username_party.png');
      _expectCircularHeader(tester);
      expect(find.text("What's your name? People need it to find you in the party!"), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AuthFieldsBox), matching: find.widgetWithText(TextField, 'Username')),
        findsOneWidget,
      );
      expect(find.text('Are you ready to party?'), findsNothing);
    });

    testWidgets('first name, last name, the caption, then the username -- in that order',
        (tester) async {
      await tester.pumpWidget(screen(_FakeProfileRepository()));

      const caption = 'And what about the name for people to find you within the app?';
      double top(Finder f) => tester.getTopLeft(f).dy;
      final first = find.widgetWithText(TextField, 'First name');
      final last = find.widgetWithText(TextField, 'Last name');
      final username = find.widgetWithText(TextField, 'Username');
      expect(find.descendant(of: find.byType(AuthFieldsBox), matching: find.text(caption)),
          findsOneWidget);
      expect(top(find.byType(AuthHeader)), lessThan(top(first)));
      expect(top(first), lessThan(top(last)));
      expect(top(last), lessThan(top(find.text(caption))));
      expect(top(find.text(caption)), lessThan(top(username)));
    });

    testWidgets('missing names are named under their fields and nothing is written', (tester) async {
      final repo = _FakeProfileRepository();
      final auth = _FakeAuthService();
      await tester.pumpWidget(screen(repo, auth));

      await submit(tester, 'maria');

      expect(find.text('Please enter your first name.'), findsOneWidget);
      expect(find.text('Please enter your last name.'), findsOneWidget);
      expect(repo.checked, isEmpty);
      expect(auth.savedNames, isEmpty);
    });

    testWidgets('a username under 3 characters never reaches the server', (tester) async {
      final repo = _FakeProfileRepository();
      await tester.pumpWidget(screen(repo));
      await fillNames(tester);

      await submit(tester, 'ab');

      expect(find.text('Username must be at least 3 characters'), findsOneWidget);
      expect(repo.checked, isEmpty);
      expect(repo.onboarded, isEmpty);
    });

    testWidgets('a taken username shows the error and writes nothing', (tester) async {
      final repo = _FakeProfileRepository(taken: {'nikos'});
      final auth = _FakeAuthService();
      await tester.pumpWidget(screen(repo, auth));
      await fillNames(tester);

      await submit(tester, 'nikos');

      expect(find.text('That username is already taken'), findsOneWidget);
      expect(repo.checked, ['nikos']);
      expect(repo.onboarded, isEmpty);
      expect(auth.savedNames, isEmpty);
    });

    testWidgets('a free username is trimmed and written, with the trimmed names', (tester) async {
      final repo = _FakeProfileRepository();
      final auth = _FakeAuthService();
      await tester.pumpWidget(screen(repo, auth));
      await fillNames(tester);

      await submit(tester, ' maria ');

      expect(auth.savedNames, [('Maria', 'Papadopoulou')]);
      expect(repo.onboarded, ['maria']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('the back arrow undoes the sign-up and opens register', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(screen(_FakeProfileRepository(), auth));

      await tester.tap(find.byTooltip('Back to sign up'));
      await tester.pumpAndSettle();

      expect(auth.abandons, 1,
          reason: 'a plain sign-out would leave the email taken by an invisible account');
      expect(find.byType(RegisterScreen), findsOneWidget);
    });

    testWidgets('the system back button does the same, and never pops a bare route', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(screen(_FakeProfileRepository(), auth));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(auth.abandons, 1);
      expect(find.byType(RegisterScreen), findsOneWidget);
    });

    testWidgets('a refused undo stays here and says so, rather than going back', (tester) async {
      final auth = _FakeAuthService()..refuseAbandon = true;
      await tester.pumpWidget(screen(_FakeProfileRepository(), auth));

      await tester.tap(find.byTooltip('Back to sign up'));
      await tester.pumpAndSettle();

      expect(find.byType(RegisterScreen), findsNothing);
      expect(find.byType(UsernameSetupScreen), findsOneWidget);
      expect(find.textContaining('Could not undo the sign-up'), findsOneWidget);
    });

    testWidgets('fits a narrow phone without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(screen(_FakeProfileRepository()));

      expect(tester.takeException(), isNull);
    });
  });

  group('going back keeps what was typed', () {
    testWidgets('username -> register: the register form comes back filled', (tester) async {
      final auth = _FakeAuthService();
      await _openRegister(tester, auth);
      await _fillRegister(tester);
      await _submitRegister(tester);
      expect(auth.signUps, hasLength(1));

      // What AuthGate shows next, and the way back from it.
      await tester.pumpWidget(
        _app(UsernameSetupScreen(repository: _FakeProfileRepository(), authService: auth)),
      );
      await tester.enterText(find.widgetWithText(TextField, 'First name'), 'Maria');
      await tester.enterText(find.widgetWithText(TextField, 'Username'), 'maria');
      await tester.tap(find.byTooltip('Back to sign up'));
      await tester.pumpAndSettle();

      expect(find.byType(RegisterScreen), findsOneWidget);
      expect(find.widgetWithText(TextField, 'm@p.gr'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.widgetWithText(TextField, 'Password')).controller!.text,
        'Party!Time9',
      );
      expect(find.text('9'), findsOneWidget);
      expect(find.text('March'), findsOneWidget);
      expect(find.text('${DateTime.now().year - 20}'), findsOneWidget);
      expect(find.text('Prefer not to say'), findsOneWidget);

      // ...and Create Account goes again with no retyping. (The first submit's
      // snackbar is let go first: it sits over the button.)
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _submitRegister(tester);
      expect(auth.signUps, hasLength(2));
      expect(auth.signUps.last['email'], 'm@p.gr');

      // Forward again: the names and username were kept too.
      await tester.pumpWidget(
        _app(UsernameSetupScreen(repository: _FakeProfileRepository(), authService: auth)),
      );
      expect(find.widgetWithText(TextField, 'Maria'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'maria'), findsOneWidget);
    });

    testWidgets('register -> login: a login that is built anew comes back filled', (tester) async {
      final auth = _FakeAuthService();
      await tester.pumpWidget(_app(LoginScreen(authService: auth)));
      await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@b.gr');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret-pw');

      // A sign-out makes AuthGate build a fresh LoginScreen: a new State.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(LoginScreen(authService: auth)));

      expect(find.widgetWithText(TextField, 'a@b.gr'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.widgetWithText(TextField, 'Password')).controller!.text,
        'secret-pw',
      );
    });

    testWidgets('finishing onboarding forgets everything, password included', (tester) async {
      AuthDrafts.instance
        ..registerPassword = 'Party!Time9'
        ..loginPassword = 'x';
      await tester.pumpWidget(
        _app(UsernameSetupScreen(
          repository: _FakeProfileRepository(parkOnboarding: false),
          authService: _FakeAuthService(),
        )),
      );
      await tester.enterText(find.widgetWithText(TextField, 'First name'), 'Maria');
      await tester.enterText(find.widgetWithText(TextField, 'Last name'), 'P');
      await tester.enterText(find.widgetWithText(TextField, 'Username'), 'maria');
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      // Microtasks only: the clear runs before the push, and pumping a frame
      // would build HomeScreen, which needs a real Supabase.
      await tester.idle();

      expect(AuthDrafts.instance.registerPassword, '');
      expect(AuthDrafts.instance.loginPassword, '');
      expect(AuthDrafts.instance.username, '');
    });
  });
}
