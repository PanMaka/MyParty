import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/mp_party.dart';

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
  MpStore({bool autoDecay = true}) {
    if (autoDecay) {
      _decayTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
        _hype['vinyl'] = math.max(22, (_hype['vinyl'] ?? 64) - 1);
        _hype['taratsa'] = math.max(18, (_hype['taratsa'] ?? 41) - 1);
        notifyListeners();
      });
    }
  }

  final Map<String, int> _hype = {'vinyl': 64, 'taratsa': 41};

  /// The viewer's own answer per party, absent when they have not answered.
  ///
  /// A map with no entry rather than a `false`: the tri-state (none /
  /// interested / going) is the shape `rsvps` actually has, and a bool could
  /// not express "going" and "interested" as different answers to the same
  /// question. Private keys hold only [MpRsvp.going].
  final Map<String, MpRsvp> _rsvp = {
    'vinyl': MpRsvp.interested,
    'taratsa': MpRsvp.going, // private
    'anodos': MpRsvp.interested,
    'kapsimo': MpRsvp.going,
    'nefeli': MpRsvp.going, // private
    // 'maria' (private) is deliberately absent: no answer yet.
  };
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

  Timer? _decayTimer;

  Map<String, MpParty> get parties => mpParties;

  int hypeOf(String id) => _hype[id] ?? 0;

  /// The viewer's answer, or null if they have not given one.
  MpRsvp? rsvpFor(String id) => _rsvp[id];
  bool get copied => _copied;

  void bump(String id, int amount) {
    _hype[id] = math.min(100, (_hype[id] ?? 0) + amount);
    notifyListeners();
  }

  /// Answers [status] for [id], or withdraws the answer if it is already the
  /// current one.
  ///
  /// Tapping the selected button is the un-RSVP, and un-RSVP REMOVES the entry
  /// — the mock analogue of `delete from rsvps`. Tapping the other button on a
  /// public party replaces the answer in place, which is the `update rsvps set
  /// status` the counter trigger handles as a single delta.
  ///
  /// The hype bump is only ever applied on a public party, by the caller:
  /// a private party displays no hype at all, so bumping a number nothing
  /// renders would be state that exists only to be leaked later.
  void setRsvp(String id, MpRsvp status, {int hypeBumpOnJoin = 0}) {
    if (_rsvp[id] == status) {
      _rsvp.remove(id);
    } else {
      _rsvp[id] = status;
      if (hypeBumpOnJoin > 0) {
        _hype[id] = math.min(100, (_hype[id] ?? 0) + hypeBumpOnJoin);
      }
    }
    notifyListeners();
  }

  void flashCopied() {
    _copied = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 1800), () {
      _copied = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _decayTimer?.cancel();
    super.dispose();
  }
}
