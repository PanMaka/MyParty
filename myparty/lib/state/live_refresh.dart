import 'dart:async';

import 'package:flutter/widgets.dart';

import '../ui/widgets/mp_bottom_nav.dart' show MpTab;
import 'data_changes.dart';

/// The MainScreen tab on screen, or null when no tab shell is mounted.
///
/// Null is what a widget test that pumps one screen sees, and it means "every
/// screen counts as visible", so such a test observes a refetch at once rather
/// than one deferred to a tab switch that can never happen.
final ValueNotifier<MpTab?> visibleTab = ValueNotifier(null);

/// Bumped by MainScreen each time the app comes back after at least
/// [liveStaleAfter] in the background. Other people's writes — a new follower,
/// an rsvp on your party, an invitation — reach the client no other way.
final ValueNotifier<int> appResumes = ValueNotifier(0);

/// How old a tab's data may be before showing the tab refetches it.
///
/// Not zero: flicking between tabs must not cost a round trip per flick. Not
/// minutes: this is the only route by which other people's changes arrive on
/// most screens.
const Duration liveStaleAfter = Duration(seconds: 30);

/// Keeps a screen's data current without the user asking.
///
/// Three triggers, one rule — **patch now, refetch when visible**:
///
///  * a [DataChange] arrives in [onDataChange]. The screen patches what it can
///    locally (cheap, instant) and calls [refreshWhenVisible] for the rest;
///  * its tab is shown again after [liveStaleAfter], or after a change marked
///    it stale while hidden;
///  * the app resumes from the background ([appResumes]).
///
/// A hidden tab never refetches, it is only marked stale: four tabs refetching
/// on every write would be four round trips for one screen's worth of pixels.
///
/// [liveRefresh] must keep what is on screen until the new data lands — a
/// refresh that flashes a spinner over a correct list reads as a fault.
mixin LiveRefresh<T extends StatefulWidget> on State<T> {
  /// The tab this screen IS, or null for a screen pushed over the tabs (a
  /// pushed screen is visible for as long as it is mounted).
  MpTab? get liveTab;

  /// Refetches, keeping the current data on screen until the answer arrives.
  Future<void> liveRefresh();

  /// A write landed somewhere in the app. Default: nothing.
  void onDataChange(DataChange change) {}

  /// The screen's tab came on or went off screen. For holding something only
  /// while visible — a realtime subscription — rather than for refetching,
  /// which the mixin already does. Default: nothing.
  void onLiveVisibilityChanged(bool visible) {}

  StreamSubscription<DataChange>? _changes;
  DateTime _fetchedAt = DateTime.now();
  bool _stale = false;
  bool _wasVisible = true;

  bool get isLiveVisible {
    final mine = liveTab;
    final shown = visibleTab.value;
    return mine == null || shown == null || shown == mine;
  }

  @override
  void initState() {
    super.initState();
    _wasVisible = isLiveVisible;
    _changes = dataChanges.stream.listen((change) {
      if (mounted) onDataChange(change);
    });
    visibleTab.addListener(_onTabShown);
    appResumes.addListener(_onResume);
  }

  @override
  void dispose() {
    _changes?.cancel();
    visibleTab.removeListener(_onTabShown);
    appResumes.removeListener(_onResume);
    super.dispose();
  }

  /// What this screen shows is wrong now: refetch at once if it is on screen,
  /// otherwise the next time it is.
  void refreshWhenVisible() {
    if (!mounted) return;
    if (isLiveVisible) {
      _run();
    } else {
      _stale = true;
    }
  }

  void _onTabShown() {
    if (!mounted || liveTab == null) return;
    final visible = isLiveVisible;
    if (visible != _wasVisible) {
      _wasVisible = visible;
      onLiveVisibilityChanged(visible);
    }
    if (!visible) return;
    final old = DateTime.now().difference(_fetchedAt) >= liveStaleAfter;
    if (_stale || old) _run();
  }

  void _onResume() => refreshWhenVisible();

  void _run() {
    _stale = false;
    _fetchedAt = DateTime.now();
    unawaited(liveRefresh());
  }
}
