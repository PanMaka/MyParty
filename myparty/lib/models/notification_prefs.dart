/// The `profiles` columns that decide whether, and when, a proximity push is
/// allowed to reach this person.
///
/// Two of these are consent and the rest are preferences, and the distinction
/// is not cosmetic — it is the reason there are two flags where a product spec
/// would have written one. [pushConsent] and [locationConsent] are legal states
/// under GDPR: withdrawing either has to take effect immediately and has
/// consequences beyond this screen (withdrawing location consent fires a
/// trigger that erases every stored cell). [notifyNearby] is a setting; turning
/// it off silences the feature and changes nothing about what may be stored.
///
/// The engine reads their conjunction through `wants_nearby_notifications`,
/// which is why the UI must never collapse them into one switch: "I don't want
/// these notifications" and "I withdraw consent to be located" are different
/// sentences, and only one of them is reversible without losing data.
class NotificationPrefs {
  const NotificationPrefs({
    required this.pushConsent,
    required this.locationConsent,
    required this.notifyNearby,
    required this.radiusMeters,
    required this.dailyCap,
    required this.timezone,
    this.quietHoursStart,
    this.quietHoursEnd,
  });

  final bool pushConsent;
  final bool locationConsent;
  final bool notifyNearby;

  /// 100–5000, enforced by `profiles_notify_radius_check`. The ceiling is not a
  /// product opinion — the engine's spatial queries carry a constant
  /// `st_dwithin(…, 5000)` term to make the GiST index usable, and that constant
  /// is only sound while no user can exceed it.
  final int radiusMeters;

  /// 0–50. Zero is meaningful and reachable: "never send me these", without
  /// touching consent.
  final int dailyCap;

  /// IANA zone. Quiet hours and the "daily" cap are local-calendar concepts;
  /// evaluated in UTC they are wrong for most of the world most of the year.
  final String timezone;

  /// Both null or both set — `profiles_quiet_hours_paired`. Half a quiet window
  /// has no meaning the engine's wrap-around arithmetic could act on.
  final Duration? quietHoursStart;
  final Duration? quietHoursEnd;

  bool get hasQuietHours => quietHoursStart != null && quietHoursEnd != null;

  /// True when the window crosses midnight, which is the overwhelmingly common
  /// shape (23:00–08:00) and the one a naive `start <= now <= end` gets exactly
  /// backwards.
  bool get quietHoursWrapMidnight =>
      hasQuietHours && quietHoursStart!.inMinutes > quietHoursEnd!.inMinutes;

  static Duration? _parseTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final parts = value.split(':');
    if (parts.length < 2) return null;
    return Duration(
      hours: int.tryParse(parts[0]) ?? 0,
      minutes: int.tryParse(parts[1]) ?? 0,
    );
  }

  static String formatTime(Duration time) {
    final h = time.inHours.remainder(24).toString().padLeft(2, '0');
    final m = time.inMinutes.remainder(60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  factory NotificationPrefs.fromRow(Map<String, dynamic> row) {
    return NotificationPrefs(
      // Defaulting the consent flags to FALSE rather than to the column default
      // is deliberate: a row that failed to load must never read as consent
      // given. Everything else may safely fall back to the schema's default.
      pushConsent: (row['push_consent'] as bool?) ?? false,
      locationConsent: (row['location_consent'] as bool?) ?? false,
      notifyNearby: (row['notify_nearby'] as bool?) ?? true,
      radiusMeters: (row['notify_radius_meters'] as int?) ?? 500,
      dailyCap: (row['notify_daily_cap'] as int?) ?? 5,
      timezone: (row['notification_tz'] as String?) ?? 'Europe/Athens',
      quietHoursStart: _parseTime(row['quiet_hours_start']),
      quietHoursEnd: _parseTime(row['quiet_hours_end']),
    );
  }

  NotificationPrefs copyWith({
    bool? pushConsent,
    bool? locationConsent,
    bool? notifyNearby,
    int? radiusMeters,
    int? dailyCap,
    String? timezone,
    Duration? quietHoursStart,
    Duration? quietHoursEnd,
    bool clearQuietHours = false,
  }) {
    return NotificationPrefs(
      pushConsent: pushConsent ?? this.pushConsent,
      locationConsent: locationConsent ?? this.locationConsent,
      notifyNearby: notifyNearby ?? this.notifyNearby,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      dailyCap: dailyCap ?? this.dailyCap,
      timezone: timezone ?? this.timezone,
      quietHoursStart: clearQuietHours ? null : (quietHoursStart ?? this.quietHoursStart),
      quietHoursEnd: clearQuietHours ? null : (quietHoursEnd ?? this.quietHoursEnd),
    );
  }
}
