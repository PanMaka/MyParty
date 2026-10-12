import 'package:flutter/material.dart';

import '../../state/live_refresh.dart';
import '../widgets/mp_bottom_nav.dart';
import 'events_screen.dart';
import 'map_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  /// The tab the bar highlights. Follows the page as soon as a swipe crosses
  /// the halfway point, so the bar never lags the content under the finger.
  MpTab _tab = MpTab.map;

  /// The tab the pager last came to rest on. Swiping is decided by THIS rather
  /// than [_tab]: switching the pager's physics in the middle of a drag would
  /// cancel the drag that caused it, which is what dragging from Parties back
  /// onto the map would otherwise do.
  MpTab _settled = MpTab.map;

  late final PageController _pages = PageController(initialPage: _tab.index);

  /// An inner horizontal scroller (Parties/Direct, a carousel) has already
  /// handed this drag on to the pager; one drag moves one tab.
  bool _handedOff = false;

  /// Reports resumes to [appResumes], but only after [liveStaleAfter] away:
  /// a glance at a notification shade is not a reason for every screen to
  /// refetch.
  late final AppLifecycleListener _lifecycle;
  DateTime? _hiddenAt;

  @override
  void initState() {
    super.initState();
    visibleTab.value = _tab;
    _lifecycle = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final hiddenAt = _hiddenAt;
        _hiddenAt = null;
        if (hiddenAt != null &&
            DateTime.now().difference(hiddenAt) >= liveStaleAfter) {
          appResumes.value += 1;
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _pages.dispose();
    // No tab shell any more (signed out): screens built without one count as
    // visible, which is the right default for whatever is built next.
    visibleTab.value = null;
    super.dispose();
  }

  /// A tap on the bar, or a screen asking for another tab. Jumps rather than
  /// slides: animating Map → Profile would sweep two unrelated screens past.
  void _select(MpTab tab) {
    _pages.jumpToPage(tab.index);
    _settle(tab);
  }

  /// Only the bar's highlight. [visibleTab] waits for the swipe to land, so a
  /// half-swipe that springs back does not count as showing the other tab —
  /// [LiveRefresh] would refetch it for a screen nobody looked at.
  void _onPageChanged(int index) => setState(() => _tab = MpTab.values[index]);

  void _settle(MpTab tab) {
    if (tab == _settled && tab == _tab) return;
    setState(() {
      _tab = tab;
      _settled = tab;
    });
    visibleTab.value = tab;
  }

  /// The pager's own scroll events (depth 0) say when a swipe has landed; an
  /// inner horizontal scroller's (depth > 0) say when it has been dragged past
  /// its own edge, which is the moment to move the tab instead.
  ///
  /// Not a true hand-off of the drag — the inner scroller keeps the gesture —
  /// but it means a screen that is one big horizontal pager (Messages) does not
  /// trap the user on its tab.
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.horizontal) return false;

    if (n.depth == 0) {
      if (n is ScrollEndNotification) {
        _settle(MpTab.values[(_pages.page ?? _tab.index.toDouble()).round()]);
      }
      return false;
    }

    if (n is ScrollStartNotification) _handedOff = false;
    // The map pans; nothing on it may switch tabs.
    if (_handedOff || _settled == MpTab.map) return false;

    // Clamping physics (Android) report the push past the edge as overscroll;
    // bouncing physics (iOS) let the position run out of range instead.
    double past = 0;
    if (n is OverscrollNotification && n.dragDetails != null) {
      past = n.overscroll;
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final m = n.metrics;
      if (m.pixels < m.minScrollExtent) past = m.pixels - m.minScrollExtent;
      if (m.pixels > m.maxScrollExtent) past = m.pixels - m.maxScrollExtent;
    }
    // A few pixels of slop, so a carousel's own fling into its end stop does
    // not also flip the tab.
    if (past.abs() < 6) return false;

    final next = _settled.index + past.sign.toInt();
    if (next < 0 || next >= MpTab.values.length) return false;
    _handedOff = true;
    _pages.animateToPage(next, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: PageView(
              controller: _pages,
              onPageChanged: _onPageChanged,
              // Horizontal drags on the map pan the map. Leaving the map is a
              // tap on the bar; arriving on it by swipe is still allowed.
              physics: _settled == MpTab.map ? const NeverScrollableScrollPhysics() : null,
              children: [
                const _KeepAlive(child: MapScreen()),
                _KeepAlive(child: EventsScreen(onNavigate: _select)),
                const _KeepAlive(child: MessagesScreen()),
                // The signed-in user's own profile. Deliberately NOT their uuid
                // read out of the session here: ProfileRepository.fetchProfile
                // resolves the owner from auth.uid() itself, so passing one from
                // a widget would be both redundant and the only place in the app
                // where an identity travelled as an argument. It would also mean
                // reaching for Supabase.instance from a widget, which is the
                // thing the repository layer exists to prevent.
                const _KeepAlive(child: ProfileScreen(target: OwnProfile())),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MpBottomNav(current: _tab, onSelect: _select),
          ),
        ],
      ),
    );
  }
}

/// Keeps a tab mounted once it has been shown, as the IndexedStack this
/// replaced did: its state, its scroll position and its realtime listeners
/// survive switching away. A PageView otherwise disposes every page that
/// leaves the viewport.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
