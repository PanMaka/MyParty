import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// A live subscription to `party_host:{uuid}` (20261014113213), held by the
/// host dashboard while it is open.
///
/// One event, `rsvp_activity`: "an rsvp on this party changed". It carries the
/// party id and nothing else, the same shape as the inbox topic — the dashboard
/// refetches rather than render it, so the stats and guest-list functions stay
/// the only thing deciding what the host reads.
class PartyHostChannel {
  PartyHostChannel({required this.activity, required this.status, required this.dispose});

  /// One event per rsvp change on the party.
  final Stream<void> activity;

  /// Subscribe/disconnect transitions; a re-subscribe means the socket was
  /// down and anything that happened meanwhile was missed.
  final Stream<RealtimeSubscribeStatus> status;

  final Future<void> Function() dispose;
}

/// Joins `party_host:{partyId}` as a PRIVATE channel, so the
/// `realtime.messages` policy runs and admits only the party's host. A
/// non-host's join is simply unauthorized and hears nothing.
PartyHostChannel subscribePartyHostTopic(SupabaseClient client, String partyId) {
  final activity = StreamController<void>.broadcast();
  final status = StreamController<RealtimeSubscribeStatus>.broadcast();

  final channel = client.channel(
    'party_host:$partyId',
    opts: const RealtimeChannelConfig(private: true),
  );

  channel
      .onBroadcast(
        event: 'rsvp_activity',
        callback: (_) {
          if (!activity.isClosed) activity.add(null);
        },
      )
      .subscribe((state, error) {
        if (!status.isClosed) status.add(state);
      });

  return PartyHostChannel(
    activity: activity.stream,
    status: status.stream,
    dispose: () async {
      await activity.close();
      await status.close();
      await client.removeChannel(channel);
    },
  );
}
