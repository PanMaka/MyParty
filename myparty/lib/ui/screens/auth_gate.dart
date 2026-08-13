import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login_screen.dart';
import 'home_screen.dart';
import 'username_setup_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // StreamBuilder constantly listens for changes in the authentication state
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // Show a loading spinner while waiting for Supabase to respond
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _LoadingScaffold();
        }

        // Check if there is a valid user session
        final session = snapshot.hasData ? snapshot.data!.session : null;

        if (session != null) {
          // User is logged in: still need to know if they've picked a
          // username yet before deciding where to send them.
          return _ProfileGate(userId: session.user.id);
        } else {
          // User is NOT logged in, send them to the Login Screen
          return const LoginScreen();
        }
      },
    );
  }
}

/// Routes a logged-in user to [UsernameSetupScreen] or [HomeScreen]
/// depending on whether `profiles.onboarding_completed_at` is set.
class _ProfileGate extends StatefulWidget {
  const _ProfileGate({required this.userId});

  final String userId;

  @override
  State<_ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<_ProfileGate> {
  late final Future<bool> _needsUsername = _checkOnboarding();

  Future<bool> _checkOnboarding() async {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('onboarding_completed_at')
        .eq('id', widget.userId)
        .single();
    return row['onboarding_completed_at'] == null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsUsername,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const _LoadingScaffold();
        }
        return snapshot.data! ? const UsernameSetupScreen() : const HomeScreen();
      },
    );
  }
}

class _LoadingScaffold extends StatelessWidget {
  const _LoadingScaffold();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}