import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/auth_drafts.dart';
import '../../services/auth_service.dart';
import '../widgets/auth_branding.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.authService});

  /// Injectable so the screen builds under `flutter test`; null means the real
  /// [AuthService].
  final AuthService? authService;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Seeded from AuthDrafts: signing out (the username screen's back arrow
  // among others) makes AuthGate build a new LoginScreen, which would
  // otherwise come back empty.
  late final _emailController = TextEditingController(text: AuthDrafts.instance.loginEmail);
  late final _passwordController =
      TextEditingController(text: AuthDrafts.instance.loginPassword);
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      await _authService.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Login successful!')),
        );
        // Later, we will navigate to the Map/Home screen here
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
      appBar: AppBar(title: const Text('MyParty - Login')),
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
                  onChanged: (v) => AuthDrafts.instance.loginEmail = v,
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
                AuthPasswordField(
                  controller: _passwordController,
                  onChanged: (v) => AuthDrafts.instance.loginPassword = v,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _isLoading
                ? const CircularProgressIndicator()
                : ElevatedButton(
                    onPressed: _login,
                    child: const Text('Login'),
                  ),
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => RegisterScreen(authService: widget.authService),
                  ),
                );
              },
              child: const Text('Need an account? Register here'),
            ),
          ],
        ),
      ),
    );
  }
}