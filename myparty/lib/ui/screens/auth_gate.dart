import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/notifications.dart';
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
  late Future<bool> _needsUsername = _checkOnboarding();

  Future<bool> _checkOnboarding() async {
    final row = await Supabase.instance.client
        .from('profiles')
        .select('onboarding_completed_at, push_consent, location_consent')
        .eq('id', widget.userId)
        .single();

    // Phase 7c. The one place in the app that knows a session exists AND
    // onboarding is settled, which is the earliest point a device row should
    // be written — `user_devices.user_id` references `profiles`, and
    // registering mid-signup would race the row `handle_new_user` creates.
    //
    // Both flags are read here and passed down rather than re-queried, so this
    // stays one round trip. Nothing is prompted: a user who has never granted
    // push consent is left alone until they open the settings screen.
    unawaited(Notifications.onSignedIn(
      pushConsent: (row['push_consent'] as bool?) ?? false,
      locationConsent: (row['location_consent'] as bool?) ?? false,
    ));

    return row['onboarding_completed_at'] == null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _needsUsername,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LoadingScaffold();
        }
        // A gate that renders a spinner on error strands the user with no
        // navigation and no message — indistinguishable from a slow network,
        // forever. Every failure mode here is one the user cannot act on
        // blindly (backend unreachable, schema behind the client, no profiles
        // row), so show the error and offer the only two useful exits.
        if (snapshot.hasError) {
          return _ProfileGateError(
            error: snapshot.error!,
            onRetry: () => setState(() {
              _needsUsername = _checkOnboarding();
            }),
          );
        }
        return snapshot.data! ? const UsernameSetupScreen() : const HomeScreen();
      },
    );
  }
}

/// Terminal state for [_ProfileGate]. Deliberately shows the raw error: the
/// only people who reach it are a developer pointed at the wrong backend or a
/// user whose profile row is missing, and both need the actual message.
class _ProfileGateError extends StatelessWidget {
  const _ProfileGateError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Δεν μπορέσαμε να φορτώσουμε το προφίλ σου.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Δοκίμασε ξανά'),
                ),
                TextButton(
                  onPressed: () => Supabase.instance.client.auth.signOut(),
                  child: const Text('Αποσύνδεση'),
                ),
              ],
            ),
          ),
        ),
      ),
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