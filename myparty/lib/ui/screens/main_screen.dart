import 'package:flutter/material.dart';
import 'map_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({Key? key}) : super(key: key);

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<String> _tabNames = [
    'Explore',
    'My Events',
    'Map',
    'Messages',
    'Profile',
  ];

  final List<Widget> _tabBodies = [
    const Center(
      child: Text(
        'Explore',
        style: TextStyle(color: Colors.purpleAccent, fontSize: 24),
      ),
    ),
    const Center(
      child: Text(
        'My Events',
        style: TextStyle(color: Colors.purpleAccent, fontSize: 24),
      ),
    ),
    const MapScreen(),
    const Center(
      child: Text(
        'Messages',
        style: TextStyle(color: Colors.purpleAccent, fontSize: 24),
      ),
    ),
    const Center(
      child: Text(
        'Profile',
        style: TextStyle(color: Colors.purpleAccent, fontSize: 24),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tabBodies[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.explore),
            label: 'Explore',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.event),
            label: 'My Events',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.message),
            label: 'Messages',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 1
          ? FloatingActionButton(
              onPressed: () {
                // TODO: Implement add event functionality
              },
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
