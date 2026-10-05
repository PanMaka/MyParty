import 'package:flutter/foundation.dart';

import 'mp_store.dart';

/// One RSVP the viewer just saved: [status] is their answer now, null when
/// they withdrew it.
///
/// Published only AFTER the write succeeded, so a listener reacting to it is
/// reacting to the server's state and not to an optimistic guess.
class RsvpChange {
  const RsvpChange({required this.partyId, required this.status});

  final String partyId;
  final MpRsvp? status;
}

/// App-wide "the viewer's rsvps rows changed" signal.
///
/// The tabs live in an IndexedStack, so a screen built once never rebuilds
/// because another tab wrote something: an RSVP from the map sheet would leave
/// MY PARTIES and the map's own pin counts stale until a restart or a pan.
/// Every RSVP writer publishes here and every RSVP reader listens, which is
/// what lets the answer show up wherever it was given from.
///
/// A plain notifier rather than a Provider so widget tests that pump one
/// screen without the app's providers above it still build. RsvpChange has
/// identity equality, so every publish notifies, even a repeat of the last.
final ValueNotifier<RsvpChange?> rsvpChanges = ValueNotifier(null);

/// The wire value of `my_rsvp_status` as an [MpRsvp], null for "no row".
MpRsvp? parseRsvpStatus(String? value) => switch (value) {
      'going' => MpRsvp.going,
      'interested' => MpRsvp.interested,
      _ => null,
    };
