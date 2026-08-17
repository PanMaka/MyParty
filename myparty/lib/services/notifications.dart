import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import 'location_reporter.dart';
import 'push_service.dart';

/// App-scoped wiring for the two 7c services, so that `main`, `AuthGate` and
/// `AuthService` all talk to the same [PushService] instance.
///
/// They have to: the FCM token lives in that instance, and it is the key of the
/// `user_devices` row that both the location reporter writes to and sign-out
/// deletes. Two instances would mean sign-out failing to remove the row the
/// other one registered — which is the exact failure that leaves a handset
/// receiving the previous account's notifications.
///
/// Not injected through Provider because these are not UI state and nothing
/// rebuilds on them. Screens that need to be testable take their own instances
/// as constructor parameters instead (see [NotificationSettingsScreen]).
class Notifications {
  Notifications._();

  static final PushService push = PushService();

  static final LocationReporter location = LocationReporter(
    pushToken: () => push.token,
    platform: PushService.platformName,
  );

  static bool _observerAdded = false;

  /// Called once from `main`, before `runApp`.
  ///
  /// Every part of this is allowed to fail. A repo with no `google-services.json`
  /// has no Firebase app to initialise, and that must leave the app fully usable
  /// with push simply unavailable — the same state as a handset with no Play
  /// Services, which is a real device rather than a hypothetical one.
  static Future<void> initialise() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    } catch (error) {
      debugPrint('[push] firebase unavailable, continuing without push: $error');
    }
  }

  /// Called once a session exists and onboarding is done.
  ///
  /// Push registration is attempted only when the user has already granted push
  /// consent; a first-time user is not prompted on launch. An OS notification
  /// prompt fired at app start, with no context for what it is for, is the
  /// single most reliable way to be permanently denied — and on iOS it can only
  /// be asked once. The settings screen asks when the user goes looking for it.
  static Future<void> onSignedIn({required bool pushConsent, required bool locationConsent}) async {
    if (!_observerAdded) {
      // Re-checks the OS permission on every resume, which is the only way to
      // notice a revocation — the OS never tells the app.
      WidgetsBinding.instance.addObserver(location);
      _observerAdded = true;
    }

    if (pushConsent) await push.register();
    if (locationConsent) await location.syncPermissionState();
  }

  /// Called BEFORE `supabase.auth.signOut()`, and the order is load-bearing:
  /// `user_devices` is owner-only, so once the session is gone the delete is
  /// refused and the row is stranded. A stranded row is not merely litter —
  /// `push_token` is globally unique, so the next account on this handset cannot
  /// register, and until FCM rotates the token the worker keeps sending the
  /// previous user's notifications to a phone somebody else is now holding.
  static Future<void> onSignOut() async {
    await location.stop();
    await push.unregister();
  }
}
