import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/age.dart';
import '../utils/auth_link.dart';
import 'notifications.dart';
import 'reset_request_store.dart';

/// Why an emailed code was refused.
enum CodeFailure {
  /// Wrong, already used, superseded by a newer code, or past its hour.
  /// GoTrue answers all four with one error (`otp_expired`, measured).
  wrongOrExpired,
  rateLimited,
}

class CodeException implements Exception {
  const CodeException(this.failure);

  final CodeFailure failure;

  @override
  String toString() => 'CodeException(${failure.name})';
}

/// Why [AuthService.requestEmailChange] was refused.
enum EmailChangeFailure {
  wrongCurrentPassword,
  sameEmail,
  invalidEmail,
  emailTaken,
  rateLimited,
  notSignedIn,
}

class EmailChangeException implements Exception {
  const EmailChangeException(this.failure);

  final EmailChangeFailure failure;

  @override
  String toString() => 'EmailChangeException(${failure.name})';
}

/// Where an email change stands after one code was accepted.
enum EmailChangeProgress { waitingForOtherAddress, completed }

/// What opening a reset link led to.
enum ResetLinkOutcome {
  /// Signed in with a recovery session: ask for the new password now.
  ready,

  /// This phone did not ask for a reset in the last hour, or asked for a
  /// different address. Nothing was exchanged.
  notRequestedHere,

  /// The link was dead (expired, used, or this phone's PKCE secret has since
  /// been replaced by another flow). The code in the email may still work.
  expired,
}

