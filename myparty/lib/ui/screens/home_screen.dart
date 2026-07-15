import 'package:flutter/material.dart';
import '../../services/auth_service.dart';
import 'main_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MyParty'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () async {
              await AuthService().signOut();
            },
          )
        ],
      ),
      // Use the main tabbed experience instead of a single map screen.
      body: const MainScreen(),
    );
  }
}