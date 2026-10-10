import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/profile_repository.dart';
import '../../services/auth_drafts.dart';
import '../../services/auth_service.dart';
import '../widgets/auth_branding.dart';
import 'home_screen.dart';
import 'register_screen.dart';

class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key, this.repository, this.authService});

  /// Injectable so the screen builds under `flutter test`; null means the real
  /// [ProfileRepository].
  final ProfileRepository? repository;

  /// Same, for saving the names and for the undo behind the back arrow; null
  /// means [AuthService].
  final AuthService? authService;

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final _drafts = AuthDrafts.instance;
  late final _firstNameController = TextEditingController(text: _drafts.firstName);
  late final _lastNameController = TextEditingController(text: _drafts.lastName);
  late final _usernameController = TextEditingController(text: _drafts.username);
  late final ProfileRepository _profiles =
      widget.repository ?? ProfileRepository();
  late final AuthService _auth = widget.authService ?? AuthService();
  bool _isLoading = false;
  String? _errorText;
  String? _firstNameError;
  String? _lastNameError;

  static const usernameCaption = 'And what about the name for people to find you within the app?';

  Future<void> _submit() async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final username = _usernameController.text.trim();
    setState(() {
      _firstNameError = firstName.isEmpty ? 'Please enter your first name.' : null;
      _lastNameError = lastName.isEmpty ? 'Please enter your last name.' : null;
      _errorText = username.length < 3 ? 'Username must be at least 3 characters' : null;
    });
    if (_firstNameError != null || _lastNameError != null || _errorText != null) return;

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

      // Names first: completeOnboarding is what makes AuthGate stop showing
      // this screen, so anything after it might never run.
      await _auth.saveNames(firstName: firstName, lastName: lastName);
      await _profiles.completeOnboarding(username);
      _drafts.clear();

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    } on PostgrestException catch (e) {
      setState(() => _errorText = e.message);
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// The way out of a half-finished sign-up: UNDOES it. Create Account has
  /// already made the account, so merely signing out would leave its email
  /// taken by an account the user cannot see, and the refilled register form
  /// could never be sent again. [AuthService.abandonSignup] deletes it and
  /// signs out, which swaps AuthGate to LoginScreen; register is pushed on top
  /// of that, refilled from [AuthDrafts], so its own back arrow lands on login.
  ///
  /// If the undo is refused, nothing has changed and the user stays here, told
  /// why — going back with the account still standing is the trap this exists
  /// to remove.
  Future<void> _backToRegister() async {
    if (_isLoading) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isLoading = true);
    try {
      await _auth.abandonSignup();
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not undo the sign-up. Please try again. ($e)')),
      );
      return;
    }
    if (mounted) setState(() => _isLoading = false);
    navigator.push(
      MaterialPageRoute(
        builder: (context) => RegisterScreen(authService: widget.authService),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
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
                    "What's your name? People need it to find you in a party!",
              ),
              const SizedBox(height: 32),
              AuthFieldsBox(
                children: [
                  AuthNameField(
                    controller: _firstNameController,
                    label: 'First name',
                    autofillHint: AutofillHints.givenName,
                    errorText: _firstNameError,
                    onChanged: (v) {
                      _drafts.firstName = v;
                      if (_firstNameError != null) setState(() => _firstNameError = null);
                    },
                  ),
                  const SizedBox(height: 16),
                  AuthNameField(
                    controller: _lastNameController,
                    label: 'Last name',
                    autofillHint: AutofillHints.familyName,
                    errorText: _lastNameError,
                    onChanged: (v) {
                      _drafts.lastName = v;
                      if (_lastNameError != null) setState(() => _lastNameError = null);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const AuthCaption(usernameCaption),
              const SizedBox(height: 20),
              AuthFieldsBox(
                children: [
                  TextField(
                    controller: _usernameController,
                    onChanged: (v) => _drafts.username = v,
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
