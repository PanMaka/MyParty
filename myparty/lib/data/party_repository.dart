import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/rsvp_party.dart';

/// Every widget-level Supabase call for parties/rsvps goes through here —
/// screens never call `Supabase.instance.client` directly.
class PartyRepository {
  PartyRepository({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Creates a party and its initial invitations in one RPC call.
  /// `party` keys: title, description, lat, lon, starts_at (ISO 8601),
  /// is_private. Returns the new party's id.
  Future<String> createPartyWithInvites({
    required Map<String, dynamic> party,
    List<String> inviteeIds = const [],
  }) async {
    final id = await _client.rpc('create_party_with_invites', params: {
      'p_party': party,
      'p_invitee_ids': inviteeIds,
    });
    return id as String;
  }

  /// Parties the current user has RSVP'd to (interested or going),
  /// newest RSVP first. Bounded rather than keyset-paginated: this is a
  /// personal list, not an unbounded feed.
  Future<List<RsvpParty>> fetchMyRsvps() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];

    final rows = await _client
        .from('rsvps')
        .select(
          'status, parties!inner(id, title, starts_at, is_private, going_count, interested_count, status)',
        )
        .eq('user_id', userId)
        .eq('parties.status', 'published')
        .order('created_at', ascending: false)
        .limit(200);

    return (rows as List).map((row) => RsvpParty.fromRow(row as Map<String, dynamic>)).toList();
  }
}
