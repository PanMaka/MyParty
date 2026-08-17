import 'package:supabase_flutter/supabase_flutter.dart';

import 'notifications.dart';

class AuthService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Sign Up Logic
  Future<AuthResponse> signUp({required String email, required String password}) async {
    return await _supabase.auth.signUp(
      email: email,
      password: password,
    );
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