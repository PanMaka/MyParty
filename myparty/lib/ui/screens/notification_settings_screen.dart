import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../data/device_repository.dart';
import '../../models/notification_prefs.dart';
import '../../services/location_reporter.dart';
import '../../services/push_service.dart';
import '../theme/app_theme.dart';
import '../widgets/location_consent_sheet.dart';

/// Where the two consents and the three preferences 7b shipped become visible.
///
/// The screen is deliberately laid out as consent first, preferences second,
/// because that is the order the engine reads them in: `wants_nearby_notifications`
/// is `push_consent AND notify_nearby`, and nothing below the consent rows has
/// any effect while the rows above them are off. Presenting a radius slider that
/// silently does nothing would be the settings-screen version of privacy theatre.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({
    super.key,
    this.repository,
    this.pushService,
    this.locationReporter,
  });

  final DeviceRepository? repository;
  final PushService? pushService;
  final LocationReporter? locationReporter;

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  late final DeviceRepository _devices = widget.repository ?? DeviceRepository();
  late final PushService _push = widget.pushService ?? PushService(devices: _devices);
  late final LocationReporter _location = widget.locationReporter ??
      LocationReporter(
        devices: _devices,
        pushToken: () => _push.token,
        platform: PushService.platformName,
      );

  NotificationPrefs? _prefs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await _devices.fetchPrefs();
    if (mounted) setState(() => _prefs = prefs);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Wraps every mutation so two taps cannot race each other into the database,
  /// and so a failed write reloads rather than leaving the switch showing a
  /// state the server never accepted.
  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      _say('Κάτι πήγε στραβά: $error');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePush(bool wanted) async {
    await _mutate(() async {
      if (!wanted) {
        // Withdrawing push consent does NOT delete the device row. The token is
        // still this install's, and re-enabling should not have to mint a new
        // one; the engine already refuses to enqueue anything while the flag is
        // false, and the delivery worker re-checks it at claim time.
        await _devices.setPushConsent(false);
        return;
      }

      final availability = await _push.register();
      switch (availability) {
        case PushAvailability.available:
          break;
        case PushAvailability.permissionDenied:
          _say('Οι ειδοποιήσεις είναι απενεργοποιημένες στις ρυθμίσεις του κινητού.');
        case PushAvailability.notConfigured:
          _say('Οι ειδοποιήσεις δεν είναι διαθέσιμες σε αυτή την έκδοση.');
        case PushAvailability.unavailable:
          _say('Δεν ήταν δυνατή η σύνδεση με την υπηρεσία ειδοποιήσεων.');
      }
    });
  }

  Future<void> _toggleLocation(bool wanted) async {
    await _mutate(() async {
      if (!wanted) {
        await _location.stop();
        // The flag is the mechanism, not a record of one: a trigger on
        // location_consent going true→false erases every stored cell for this
        // user immediately. Stopping the stream alone would leave the last one
        // on disk, and matchable, for up to 24 hours.
        await _devices.setLocationConsent(false);
        _say('Η τοποθεσία σου διαγράφηκε.');
        return;
      }

      // The explanation, then the OS prompt. Never the other way round.
      final accepted = await showLocationConsentSheet(context);
      final result = await _location.requestConsent(explanationAccepted: accepted);

      switch (result) {
        case LocationConsentResult.granted:
          break;
        case LocationConsentResult.explanationDeclined:
          break; // They said no to us; the OS was never asked.
        case LocationConsentResult.permissionDenied:
          _say('Χωρίς άδεια τοποθεσίας δεν μπορούμε να ξέρουμε τι είναι κοντά σου.');
        case LocationConsentResult.permissionDeniedForever:
          // Re-prompting is impossible at this point — only the system settings
          // app can undo it, so that is what gets offered instead of a dialog
          // the OS will never show.
          _say('Άνοιξε τις ρυθμίσεις για να επιτρέψεις την τοποθεσία.');
          await Geolocator.openAppSettings();
        case LocationConsentResult.serviceDisabled:
          _say('Οι υπηρεσίες τοποθεσίας είναι κλειστές στη συσκευή.');
      }
    });
  }

  Future<void> _pickQuietHour({required bool start}) async {
    final prefs = _prefs;
    if (prefs == null) return;

    final existing = start ? prefs.quietHoursStart : prefs.quietHoursEnd;
    final picked = await showTimePicker(
      context: context,
      initialTime: existing == null
          ? TimeOfDay(hour: start ? 23 : 8, minute: 0)
          : TimeOfDay(hour: existing.inHours % 24, minute: existing.inMinutes % 60),
    );
    if (picked == null) return;

    final chosen = Duration(hours: picked.hour, minutes: picked.minute);
    final other = start ? prefs.quietHoursEnd : prefs.quietHoursStart;

    // Both columns or neither — `profiles_quiet_hours_paired`. Setting one half
    // first would be refused, so the missing half gets a sensible default rather
    // than an error the user did not cause.
    final newStart = start ? chosen : (other ?? const Duration(hours: 23));
    final newEnd = start ? (other ?? const Duration(hours: 8)) : chosen;

    if (newStart == newEnd) {
      // `profiles_quiet_hours_distinct`: start == end is ambiguous between
      // "zero-length" and "all day", and those differ by 24 hours of silence.
      _say('Η αρχή και το τέλος δεν μπορούν να είναι η ίδια ώρα.');
      return;
    }

    await _mutate(() => _devices.updatePrefs(
          quietHoursStart: newStart,
          quietHoursEnd: newEnd,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Ειδοποιήσεις',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      body: prefs == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              children: [
                _section('ΑΔΕΙΕΣ'),
                _card([
                  _switchRow(
                    'Ειδοποιήσεις push',
                    'Προσκλήσεις, μηνύματα και πάρτι κοντά σου.',
                    prefs.pushConsent,
                    _togglePush,
                  ),
                  _divider(),
                  _switchRow(
                    'Τοποθεσία για πάρτι κοντά σου',
                    prefs.locationConsent
                        ? 'Περιοχή ~100μ, σβήνεται μετά από 24 ώρες.'
                        : 'Θα σου εξηγήσουμε ακριβώς τι κρατάμε πριν ρωτήσουμε.',
                    prefs.locationConsent,
                    _toggleLocation,
                  ),
                ]),
                _note(
                  'Η τοποθεσία σου δεν εμφανίζεται ποτέ σε άλλον χρήστη. '
                  'Αν κλείσεις τον διακόπτη, ό,τι έχει αποθηκευτεί διαγράφεται αμέσως.',
                ),

                const SizedBox(height: 22),
                _section('ΠΑΡΤΙ ΚΟΝΤΑ ΣΟΥ'),
                // Dimmed, not hidden, when the consents above are off: the
                // settings still exist and are still theirs, and hiding them
                // would make the screen look broken rather than gated.
                Opacity(
                  opacity: prefs.pushConsent && prefs.locationConsent ? 1 : 0.45,
                  child: IgnorePointer(
                    ignoring: !(prefs.pushConsent && prefs.locationConsent),
                    child: Column(
                      children: [
                        _card([
                          _switchRow(
                            'Ειδοποίησέ με για πάρτι κοντά μου',
                            'Ξεχωριστό από την άδεια — μπορείς να το κλείσεις χωρίς να ανακαλέσεις τίποτα.',
                            prefs.notifyNearby,
                            (v) => _mutate(() => _devices.updatePrefs(notifyNearby: v)),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        _card([
                          _CommittingSlider(
                            title: 'Απόσταση',
                            value: prefs.radiusMeters.toDouble(),
                            // The 100 floor is the resolution limit — locations
                            // are stored as a ~100m cell, so a smaller radius
                            // asks a question the data cannot answer. The 5000
                            // ceiling is the CHECK constraint, and that
                            // constraint is load-bearing for the query plan:
                            // the engine's indexable st_dwithin term is the
                            // same literal.
                            min: 100,
                            max: 5000,
                            divisions: 49,
                            enabled: !_busy,
                            label: (v) => '${v.round()} μ.',
                            onCommit: (v) =>
                                _mutate(() => _devices.updatePrefs(radiusMeters: v.round())),
                          ),
                          _divider(),
                          _CommittingSlider(
                            title: 'Μέγιστο ανά ημέρα',
                            value: prefs.dailyCap.toDouble(),
                            min: 0,
                            max: 20,
                            divisions: 20,
                            enabled: !_busy,
                            // Zero is a real, reachable setting — "never send me
                            // these" without withdrawing any consent.
                            label: (v) => v.round() == 0 ? 'καμία' : '${v.round()}',
                            onCommit: (v) =>
                                _mutate(() => _devices.updatePrefs(dailyCap: v.round())),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 22),
                _section('ΩΡΕΣ ΗΣΥΧΙΑΣ'),
                _card([
                  _tapRow(
                    'Από',
                    prefs.quietHoursStart == null
                        ? '—'
                        : NotificationPrefs.formatTime(prefs.quietHoursStart!),
                    () => _pickQuietHour(start: true),
                  ),
                  _divider(),
                  _tapRow(
                    'Έως',
                    prefs.quietHoursEnd == null
                        ? '—'
                        : NotificationPrefs.formatTime(prefs.quietHoursEnd!),
                    () => _pickQuietHour(start: false),
                  ),
                  if (prefs.hasQuietHours) ...[
                    _divider(),
                    _tapRow('Κατάργηση ωρών ησυχίας', '', () {
                      _mutate(() => _devices.updatePrefs(clearQuietHours: true));
                    }),
                  ],
                ]),
                _note(
                  prefs.hasQuietHours
                      // Deferred, not dropped — the decision is taken when the
                      // party is published and only the delivery moves. Worth
                      // saying, because "you will get it later" and "you will
                      // not get it" are different promises.
                      ? 'Μέσα σε αυτό το διάστημα δεν χτυπάει τίποτα. Οι ειδοποιήσεις '
                          'δεν χάνονται — έρχονται μόλις τελειώσει.'
                      : 'Όρισε ένα διάστημα για να μη σε ξυπνάει τίποτα.',
                ),
              ],
            ),
    );
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 9),
        child: Text(label, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
      );

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: Colors.white.withValues(alpha: 0.035),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(children: children),
      );

  Widget _divider() => Container(height: 1, color: AppColors.hairline);

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
        child: Text(
          text,
          style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
        ),
      );

  Widget _switchRow(String title, String sub, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(fontSize: 11, height: 1.4, color: AppColors.textAlpha(0.45))),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            value: value,
            onChanged: _busy ? null : onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.purpleDeep,
          ),
        ],
      ),
    );
  }

  Widget _tapRow(String title, String value, VoidCallback onTap) {
    return InkWell(
      onTap: _busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            if (value.isNotEmpty)
              Text(value, style: AppTextStyles.mono(size: 12.5, color: AppColors.purpleLight)),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
          ],
        ),
      ),
    );
  }
}