final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// A deliberately loose check: the server is the authority, this only stops
/// the obvious typo before a round trip.
bool looksLikeEmail(String value) => _emailShape.hasMatch(value.trim());

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
  AuthService({SupabaseClient? client, ResetRequestStore? resetRequests})
      : _clientOverride = client,
        _resetRequests = resetRequests ?? ResetRequestStore();

  final SupabaseClient? _clientOverride;
  final ResetRequestStore _resetRequests;

  /// Resolved lazily so a test double can subclass this without an initialized
  /// Supabase, which does not exist under `flutter test` — same as
  /// [ProfileRepository].
  SupabaseClient get _supabase => _clientOverride ?? Supabase.instance.client;

  /// The signed-in user's email (Settings → Account).
  String? get currentEmail => _supabase.auth.currentUser?.email;

  /// The address an email change is waiting on, or null. As of the last
  /// session refresh: [reloadUser] brings it up to date.
  String? get pendingNewEmail => _supabase.auth.currentUser?.newEmail;

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

  // ---------------------------------------------------------------------------
  // Emailed codes (Phase 47). Sign-up confirmation is ON: GoTrue enforces the
  // double confirmation of an email change only when it is (measured), so it
  // is what makes Change email safe, not only a check on the address.
  // ---------------------------------------------------------------------------

  /// Confirms a new account with the code from its sign-up email. Signs in.
  Future<void> confirmSignUp({required String email, required String code}) async {
    await _verify(email: email, code: code, type: OtpType.signup);
  }

  /// A fresh sign-up code. The previous one stops working (measured).
  Future<void> resendSignUpCode(String email) => _send(() => sendSignUpCode(email.trim()));

  /// Login screen → Forgot password. Sends a code and a link. GoTrue answers
  /// the same for an address with no account (measured), and so does the
  /// screen, so this cannot be used to find out who has one.
  Future<void> requestPasswordReset(String email) async {
    final address = email.trim();
    await _send(() => sendPasswordReset(address));
    await _resetRequests.record(address);
  }

  /// The main path: the code from the reset email. Signs in with a recovery
  /// session, which [setNewPassword] then uses.
  Future<void> verifyResetCode({required String email, required String code}) async {
    await _verify(email: email, code: code, type: OtpType.recovery);
  }

  /// The Android convenience: a reset link, already parsed by `authLinkFrom`
  /// into a bare PKCE code. Exchanged only if this phone asked for a reset for
  /// this address in the last hour, and never over a different signed-in
  /// account. GoTrue would refuse a code from someone else's request anyway
  /// (`bad_code_verifier`); this stops the app from trying.
  Future<ResetLinkOutcome> openResetLink(ResetLink link) async {
    final asked = await _resetRequests.pendingEmail();
    if (asked == null) return ResetLinkOutcome.notRequestedHere;
    final signedIn = currentEmail?.toLowerCase();
    if (signedIn != null && signedIn != asked) return ResetLinkOutcome.notRequestedHere;

    try {
      await exchangeResetCode(link.code);
    } on AuthException {
      return ResetLinkOutcome.expired;
    }
    return ResetLinkOutcome.ready;
  }

  /// The end of a reset: the new password, on the recovery session. No
  /// current password, by definition. Like a change, it ends every other
  /// session.
  Future<void> setNewPassword(String newPassword) async {
    try {
      await writeNewPassword(newPassword);
    } on AuthException catch (e) {
      final failure = switch (e.code) {
        'same_password' => PasswordChangeFailure.samePassword,
        'weak_password' => PasswordChangeFailure.weakPassword,
        'over_request_rate_limit' => PasswordChangeFailure.rateLimited,
        _ => null,
      };
      if (failure == null) rethrow;
      throw PasswordChangeException(failure);
    }
    await _resetRequests.clear();
  }

  /// Leaving a reset before setting the password. The recovery session is a
  /// real session, so it is ended rather than left signed in.
  Future<void> abandonPasswordReset() async {
    await _resetRequests.clear();
    await signOut();
  }

  /// Settings → Account → Email. Asks for the current password first (on the
  /// client only: GoTrue has no server check for this, and the binding
  /// protection is the double confirmation), then sends a code and link to
  /// BOTH addresses. Nothing changes until each has confirmed.
  Future<void> requestEmailChange({required String newEmail, required String currentPassword}) async {
    final email = currentEmail;
    if (email == null) throw const EmailChangeException(EmailChangeFailure.notSignedIn);
    final address = newEmail.trim();
    if (!looksLikeEmail(address)) throw const EmailChangeException(EmailChangeFailure.invalidEmail);
    if (address.toLowerCase() == email.toLowerCase()) {
      throw const EmailChangeException(EmailChangeFailure.sameEmail);
    }
    final bool correct;
    try {
      correct = await verifyPassword(email: email, password: currentPassword);
    } on PasswordChangeException {
      throw const EmailChangeException(EmailChangeFailure.rateLimited);
    }
    if (!correct) throw const EmailChangeException(EmailChangeFailure.wrongCurrentPassword);
    await _writeEmail(address);
  }

  /// Sends both codes again, new ones. GoTrue's own resend for an email change
  /// answers 200 and sends nothing (measured); repeating the request is what
  /// re-sends, and the earlier codes stop working.
  Future<void> resendEmailChange(String newEmail) => _writeEmail(newEmail.trim());

  /// One inbox's code. [address] is the inbox it was sent to: GoTrue checks
  /// the code against that address.
  Future<EmailChangeProgress> confirmEmailChange({required String address, required String code}) async {
    final response = await _verify(email: address, code: code, type: OtpType.emailChange);
    // The first confirmation answers with a message only; the second with a
    // session for the changed account (measured).
    return response.session != null ? EmailChangeProgress.completed : EmailChangeProgress.waitingForOtherAddress;
  }

  /// Re-reads the account from the server, for [currentEmail] and
  /// [pendingNewEmail] after an email-change link or an app resume.
  Future<void> reloadUser() async {
    await refreshAuthSession();
  }

  Future<void> _writeEmail(String address) async {
    try {
      await writeEmail(address);
    } on AuthException catch (e) {
      final failure = switch (e.code) {
        'email_exists' => EmailChangeFailure.emailTaken,
        'email_address_invalid' || 'validation_failed' => EmailChangeFailure.invalidEmail,
        'over_email_send_rate_limit' || 'over_request_rate_limit' => EmailChangeFailure.rateLimited,
        _ => null,
      };
      if (failure == null) rethrow;
      throw EmailChangeException(failure);
    }
  }

  Future<AuthResponse> _verify({required String email, required String code, required OtpType type}) async {
    try {
      return await verifyEmailCode(email: email.trim(), code: code.trim(), type: type);
    } on AuthException catch (e) {
      final failure = _codeFailure(e);
      if (failure == null) rethrow;
      throw CodeException(failure);
    }
  }

  Future<void> _send(Future<void> Function() send) async {
    try {
      await send();
    } on AuthException catch (e) {
      if (_codeFailure(e) == CodeFailure.rateLimited) throw const CodeException(CodeFailure.rateLimited);
      rethrow;
    }
  }

  static CodeFailure? _codeFailure(AuthException e) => switch (e.code) {
        'otp_expired' || 'otp_disabled' => CodeFailure.wrongOrExpired,
        'over_email_send_rate_limit' || 'over_request_rate_limit' => CodeFailure.rateLimited,
        _ => null,
      };

  // The network halves of the above, overridden by test doubles.

  @protected
  Future<AuthResponse> verifyEmailCode({required String email, required String code, required OtpType type}) =>
      _supabase.auth.verifyOTP(email: email, token: code, type: type);

  @protected
  Future<void> sendSignUpCode(String email) async {
    await _supabase.auth.resend(type: OtpType.signup, email: email);
  }

  /// PKCE: supabase_flutter stores this phone's secret for the link. It keeps
  /// one, so a later PKCE flow (a sign-up) replaces it and the link then fails
  /// cleanly; the code still works.
  @protected
  Future<void> sendPasswordReset(String email) =>
      _supabase.auth.resetPasswordForEmail(email, redirectTo: kResetRedirect);

  @protected
  Future<void> exchangeResetCode(String code) async {
    await _supabase.auth.exchangeCodeForSession(code);
  }

  @protected
  Future<void> writeNewPassword(String newPassword) async {
    await _supabase.auth.updateUser(UserAttributes(password: newPassword));
  }

  @protected
  Future<void> writeEmail(String newEmail) async {
    await _supabase.auth.updateUser(UserAttributes(email: newEmail), emailRedirectTo: kEmailChangeRedirect);
  }

  @protected
  Future<void> refreshAuthSession() async {
    await _supabase.auth.refreshSession();
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