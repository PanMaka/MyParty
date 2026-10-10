import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _isLoading = false;
  DateTime? _dateOfBirth;
  String? _dateOfBirthError;
  Gender? _gender;
  String? _genderError;
  String? _firstNameError;
  String? _lastNameError;
  String? _emailError;
  String? _passwordError;

  static const _missingFirstName = 'Please enter your first name.';
  static const _missingLastName = 'Please enter your last name.';
  static const _missingGender = 'Please choose an option.';
  static const emailTakenMessage =
      'There is already an account that is linked with this email.';

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onDateOfBirthPicked(DateTime dob) {
    setState(() {
      _dateOfBirth = dob;
      _dateOfBirthError = dateOfBirthError(dob);
    });
  }

  Future<void> _register() async {
    // Checked here first so the user gets the red field rather than a
    // round trip; the server's age gate refuses the same cases regardless.
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final password = _passwordController.text;
    final dobError = dateOfBirthError(_dateOfBirth);
    setState(() {
      _emailError = null;
      _passwordError = passwordError(password);
      _firstNameError = firstName.isEmpty ? _missingFirstName : null;
      _lastNameError = lastName.isEmpty ? _missingLastName : null;
      _dateOfBirthError = dobError;
      _genderError = _gender == null ? _missingGender : null;
    });
    if (_firstNameError != null ||
        _lastNameError != null ||
        _passwordError != null ||
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
        firstName: firstName,
        lastName: lastName,
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

  Widget _nameField(
    TextEditingController controller,
    String label,
    String autofillHint,
    String? errorText,
    VoidCallback onEdited,
  ) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      cursorColor: Colors.white,
      textCapitalization: TextCapitalization.words,
      autofillHints: [autofillHint],
      onChanged: (_) {
        if (errorText != null) onEdited();
      },
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
        errorText: errorText,
        errorStyle: authErrorStyle,
        errorBorder: authErrorUnderline,
        focusedErrorBorder: authErrorUnderline,
      ),
    );
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
                _nameField(
                  _firstNameController,
                  'First name',
                  AutofillHints.givenName,
                  _firstNameError,
                  () => setState(() => _firstNameError = null),
                ),
                const SizedBox(height: 16),
                _nameField(
                  _lastNameController,
                  'Last name',
                  AutofillHints.familyName,
                  _lastNameError,
                  () => setState(() => _lastNameError = null),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: Colors.white,
                  onChanged: (_) {
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
                  onChanged: (_) {
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