import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/age.dart';
import 'notifications.dart';

/// Why [AuthService.changePassword] was refused, so the screen can put the
/// message under the field it is about.
enum PasswordChangeFailure {
  wrongCurrentPassword,
  samePassword,
  weakPassword,
  rateLimited,
  notSignedIn,
}

class PasswordChangeException implements Exception {
  const PasswordChangeException(this.failure);

  final PasswordChangeFailure failure;

  @override
  String toString() => 'PasswordChangeException(${failure.name})';
}

class AuthService {
  AuthService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily so a test double can subclass this without an initialized
  /// Supabase, which does not exist under `flutter test` — same as
  /// [ProfileRepository].
  SupabaseClient get _supabase => _clientOverride ?? Supabase.instance.client;

  /// The signed-in user's email, for display only (Settings → Account).
  /// Changing it is not offered yet: it needs SMTP and an email-link callback,
  /// and `detectSessionInUri` is off on purpose (see `main.dart`).
  String? get currentEmail => _supabase.auth.currentUser?.email;

  // Sign Up Logic
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required DateTime dateOfBirth,
    required String gender,
  }) async {
    return await _supabase.auth.signUp(
      email: email,
      password: password,
      data: {
        // Read by the before_user_created age gate (which refuses under-13s)
        // and stored by handle_new_user into user_birthdates.
        'date_of_birth': isoDate(dateOfBirth),
        // Copied by handle_new_user into user_genders (owner-read-only; not
        // `profiles`, which everyone can read) and stripped from the metadata
        // by GoTrue's own write-back during sign-up (20261019193257). Nothing
        // reads it from the metadata: Settings goes through ProfileRepository.
        'gender': gender,
      },
    );
  }

  /// The username screen's way back: deletes the account Create Account just
  /// made (abandon_signup, which refuses once onboarding is complete), then
  /// signs out. Without the delete, the email would stay taken by an account
  /// the user cannot see, and the refilled register form could never be sent
  /// again. The sign-out's own server call then answers 403 for the vanished
  /// user, which gotrue ignores, so the local session is still cleared.
  Future<void> abandonSignup() async {
    await _supabase.rpc('abandon_signup');
    await signOut();
  }

  // Sign In Logic
  Future<AuthResponse> signIn({required String email, required String password}) async {
    return await _supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Settings → Account → Password. Needs the current password, checked
  /// twice on purpose:
  ///
  ///  1. Here, by [verifyPassword]. GoTrue ignores `current_password` unless
  ///     the project sets `update_password_require_current_password`, which
  ///     the CLI's config.toml cannot express (measured on the local stack:
  ///     a wrong one was accepted and the password changed). Without this
  ///     check a wrong current password would "work" locally.
  ///  2. By the server, from the `currentPassword` sent with the update, on
  ///     the hosted project where that setting is on. That is the check that
  ///     binds: this one only runs on a client that wants it to, and the point
  ///     of asking is that a stolen session alone cannot change the password.
  ///
  /// On success GoTrue ends every OTHER session of the account and keeps this
  /// one (measured), which the screen tells the user.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final email = currentEmail;
    if (email == null) throw const PasswordChangeException(PasswordChangeFailure.notSignedIn);

    if (!await verifyPassword(email: email, password: currentPassword)) {
      throw const PasswordChangeException(PasswordChangeFailure.wrongCurrentPassword);
    }

    try {
      await writePassword(currentPassword: currentPassword, newPassword: newPassword);
    } on AuthException catch (e) {
      final failure = switch (e.code) {
        'same_password' => PasswordChangeFailure.samePassword,
        'weak_password' => PasswordChangeFailure.weakPassword,
        // `required` cannot happen (it is always sent) but means the same thing.
        'current_password_invalid' || 'current_password_required' => PasswordChangeFailure.wrongCurrentPassword,
        'over_request_rate_limit' => PasswordChangeFailure.rateLimited,
        _ => null,
      };
      if (failure == null) rethrow;
      throw PasswordChangeException(failure);
    }
  }

  /// True if [password] is the account's current password, false if it is
  /// not. Signs in on a THROWAWAY client that persists nothing and does not
  /// refresh, then ends that session at once: signing in on the app's own
  /// client would swap this device's session and leave the old refresh token
  /// valid on the server. The app's auth stream never hears about it.
  @protected
  Future<bool> verifyPassword({required String email, required String password}) async {
    final scratch = GoTrueClient(
      url: '${dotenv.env['SUPABASE_URL']!}/auth/v1',
      // The app client's auth headers: the publishable key only, never a user
      // token (supabase_client.dart builds them once).
      headers: _supabase.auth.headers,
      autoRefreshToken: false,
    );
    try {
      await scratch.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      if (e.code == 'invalid_credentials') return false;
      if (e.code == 'over_request_rate_limit') {
        throw const PasswordChangeException(PasswordChangeFailure.rateLimited);
      }
      rethrow;
    } finally {
      // Best effort. The session is never stored anywhere, and the password
      // change that follows ends it anyway.
      try {
        await scratch.signOut();
      } catch (_) {}
      scratch.dispose();
    }
    return true;
  }

  /// The write itself, on the app's own session.
  @protected
  Future<void> writePassword({required String currentPassword, required String newPassword}) async {
    await _supabase.auth.updateUser(
      UserAttributes(password: newPassword, currentPassword: currentPassword),
    );
  }

  // Sign Out Logic
  Future<void> signOut() async {
    // Phase 7c. The device row goes first, and the order is not cosmetic:
    // `user_devices` is owner-only, so after signOut the delete is refused and
    // the row survives. `push_token` is globally unique, so a stranded row also
    // blocks the next account on this handset from registering — and until FCM
    // rotates the token, the delivery worker keeps sending this user's
    // notifications to a phone somebody else is now holding.
    await Notifications.onSignOut();
    await _supabase.auth.signOut();
  }
}