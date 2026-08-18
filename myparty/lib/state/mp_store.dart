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
  final Map<String, bool> _invited = {
    'eleni': true,
    'aris': true,
    'zoi': false,
    'lefteris': false,
  };
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
  bool invited(String friendId) => _invited[friendId] ?? false;
  int get invitedCount => _invited.values.where((v) => v).length;

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

  void toggleInvited(String friendId) {
    _invited[friendId] = !(_invited[friendId] ?? false);
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
