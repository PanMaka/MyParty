import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/mp_party.dart';

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
  final Map<String, bool> _interested = {
    'vinyl': true,
    'taratsa': true,
    'anodos': true,
    'maria': false,
    'kapsimo': false,
    'nefeli': true,
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
  bool interestedIn(String id) => _interested[id] ?? false;
  bool get copied => _copied;

  void bump(String id, int amount) {
    _hype[id] = math.min(100, (_hype[id] ?? 0) + amount);
    notifyListeners();
  }

  void toggleInterest(String id, {int hypeBumpOnJoin = 0}) {
    final next = !(_interested[id] ?? false);
    _interested[id] = next;
    if (next && hypeBumpOnJoin > 0) {
      _hype[id] = math.min(100, (_hype[id] ?? 0) + hypeBumpOnJoin);
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
