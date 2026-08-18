import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/notification_prefs.dart';

/// Thrown when a device could not be registered for a reason the user can
/// actually do something about. The two cases are genuinely different and the
/// UI has to say different things, which is why `upsert_user_device` goes to
/// the trouble of raising two distinguishable codes.
enum DeviceRegistrationProblem {
  /// `P0001` — a location was offered while `profiles.location_consent` is
  /// false. The device itself registers fine without one.
  locationConsentMissing,

  /// `23505` — this FCM token already belongs to another account, which happens
  /// on a shared or resold handset when the previous user never signed out.
  /// Deliberately not resolvable from here: widening the RLS so one user could
  /// overwrite another's row is what would let the previous owner's
  /// notifications keep arriving.
  tokenBelongsToAnotherAccount,
}

class DeviceRegistrationException implements Exception {
  DeviceRegistrationException(this.problem, this.message);
  final DeviceRegistrationProblem problem;
  final String message;

  @override
  String toString() => 'DeviceRegistrationException($problem): $message';
}

/// Every widget-level Supabase call touching `user_devices` or the notification
/// preference columns goes through here — screens never call
/// `Supabase.instance.client` directly. Mirrors [StoryRepository],
/// [ChatRepository] and the rest.
///
/// Nothing here decides whether a location may be stored. That is 7a's RLS
/// `with check`, and `upsert_user_device` is `security invoker` precisely so the
/// policy stays the authority — [rounded] below is defence in depth, not the
/// guarantee.
class DeviceRepository {
  DeviceRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily for the same reason [ChatRepository] does it: a test double
  /// subclasses this and overrides every method, and constructing a real client
  /// just to discard it needs an initialized Supabase, which does not exist
  /// under `flutter test`.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  /// Rounds to three decimal places — the same ~100m grid
  /// `public.round_location` applies in a before-trigger.
  ///
  /// Doing it twice is not redundant. The trigger is what makes "a precise fix
  /// never reaches the heap" *true*, because it catches every writer including
  /// future migrations and psql. This catches something the trigger structurally
  /// cannot: the coordinate still travels in the statement text, so on a stack
  /// running `log_statement = 'all'` the precise value would be written to a log
  /// file before Postgres ever rounds it. Rounding client-side means the precise
  /// value never leaves the handset at all.
  static double rounded(double degrees) => (degrees * 1000).roundToDouble() / 1000;

  /// Registers or refreshes this install's push token.
  ///
  /// [latitude]/[longitude] are optional and omitting them is a supported,
  /// ordinary case: push consent and location consent are separate acts, so a
  /// device that only wants "someone invited you" notifications must be able to
  /// exist without ever offering a coordinate.
  ///
  /// Goes through the `upsert_user_device` RPC rather than a PostgREST upsert
  /// because it cannot be expressed as one. `user_devices` grants
  /// `insert (id, user_id, push_token, platform, last_location)` but only
  /// `update (push_token, platform, last_location)`, and PostgREST puts every
  /// key of the request body into the `ON CONFLICT DO UPDATE SET` list — so a
  /// body carrying `user_id`, which the insert path requires, tries to write a
  /// column the update path deliberately has no privilege on. It would succeed
  /// on first run and fail on every one after.
  Future<String?> registerDevice({
    required String pushToken,
    required String platform,
    double? latitude,
    double? longitude,
  }) async {
    if (currentUserId == null) return null;

    try {
      final id = await _client.rpc('upsert_user_device', params: {
        'p_push_token': pushToken,
        'p_platform': platform,
        'p_lat': latitude == null ? null : rounded(latitude),
        'p_lng': longitude == null ? null : rounded(longitude),
      });
      return id as String?;
    } on PostgrestException catch (error) {
      throw DeviceRegistrationException(
        switch (error.code) {
          'P0001' => DeviceRegistrationProblem.locationConsentMissing,
          '23505' => DeviceRegistrationProblem.tokenBelongsToAnotherAccount,
          _ => throw error,
        },
        error.message,
      );
    }
  }

