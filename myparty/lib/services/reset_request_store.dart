import 'package:shared_preferences/shared_preferences.dart';

/// This phone's record that it asked for a password reset, and for which
/// email (Phase 47).
///
/// A reset link is acted on only while this record says so: within the hour
/// the email's code is valid (`otp_expiry`), on the phone that asked. GoTrue
/// already refuses a PKCE code from somebody else's request, because the
/// secret that redeems it lives only on the phone that asked. This record is
/// what keeps the app from even trying, and from replacing a signed-in user's
/// session with a session for another address.
///
/// Persisted, not in memory, because the link usually arrives after the app
/// was closed to open the mail app. Holds an email and a time, never a code.
class ResetRequestStore {
  ResetRequestStore({Future<SharedPreferences> Function()? prefs, DateTime Function()? now})
      : _prefs = prefs ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;

  static const _key = 'password_reset_request';

  /// Matches `otp_expiry` in supabase/config.toml: past it, the link is dead
  /// on the server anyway.
  static const validFor = Duration(hours: 1);

  Future<void> record(String email) async {
    await (await _prefs()).setStringList(_key, [email.trim().toLowerCase(), _now().toUtc().toIso8601String()]);
  }

  /// The email a reset was asked for on this phone in the last hour, or null.
  Future<String?> pendingEmail() async {
    final stored = (await _prefs()).getStringList(_key);
    if (stored == null || stored.length != 2) return null;
    final at = DateTime.tryParse(stored[1]);
    if (at == null || _now().difference(at) > validFor) return null;
    return stored[0];
  }

  Future<void> clear() async {
    await (await _prefs()).remove(_key);
  }
}
