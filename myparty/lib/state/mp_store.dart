import 'dart:async';

import 'package:flutter/foundation.dart';

/// The two answers `public.rsvp_status` holds, and the only two it will hold —
/// 22_private_party_counts_and_rsvp asserts the enum stays at two values.
///
/// There is deliberately no `declined`. "Not going" is the ABSENCE of a row:
/// un-tapping deletes it, which the rsvps DELETE policy and the counter
/// trigger's DELETE branch have supported since the table was created. A third
/// value would record an absence the absent row already records, and would
/// widen `my_rsvp_status` on three read RPCs to do it.
///
/// A PRIVATE party only ever takes [going] — the rsvps write policies refuse
/// [interested] on one (20260825090050), so "Coming" writes 'going'.
enum MpRsvp { interested, going }

/// Shared mock/interactive state for the redesigned screens, mirroring the
/// single component state tree of the original design prototype.
class MpStore extends ChangeNotifier {
  MpStore();

  // _hype / hypeOf / bump and the mock _rsvp map lived here until Phase 18.
  //
  // HYPE IS GONE, not migrated. It was a percentage with no column behind it
  // -- seeded at 64 and 41 for two hardcoded party keys, decremented by a
  // timer and bumped by taps -- and there is no hype column in the schema and
  // no phase that adds one. What replaced it on the card is the thing it was
  // a picture of: the real interested_count, labelled by tense. Same call
  // credibility_score already got, for the same reason: a number nothing
  // computes is an invitation to display it.
  //
  // The rsvp map went because the buttons write to `rsvps` now. It was keyed
  // by mpParties handles ('vinyl', 'taratsa') that no table could match, and
  // my_rsvp_status comes back on every read RPC that carries a party.
  // _invited / invited / toggleInvited / invitedCount lived here until Phase 11
  // and were already unreachable when they were removed: the host wizard keeps
  // its own `Set<String> _invited` of real profile uuids from
  // SocialRepository.fetchFollowing, and its done screen's `invitedCount` is a
  // constructor parameter on a private widget, not this getter. The keys here
  // were mock handles ('eleni', 'aris') that no table could ever match.
  //
  // _mapVisible / toggleMapVisible lived here until Phase 8. They are gone
  // rather than migrated: the real setting is profiles.map_visibility, which is
  // three tiers instead of two and is read by get_parties_near_user, so keeping
  // a mirror of it in memory would only create something that could disagree
  // with the server. ProfileScreen holds the loaded value instead.
  bool _copied = false;

  bool get copied => _copied;

  // setRsvp lived here too, and is now PartyRepository.setRsvp -- a real
  // upsert, with the un-RSVP as the DELETE it always described itself as
  // being. The `hypeBumpOnJoin` parameter went with hype.

  void flashCopied() {
    _copied = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 1800), () {
      _copied = false;
      notifyListeners();
    });
  }

}
