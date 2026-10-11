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
  MpTab _tab = MpTab.map;

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
    // No tab shell any more (signed out): screens built without one count as
    // visible, which is the right default for whatever is built next.
    visibleTab.value = null;
    super.dispose();
  }

  void _select(MpTab tab) {
    setState(() => _tab = tab);
    visibleTab.value = tab;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _tab.index,
            children: [
              const MapScreen(),
              EventsScreen(onNavigate: _select),
              const MessagesScreen(),
              // The signed-in user's own profile. Deliberately NOT their uuid
              // read out of the session here: ProfileRepository.fetchProfile
              // resolves the owner from auth.uid() itself, so passing one from
              // a widget would be both redundant and the only place in the app
              // where an identity travelled as an argument. It would also mean
              // reaching for Supabase.instance from a widget, which is the
              // thing the repository layer exists to prevent.
              const ProfileScreen(target: OwnProfile()),
            ],
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