  /// Reports a new position for an already-registered device.
  ///
  /// Identical call to [registerDevice] — the RPC is an upsert keyed on the
  /// token, so "register" and "move" are the same statement. Kept as a separate
  /// method because the call sites mean different things and the location one is
  /// the one that must never be reached without consent.
  Future<void> reportLocation({
    required String pushToken,
    required String platform,
    required double latitude,
    required double longitude,
  }) async {
    await registerDevice(
      pushToken: pushToken,
      platform: platform,
      latitude: latitude,
      longitude: longitude,
    );
  }

  /// Removes this install's device row. Called on sign-out, and it is the
  /// documented fix for the cross-account token conflict: FCM issues a token per
  /// app install, not per user, so a row left behind by the previous account is
  /// a row that would deliver their notifications to whoever signs in next.
  ///
  /// Deliberately best-effort. Sign-out must not fail because a delete did.
  Future<void> unregisterDevice(String pushToken) async {
    if (currentUserId == null) return;
    try {
      await _client.from('user_devices').delete().eq('push_token', pushToken);
    } catch (_) {
      // The row may already be gone — FCM rotated the token, or the worker
      // deleted it after a 404. Either way there is nothing left to do.
    }
  }

  Future<NotificationPrefs?> fetchPrefs() async {
    final userId = currentUserId;
    if (userId == null) return null;

    final row = await _client
        .from('profiles')
        .select(
          'push_consent, location_consent, notify_nearby, notify_radius_meters, '
          'notify_daily_cap, notification_tz, quiet_hours_start, quiet_hours_end',
        )
        .eq('id', userId)
        .maybeSingle();

    if (row == null) return null;
    return NotificationPrefs.fromRow(row);
  }

  /// Writes the preference columns. `profiles` already carries a table-wide
  /// UPDATE grant and an owner-only policy, so these are a plain PATCH — the
  /// CHECK constraints are what keep them honest, not the client.
  Future<void> updatePrefs({
    bool? notifyNearby,
    int? radiusMeters,
    int? dailyCap,
    String? timezone,
    Duration? quietHoursStart,
    Duration? quietHoursEnd,
    bool clearQuietHours = false,
  }) async {
    final userId = currentUserId;
    if (userId == null) return;

    final patch = <String, dynamic>{
      'notify_nearby': ?notifyNearby,
      'notify_radius_meters': ?radiusMeters,
      'notify_daily_cap': ?dailyCap,
      'notification_tz': ?timezone,
      // Both columns move together or neither does — `profiles_quiet_hours_paired`
      // refuses half a window, and the engine would have to invent a meaning for
      // one anyway.
      if (clearQuietHours) 'quiet_hours_start': null,
      if (clearQuietHours) 'quiet_hours_end': null,
      if (!clearQuietHours && quietHoursStart != null)
        'quiet_hours_start': NotificationPrefs.formatTime(quietHoursStart),
      if (!clearQuietHours && quietHoursEnd != null)
        'quiet_hours_end': NotificationPrefs.formatTime(quietHoursEnd),
    };

    if (patch.isEmpty) return;
    await _client.from('profiles').update(patch).eq('id', userId);
  }

  Future<void> setPushConsent(bool granted) async {
    final userId = currentUserId;
    if (userId == null) return;
    await _client.from('profiles').update({'push_consent': granted}).eq('id', userId);
  }

  /// Sets `profiles.location_consent`.
  ///
  /// Setting it to false is not merely bookkeeping: a trigger on that column
  /// going true→false nulls every `last_location` this user has, immediately
  /// (GDPR Art. 7(3)). That is why the revocation path in [LocationReporter]
  /// calls this rather than just stopping the position stream — stopping
  /// collection leaves the last cell on disk for up to 24 hours, still matchable
  /// by the proximity queries.
  Future<void> setLocationConsent(bool granted) async {
    final userId = currentUserId;
    if (userId == null) return;
    await _client.from('profiles').update({'location_consent': granted}).eq('id', userId);
  }

  /// Distance in metres between two points, used only to decide whether a new
  /// fix is worth sending. Haversine on a sphere is far more precision than a
  /// ~100m threshold needs.
  static double metresBetween(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0;
    double toRad(double d) => d * math.pi / 180.0;

    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) * math.cos(toRad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
