import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/profile_repository.dart';
import '../../services/auth_service.dart';
import '../widgets/auth_branding.dart';
import 'register_screen.dart';

class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key, this.repository, this.authService, this.onCompleted});

  /// Called once the username is stored. [AuthGate] passes one that swaps its
  /// own child to the home screen.
  ///
  /// The screen deliberately does NOT navigate. It used to
  /// `Navigator.pushReplacement(HomeScreen)`, and since this screen is the
  /// content of AuthGate's route — the app's first route — that REPLACED the
  /// gate. Nothing was left listening to `onAuthStateChange`, so for the rest
  /// of a session that began with sign-up, Sign out cleared the session and
  /// the screen never changed. It also skipped the `PartyLinkHandler` the gate
  /// wraps the home screen in.
  final VoidCallback? onCompleted;

  /// Injectable so the screen builds under `flutter test`; null means the real
  /// [ProfileRepository].
  final ProfileRepository? repository;

  /// Same, for the sign-out behind the back arrow; null means [AuthService].
  final AuthService? authService;

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final _usernameController = TextEditingController();
  late final ProfileRepository _profiles =
      widget.repository ?? ProfileRepository();
  late final AuthService _auth = widget.authService ?? AuthService();
  bool _isLoading = false;
  String? _errorText;

  Future<void> _submit() async {
    final username = _usernameController.text.trim();
    if (username.length < 3) {
      setState(() => _errorText = 'Username must be at least 3 characters');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final available = await _profiles.isUsernameAvailable(username);

      if (!available) {
        setState(() => _errorText = 'That username is already taken');
        return;
      }

      await _profiles.completeOnboarding(username);

      if (mounted) widget.onCompleted?.call();
    } on PostgrestException catch (e) {
      setState(() => _errorText = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// The way out of a half-finished sign-up. Popping alone is not enough:
  /// this screen is AuthGate's answer to "signed in, no username", so while
  /// the session lives the gate would only rebuild it. Signing out swaps the
  /// gate to LoginScreen, and register is pushed on top of that, so its own
  /// back arrow lands on login as usual.
  Future<void> _backToRegister() async {
    if (_isLoading) return;
    final navigator = Navigator.of(context);
    setState(() => _isLoading = true);
    try {
      await _auth.signOut();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    navigator.push(
      MaterialPageRoute(
        builder: (context) => RegisterScreen(authService: widget.authService),
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToRegister();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to sign up',
            onPressed: _isLoading ? null : _backToRegister,
          ),
          title: const Text('MyParty - Choose a username'),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
          child: Column(
            children: [
              const AuthHeader(
                asset: 'assets/images/username_party.png',
                imageScale: 1.0,
                semanticLabel: 'Friends at a party',
                caption:
                    "What's your name? People need it to find you in the party!",
              ),
              const SizedBox(height: 32),
              AuthFieldsBox(
                children: [
                  TextField(
                    controller: _usernameController,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: Colors.white,
                    decoration: InputDecoration(
                      labelText: 'Username',
                      labelStyle: const TextStyle(color: Colors.white70),
                      errorText: _errorText,
                      focusedBorder: const UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white),
                      ),
                    ),
                    autocorrect: false,
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _isLoading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _submit,
                      child: const Text('Continue'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
