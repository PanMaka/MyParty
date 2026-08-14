import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'home_screen.dart';

class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key});

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final _usernameController = TextEditingController();
  final _supabase = Supabase.instance.client;
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
      final available = await _supabase.rpc(
        'check_username_available',
        params: {'p_username': username},
      ) as bool;

      if (!available) {
        setState(() => _errorText = 'That username is already taken');
        return;
      }

      final userId = _supabase.auth.currentUser!.id;
      await _supabase.from('profiles').update({
        'username': username,
        'onboarding_completed_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', userId);

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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Pick a username so your friends can find you.',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
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
