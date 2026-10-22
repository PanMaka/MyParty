import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/notifications.dart';
import '../widgets/party_link_handler.dart';
import 'login_screen.dart';
import 'name_notice_screen.dart';
import 'home_screen.dart';
import 'pending_deletion_screen.dart';
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
          return ProfileGate(userId: session.user.id);
        } else {
          // Sign-out is triggered from Settings and the account-deletion
          // screen, which are pushed ON TOP of this route. Swapping this route
          // to LoginScreen happens underneath them, so without the pop the
          // session is gone and the user is still looking at Settings.
          // Only on signedOut: other session-less events (e.g. a sign-up
          // awaiting email confirmation) must not pop RegisterScreen.
          if (snapshot.data?.event == AuthChangeEvent.signedOut) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          // User is NOT logged in, send them to the Login Screen
          return const LoginScreen();
        }
      },
    );
  }
}

/// The slice of the caller's own `profiles` row the gate decides on.
@visibleForTesting
class ProfileGateRow {
  const ProfileGateRow({
    required this.onboarded,
    required this.pushConsent,
    required this.locationConsent,
    this.notificationTz,
    this.deletionRequestedAt,
    this.unshownName,
  });

  /// [names] is the `get_my_names` row, if any.
  factory ProfileGateRow.fromRow(Map<String, dynamic> row, {Map<String, dynamic>? names}) {
    final deletedAt = row['deleted_at'] as String?;
    return ProfileGateRow(
      onboarded: row['onboarding_completed_at'] != null,
      pushConsent: (row['push_consent'] as bool?) ?? false,
      locationConsent: (row['location_consent'] as bool?) ?? false,
      notificationTz: row['notification_tz'] as String?,
      deletionRequestedAt: deletedAt == null ? null : DateTime.parse(deletedAt).toLocal(),
      unshownName: names == null || names['shown'] == true
          ? null
          : '${names['first_name']} ${names['last_name']}',
    );
  }

  final bool onboarded;
  final bool pushConsent;
  final bool locationConsent;
  final String? notificationTz;

  /// `profiles.deleted_at`: non-null while the account is in its grace period.
  final DateTime? deletionRequestedAt;

  /// "First Last" while the Phase 49 notice is owed: a name stored before
  /// names became public, which stays owner-only until the user answers.
  /// Null when there is no name or it is already shown.
  final String? unshownName;
}

typedef ProfileGateLoader = Future<ProfileGateRow> Function(String userId);
typedef SignedInHook = Future<void> Function(ProfileGateRow row);

/// Through `get_my_settings`, not a select on `profiles`: since Phase 45
/// (20261021121734) these columns are owner-only, and a grant cannot say
/// "your own row", so nobody reads them off the table. The function reads the
/// session's own row; [userId] is the session's user by construction.
///
/// `get_my_names` rides along for the Phase 49 notice: `shown_at` is not
/// client-readable either.
Future<ProfileGateRow> _loadGateRow(String userId) async {
  final client = Supabase.instance.client;
  final (row, names) = await (
    client.rpc('get_my_settings').single(),
    client.rpc('get_my_names').maybeSingle(),
  ).wait;
  return ProfileGateRow.fromRow(row, names: names);
}

Future<void> _notificationsSignedIn(ProfileGateRow row) => Notifications.onSignedIn(
      pushConsent: row.pushConsent,
      locationConsent: row.locationConsent,
      notificationTz: row.notificationTz,
    );

/// Routes a logged-in user to [PendingDeletionScreen], [UsernameSetupScreen],
/// [NameNoticeScreen] or [HomeScreen], in that order of precedence.
///
/// Public, with injectable seams, only so the routing can be widget-tested:
/// [load], [onSignedIn] and [home] default to the real Supabase read, the real
/// [Notifications] wiring and the real [HomeScreen].
@visibleForTesting
class ProfileGate extends StatefulWidget {
  const ProfileGate({
    super.key,
    required this.userId,
    this.load = _loadGateRow,
    this.onSignedIn = _notificationsSignedIn,
    this.home,
    this.pendingDeletion,
    this.nameNotice,
  });

