import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_service.dart';
import '../../utils/age.dart';
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
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _isLoading = false;
  DateTime? _dateOfBirth;
  String? _dateOfBirthError;

  void _onDateOfBirthPicked(DateTime dob) {
    setState(() {
      _dateOfBirth = dob;
      _dateOfBirthError = dateOfBirthError(dob);
    });
  }

  Future<void> _register() async {
    // Checked here first so the user gets the red field rather than a
    // round trip; the server's age gate refuses the same cases regardless.
    final dobError = dateOfBirthError(_dateOfBirth);
    if (dobError != null) {
      setState(() => _dateOfBirthError = dobError);
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _authService.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
        dateOfBirth: _dateOfBirth!,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Registration successful! Please log in.')),
        );
        Navigator.pop(context); // Go back to login screen
      }
    } on AuthException catch (e) {
      if (mounted) {
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
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: Colors.white70),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                AuthPasswordField(controller: _passwordController),
                const SizedBox(height: 24),
                AuthDateOfBirthField(
                  value: _dateOfBirth,
                  onChanged: _onDateOfBirthPicked,
                  errorText: _dateOfBirthError,
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