import 'package:shared_preferences/shared_preferences.dart';

/// The host's own copy of their parties' invite-link tokens, on this device.
///
/// The server keeps only each token's SHA-256 (20261014133500), so a token
/// cannot be fetched again. Keeping it here is what lets the host tap
/// "Copy link" a second time on the phone that made the link. On any other
/// device there is no copy, and the only way to share is a NEW link, which
/// disables the old one — the dashboard says exactly that.
///
/// Stored with the link's `created_at`, and trusted only while it matches the
/// active link the server reports: a link regenerated or disabled elsewhere
/// leaves a stale token here, and offering it would share a dead link.
///
/// Holds only tokens the host made, in the app's private storage, which
/// `allowBackup`/`dataExtractionRules` already keep out of cloud backup.
class InviteLinkStore {
  InviteLinkStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static String _key(String partyId) => 'invite_link:$partyId';

  /// The token for [partyId] if this device holds the one that was created
  /// at [createdAt], else null.
  Future<String?> tokenFor(String partyId, DateTime createdAt) async {
    final stored = (await _prefs()).getStringList(_key(partyId));
    if (stored == null || stored.length != 2) return null;
    final at = DateTime.tryParse(stored[1]);
    if (at == null || !at.isAtSameMomentAs(createdAt)) return null;
    return stored[0];
  }

  Future<void> save(String partyId, String token, DateTime createdAt) async {
    await (await _prefs()).setStringList(_key(partyId), [token, createdAt.toUtc().toIso8601String()]);
  }

  Future<void> forget(String partyId) async {
    await (await _prefs()).remove(_key(partyId));
  }
}
