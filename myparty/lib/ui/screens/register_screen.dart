import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_drafts.dart';
import '../../services/auth_service.dart';
import '../../utils/age.dart';
import '../../utils/password.dart';
import '../widgets/auth_branding.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.authService});

  /// Injectable so the screen builds under `flutter test`; null means the real
  /// [AuthService].
  final AuthService? authService;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // Seeded from, and written back to, AuthDrafts: this screen is rebuilt from
  // scratch whenever the username screen's back arrow brings the user here.
  final _drafts = AuthDrafts.instance;
  late final _emailController = TextEditingController(text: _drafts.registerEmail);
  late final _passwordController = TextEditingController(text: _drafts.registerPassword);
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _isLoading = false;
  late DateTime? _dateOfBirth = _drafts.registerDateOfBirth;
  String? _dateOfBirthError;
  late Gender? _gender = _drafts.registerGender;
  String? _genderError;
  String? _emailError;
  String? _passwordError;

  static const _missingGender = 'Please choose an option.';
  static const emailTakenMessage =
      'There is already an account that is linked with this email.';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onDateOfBirthPicked(DateTime dob) {
    setState(() {
      _dateOfBirth = dob;
      _drafts.registerDateOfBirth = dob;
      _dateOfBirthError = dateOfBirthError(dob);
    });
  }

  Future<void> _register() async {
    // Checked here first so the user gets the red field rather than a
    // round trip; the server's age gate refuses the same cases regardless.
    final password = _passwordController.text;
    final dobError = dateOfBirthError(_dateOfBirth);
    setState(() {
      _emailError = null;
      _passwordError = passwordError(password);
      _dateOfBirthError = dobError;
      _genderError = _gender == null ? _missingGender : null;
    });
    if (_passwordError != null ||
        dobError != null ||
        _genderError != null) {
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await _authService.signUp(
        email: _emailController.text.trim(),
        // Not trimmed: a space is refused above, so trimming could only make
        // the stored password differ from the one that was checked.
        password: password,
        dateOfBirth: _dateOfBirth!,
        gender: _gender!.value,
      );
      // With email confirmation on, GoTrue does not refuse a taken address: it
      // answers with a user that has no identities, so it cannot be told from
      // a real signup by status alone.
      if (response.user != null && (response.user!.identities ?? const []).isEmpty) {
        if (mounted) setState(() => _emailError = emailTakenMessage);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Registration successful! Please log in.')),
        );
        Navigator.pop(context); // Go back to login screen
      }
    } on AuthException catch (e) {
      if (e.code == 'user_already_exists' || e.code == 'email_exists') {
        if (mounted) setState(() => _emailError = emailTakenMessage);
      } else if (e.code == 'weak_password') {
        // The server's minimum_password_length, should it ever outrun ours.
        if (mounted) setState(() => _passwordError = passwordTooShortMessage);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MyParty - Register')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
        child: Column(
          children: [
            const AuthHeader(),
            const SizedBox(height: 32),
            AuthFieldsBox(
              children: [
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  onChanged: (v) {
                    _drafts.registerEmail = v;
                    if (_emailError != null) setState(() => _emailError = null);
                  },
                  decoration: InputDecoration(
                    labelText: 'Email',
                    labelStyle: const TextStyle(color: Colors.white70),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                    errorText: _emailError,
                    errorMaxLines: 3,
                    errorStyle: authErrorStyle,
                    errorBorder: authErrorUnderline,
                    focusedErrorBorder: authErrorUnderline,
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                AuthPasswordField(
                  controller: _passwordController,
                  errorText: _passwordError,
                  onChanged: (v) {
                    _drafts.registerPassword = v;
                    if (_passwordError != null) setState(() => _passwordError = null);
                  },
                ),
                const SizedBox(height: 24),
                AuthDateOfBirthField(
                  value: _dateOfBirth,
                  onChanged: _onDateOfBirthPicked,
                  errorText: _dateOfBirthError,
                ),
                const SizedBox(height: 24),
                AuthGenderField(
                  value: _gender,
                  errorText: _genderError,
                  onChanged: (g) => setState(() {
                    _gender = g;
                    _drafts.registerGender = g;
                    _genderError = null;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _register,
                    child: const Text('Create Account'),
                  ),
          ],
        ),
      ),
    );
  }
}