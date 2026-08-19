import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Account lifecycle: deletion, recovery, and the GDPR data export.
///
/// Its own repository rather than three more methods on [ProfileRepository],
/// because the surfaces are genuinely different. [ProfileRepository] reads and
/// writes preferences — values the user can change back, where a failed write
/// costs a re-tap. Nothing here is a preference: one call schedules the
/// destruction of the account, and the other hands the caller a file
/// containing everything the service knows about them.
///
/// Every method acts on the CURRENT user and none of them takes a user id.
/// That is not a convenience — it mirrors the server, where
/// `request_account_deletion` and `export_account_data` take no argument at
/// all and resolve `auth.uid()` themselves. There is no id in this path to get
/// wrong, at any layer.
class AccountRepository {
  AccountRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily for the same reason [ProfileRepository] does it: a test
  /// double subclasses this and overrides every method, and constructing a
  /// real client needs an initialized Supabase, which does not exist under
  /// `flutter test`.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  /// Schedules deletion and returns the moment the grace period started.
  ///
  /// What the server does immediately, which the confirmation copy promises
  /// and the user should therefore see happen: devices and pending
  /// notifications are purged, consent flags go false, and parties that have
  /// not started yet are cancelled. What it does NOT do for 30 days: touch
  /// anything the user wrote.
  ///
  /// Idempotent server-side — a second call returns the original timestamp
  /// rather than restarting the clock, so a double tap cannot quietly extend
  /// the grace period.
  Future<DateTime> requestDeletion() async {
    final result = await _client.rpc('request_account_deletion');
    return DateTime.parse(result as String).toLocal();
  }

  /// Takes the account back. Only works inside the grace period; once the
  /// erasure has run there is no auth user left to call this with.
  ///
  /// Deliberately does not restore cancelled parties or re-grant consent —
  /// both are acts the user performs, not state the app infers on their
  /// behalf.
  Future<void> cancelDeletion() async {
    await _client.rpc('cancel_account_deletion');
  }

  /// When the current user's account is scheduled for deletion, or null.
  ///
  /// Read from the user's own row rather than cached in memory, for the same
  /// reason Phase 8 deleted `mapVisible` from `mp_store` instead of migrating
  /// it: a mirror of server state can only ever disagree with the server. The
  /// grace period can also expire while the app is open.
  Future<DateTime?> deletionScheduledAt() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    final row = await _client
        .from('profiles')
        .select('deleted_at')
        .eq('id', userId)
        .maybeSingle();

    final value = row?['deleted_at'] as String?;
    return value == null ? null : DateTime.parse(value).toLocal();
  }

  /// The GDPR Art. 20 export, as pretty-printed JSON ready to be written to a
  /// file or shared.
  ///
  /// Goes through the `account-export` edge function rather than calling
  /// `export_account_data` directly, because the function is what sets the
  /// filename and the no-store cache headers — and because it is the seam
  /// where a future large-account export moves to "write to storage, mail a
  /// link" without this method changing shape.
  ///
  /// `functions.invoke` attaches the current session's token automatically;
  /// that token is the only thing identifying whose data comes back.
  Future<String> exportData() async {
    final response = await _client.functions.invoke('account-export');

    if (response.status != 200) {
      throw Exception('Export failed with status ${response.status}');
    }

    final data = response.data;
    // The function returns a JSON body; the client may hand it back already
    // decoded or as the raw string depending on the content type it saw.
    if (data is String) return data;
    return const JsonEncoder.withIndent('  ').convert(data);
  }
}
