import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../utils/party_link.dart';

/// App-scoped: receives every link the OS opens the app with and keeps the
/// party id until someone signed in can act on it.
///
/// Started once in `main()`, before the first frame, because the link that
/// LAUNCHED the app is delivered on the same stream as later ones (app_links
/// on mobile) and must not be missed while the auth gate is still deciding
/// which screen to show. [pending] is then consumed by `PartyLinkHandler`,
/// which only exists once someone is signed in and onboarded — so a link
/// opened while signed out waits, and opens after sign-in.
///
/// Only party links are kept. Anything else — including a link dressed up as
/// an auth callback — is dropped here; `main.dart` has also turned off
/// supabase_flutter's own link listener, so nothing in the app reads tokens
/// from a link.
class PartyLinks {
  PartyLinks._();

  /// The id of the most recent party link not yet opened, or null.
  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  static StreamSubscription<Uri>? _subscription;

  static void start({AppLinks? appLinks}) {
    if (_subscription != null) return;
    _subscription = (appLinks ?? AppLinks()).uriLinkStream.listen(
          receive,
          // A malformed intent is not worth crashing over, and not worth
          // retrying either — the next link starts clean.
          onError: (Object error) => debugPrint('Ignoring an unreadable link: $error'),
        );
  }

  /// Exposed for tests; the stream above is the only production caller.
  @visibleForTesting
  static void receive(Uri uri) {
    final id = partyIdFromLink(uri);
    if (id != null) pending.value = id;
  }
}
