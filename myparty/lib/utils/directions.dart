import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Google Maps directions to a party, as a universal URL.
///
/// `https://www.google.com/maps/dir/?api=1&destination=…` opens the Maps app
/// where it is installed and the browser everywhere else, on Android, iOS and
/// web alike. There is deliberately no `origin`: Maps then starts from the
/// viewer's own position, which it asks for itself — we neither read nor send
/// it.
///
/// Coordinates win when present, because they are the host's actual pin.
/// [address] is the fallback: the party's `address` (Phase 42) when it has
/// one, else its `area`. Never the other way round: the address is a label
/// the host can edit ("rooftop, 3rd floor"), the pin is where the party is.
/// Since `parties.location` is NOT NULL the fallback only fires on a row
/// decoded without coordinates.
///
/// Returns null when there is nothing to navigate to. Takes only what the
/// caller already holds, so it cannot reveal a position the read RPC did not
/// send: every party row on the client came through an invoker-rights RPC and
/// the parties SELECT policy.
Uri? directionsUri({double? lat, double? lng, String? address}) {
  final String destination;
  if (_validCoordinates(lat, lng)) {
    destination = '$lat,$lng';
  } else {
    final text = address?.trim() ?? '';
    if (text.isEmpty) return null;
    destination = text;
  }
  // queryParameters percent-encodes for us — Greek included, as UTF-8.
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': destination,
  });
}

bool _validCoordinates(double? lat, double? lng) =>
    lat != null &&
    lng != null &&
    lat.isFinite &&
    lng.isFinite &&
    lat.abs() <= 90 &&
    lng.abs() <= 180;

/// Opens a URL outside the app. A seam so widget tests can record the URL
/// instead of reaching a platform channel.
typedef LaunchExternal = Future<bool> Function(Uri uri);

Future<bool> launchExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens [directionsUri] in Google Maps, or says why it could not.
///
/// Every failure — no location, no app or browser to take the link, a
/// platform error — ends in the same short snackbar rather than a silent tap.
Future<void> openDirections(
  BuildContext context, {
  double? lat,
  double? lng,
  String? address,
  LaunchExternal launch = launchExternal,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final uri = directionsUri(lat: lat, lng: lng, address: address);
  if (uri == null) {
    _fail(messenger, 'No location for this party');
    return;
  }
  bool opened;
  try {
    opened = await launch(uri);
  } catch (_) {
    opened = false;
  }
  if (!opened) _fail(messenger, "Couldn't open Google Maps");
}

void _fail(ScaffoldMessengerState? messenger, String message) {
  messenger?.showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}