/// A slider that follows the thumb locally and writes once, on release.
///
/// The naive version — driving the slider straight from the loaded preference
/// and saving in `onChanged` — is wrong twice over: a drag fires continuously,
/// so one gesture becomes dozens of UPDATEs, and because each write is followed
/// by a reload the thumb snaps back to the last saved value mid-drag. Local
/// state while dragging, one write on `onChangeEnd`.
class _CommittingSlider extends StatefulWidget {
  const _CommittingSlider({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onCommit,
    required this.enabled,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) label;
  final ValueChanged<double> onCommit;
  final bool enabled;

  @override
  State<_CommittingSlider> createState() => _CommittingSliderState();
}

class _CommittingSliderState extends State<_CommittingSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final shown = (_dragging ?? widget.value).clamp(widget.min, widget.max);

    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.title,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              Text(widget.label(shown),
                  style: AppTextStyles.mono(size: 11.5, color: AppColors.purpleLight)),
            ],
          ),
          Slider(
            value: shown,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            activeColor: AppColors.purple,
            inactiveColor: Colors.white.withValues(alpha: 0.12),
            onChanged: widget.enabled ? (v) => setState(() => _dragging = v) : null,
            onChangeEnd: (v) {
              // Cleared so the next build falls back to the reloaded preference.
              // Keeping the local value would leave the thumb showing what was
              // asked for even if the server clamped or refused it.
              setState(() => _dragging = null);
              widget.onCommit(v);
            },
          ),
        ],
      ),
    );
  }
}
