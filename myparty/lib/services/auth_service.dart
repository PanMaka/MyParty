import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/age.dart';
import 'notifications.dart';

class AuthService {
  AuthService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily so a test double can subclass this without an initialized
  /// Supabase, which does not exist under `flutter test` — same as
  /// [ProfileRepository].
  SupabaseClient get _supabase => _clientOverride ?? Supabase.instance.client;

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
        // Held only in the owner's auth user_metadata for now — no table
        // reads it yet. Not `profiles`: that row is readable by everyone.
        'gender': gender,
      },
    );
  }

  /// First and last name, picked on the username screen. Same home as
  /// `gender`: the owner's user_metadata, which nothing else can read.
  Future<void> saveNames({required String firstName, required String lastName}) async {
    await _supabase.auth.updateUser(
      UserAttributes(data: {'first_name': firstName, 'last_name': lastName}),
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