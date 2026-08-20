import 'package:flutter/material.dart';

import '../widgets/mp_bottom_nav.dart';
import 'events_screen.dart';
import 'feed_screen.dart';
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

  void _select(MpTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _tab.index,
            children: [
              const FeedScreen(),
              EventsScreen(onNavigate: _select),
              const MapScreen(),
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
