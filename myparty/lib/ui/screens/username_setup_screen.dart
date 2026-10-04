import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/profile_repository.dart';
import '../widgets/auth_branding.dart';
import 'home_screen.dart';

class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key, this.repository});

  /// Injectable so the screen builds under `flutter test`; null means the real
  /// [ProfileRepository].
  final ProfileRepository? repository;

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final _usernameController = TextEditingController();
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();
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

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    } on PostgrestException catch (e) {
      setState(() => _errorText = e.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MyParty - Choose a username')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
        child: Column(
          children: [
            const AuthHeader(
              asset: 'assets/images/username_party.png',
              imageScale: 1.0,
              semanticLabel: 'Friends at a party',
              caption: "What's your name? People need it to find you in the party!",
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
    );
  }
}