  final String userId;
  final ProfileGateLoader load;
  final SignedInHook onSignedIn;
  final WidgetBuilder? home;

  /// Builds the pending-deletion screen; tests swap in one with a fake
  /// repository. The callback is the gate's re-check.
  final Widget Function(DateTime requestedAt, VoidCallback onRestored)? pendingDeletion;

  /// Builds the Phase 49 name notice; tests swap in one with a fake
  /// repository. The callback lets the user through.
  final Widget Function(String name, VoidCallback onAnswered)? nameNotice;

  @override
  State<ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<ProfileGate> {
  late Future<ProfileGateRow> _row = _check();

  Future<ProfileGateRow> _check() async {
    final row = await widget.load(widget.userId);

    // Phase 7c. The one place in the app that knows a session exists, which
    // is the earliest point a device row should be written. Both flags (and,
    // since Phase 43, the stored time zone) come from this one read and are
    // passed down rather than re-queried. Nothing is prompted: a user who has
    // never granted push consent is left alone until they open settings.
    //
    // Phase 43: NOT for an account with a pending deletion. It has no device
    // rows and both consents are off, and until the user says "restore" there
    // is nothing for it to do. Restoring re-runs this check, which is when it
    // fires.
    if (row.deletionRequestedAt == null) unawaited(widget.onSignedIn(row));

    return row;
  }

  void _recheck() => setState(() {
        _row = _check();
      });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ProfileGateRow>(
      future: _row,
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
          return _ProfileGateError(error: snapshot.error!, onRetry: _recheck);
        }
        final row = snapshot.data!;

        // Before onboarding, deliberately: an account inside its grace period
        // has finished onboarding by definition (deletion is reachable only
        // from Settings), and the question it must answer first is whether it
        // still wants to exist.
        final requestedAt = row.deletionRequestedAt;
        if (requestedAt != null) {
          return widget.pendingDeletion?.call(requestedAt, _recheck) ??
              PendingDeletionScreen(deletionRequestedAt: requestedAt, onRestored: _recheck);
        }

        // After onboarding, which never owes it: a name given there is shown
        // from the start. Before home, because the name stays hidden until
        // this is answered and the answer is the user's, not a default.
        final unshownName = row.unshownName;
        if (row.onboarded && unshownName != null) {
          void answered() => setState(() {
                _row = Future.value(ProfileGateRow(
                  onboarded: true,
                  pushConsent: row.pushConsent,
                  locationConsent: row.locationConsent,
                  notificationTz: row.notificationTz,
                ));
              });
          return widget.nameNotice?.call(unshownName, answered) ??
              NameNoticeScreen(name: unshownName, onAnswered: answered);
        }

        // PartyLinkHandler only around the signed-in, onboarded root: a link
        // opened earlier waits in PartyLinks.pending until this exists.
        return !row.onboarded
            ? UsernameSetupScreen(
                // No re-query: the write just succeeded, and Notifications
                // already ran on the first check.
                onOnboarded: () => setState(() {
                  _row = Future.value(ProfileGateRow(
                    onboarded: true,
                    pushConsent: row.pushConsent,
                    locationConsent: row.locationConsent,
                    notificationTz: row.notificationTz,
                  ));
                }),
              )
            : (widget.home?.call(context) ?? const PartyLinkHandler(child: HomeScreen()));
      },
    );
  }
}

/// Terminal state for [ProfileGate]. Deliberately shows the raw error: the
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
                  'We couldn’t load your profile.',
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
                  child: const Text('Try again'),
                ),
                TextButton(
                  onPressed: () => Supabase.instance.client.auth.signOut(),
                  child: const Text('Sign out'),
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