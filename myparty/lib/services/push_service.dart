import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/device_repository.dart';

/// Handles a push that arrives while the app is terminated or backgrounded.
///
/// Must be a top-level function: Flutter spins up a **separate isolate** for it,
/// with none of the app's state, so a closure or a method would have nothing to
/// capture. It deliberately does almost nothing — the system tray notification
/// is drawn by the OS from the `notification` block the worker sends, and this
/// exists so the `data` block is delivered at all.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // No Supabase, no repositories: this isolate has no session, and re-initialising
  // one to record a delivery receipt would be a network call on a background
  // wake-up for something no screen is waiting on.
  debugPrint('[push] background message ${message.messageId}');
}

/// Why push might not be available, so the UI can say something true rather
/// than "something went wrong".
enum PushAvailability {
  /// Working: Firebase initialised and a token was obtained.
  available,

  /// No `google-services.json` / `GoogleService-Info.plist` has been added, so
  /// there is no Firebase app to talk to. The expected state of a fresh clone —
  /// see the pubspec comment and `flutterfire configure`.
  notConfigured,

  /// Firebase is configured but the user declined the OS notification prompt.
  permissionDenied,

  /// Configured and permitted, but no token came back — typically a handset
  /// with no Google Play Services.
  unavailable,
}

/// Owns the FCM token: obtaining it, keeping it fresh, and making sure the row
/// in `user_devices` matches it.
///
/// Everything here is wrapped so that a missing or broken Firebase setup
/// degrades to [PushAvailability.notConfigured] instead of throwing. That is not
/// only for the un-configured repo — it is the correct runtime behaviour on any
/// Android device without Play Services, where `getToken` genuinely cannot
/// succeed and the rest of the app must keep working.
class PushService {
  PushService({DeviceRepository? devices, FirebaseMessaging? messaging})
      : _devices = devices ?? DeviceRepository(),
        _messagingOverride = messaging;

  final DeviceRepository _devices;
  final FirebaseMessaging? _messagingOverride;

  FirebaseMessaging get _messaging => _messagingOverride ?? FirebaseMessaging.instance;

  String? _token;
  StreamSubscription<String>? _refreshSubscription;

  /// The token this install is currently registered under, or null if push is
  /// unavailable. [LocationReporter] needs it, because a location is stored
  /// against a device row and the token is that row's key.
  String? get token => _token;

  static String get platformName {
    if (kIsWeb) return 'web';
    if (Platform.isIOS || Platform.isMacOS) return 'ios';
    return 'android';
  }

  /// Obtains a token and writes the device row. Safe to call more than once —
  /// the RPC is an upsert keyed on the token.
  ///
  /// Ordering matters and is the opposite of the obvious one: the OS
  /// notification permission is requested BEFORE the token is used, because on
  /// iOS a token obtained without permission is a token that can never deliver
  /// anything, and registering it would put a row in `user_devices` that the
  /// worker will send to forever and FCM will silently drop.
  Future<PushAvailability> register() async {
    if (Firebase.apps.isEmpty) return PushAvailability.notConfigured;

    final NotificationSettings settings;
    try {
      settings = await _messaging.requestPermission();
    } on FirebaseException {
      return PushAvailability.notConfigured;
    }

    // `provisional` is iOS's quiet authorisation — notifications are delivered
    // straight to the notification centre without an alert. It counts as
    // permitted; treating it as a denial would silence a user who was never
    // asked to say no.
    final permitted = settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
    if (!permitted) return PushAvailability.permissionDenied;

    String? token;
    try {
      // On iOS the APNs token can lag the permission grant by a moment, and
      // getToken then returns null rather than throwing. Retried once rather
      // than reported as unavailable on what is usually a timing artefact.
      token = await _messaging.getToken();
      token ??= await Future<String?>.delayed(
        const Duration(seconds: 2),
        () => _messaging.getToken(),
      );
    } on FirebaseException {
      return PushAvailability.unavailable;
    }

    if (token == null) return PushAvailability.unavailable;

    _token = token;
    await _devices.setPushConsent(true);
    await _registerToken(token);

    // FCM rotates tokens on its own schedule — a restore to a new handset, a
    // reinstall, a periodic refresh. Without this the row keeps a token that
    // stopped working and the worker deletes it on the first 404, leaving the
    // user silently unsubscribed.
    _refreshSubscription ??= _messaging.onTokenRefresh.listen((fresh) async {
      final previous = _token;
      _token = fresh;
      await _registerToken(fresh);
      // Only after the new row exists: a crash between the two leaves a
      // duplicate device, which is one wasted send. The other order leaves the
      // user with no row at all.
      if (previous != null && previous != fresh) {
        await _devices.unregisterDevice(previous);
      }
    });

    return PushAvailability.available;
  }

  Future<void> _registerToken(String token) async {
    try {
      // No location here on purpose. Registering for push and offering a
      // coordinate are separate acts with separate consent, and this path runs
      // for users who have declined the second one.
      await _devices.registerDevice(pushToken: token, platform: platformName);
    } on DeviceRegistrationException catch (error) {
      // Surfaced as a log rather than an exception: registration happens on
      // sign-in, where there is no screen to show an error on and nothing the
      // user could do about it mid-launch. The settings screen re-runs it and
      // does report failures.
      debugPrint('[push] device registration refused: ${error.problem}');
    }
  }

  /// Deletes the device row. Called on sign-out, before the session goes away —
  /// afterwards the delete would be refused by RLS, since the row is only
  /// visible to its owner.
  Future<void> unregister() async {
    final token = _token;
    _token = null;
    await _refreshSubscription?.cancel();
    _refreshSubscription = null;
    if (token != null) await _devices.unregisterDevice(token);
  }

  void dispose() {
    _refreshSubscription?.cancel();
    _refreshSubscription = null;
  }
}
