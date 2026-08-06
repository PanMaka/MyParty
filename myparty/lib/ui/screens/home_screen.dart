import 'package:flutter/material.dart';
import 'main_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // MainScreen owns the full immersive shell (its own nav, no app bar).
    return const MainScreen();
  }
}