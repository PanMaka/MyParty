import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'ui/screens/auth_gate.dart';


Future<void> main() async {
  // Ensure Flutter binding is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Load the hidden variables from the .env file
  await dotenv.load(fileName: ".env");

  // Initialize Supabase using the loaded variables
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    publishableKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  runApp(const MyPartyApp());
}

class MyPartyApp extends StatelessWidget {
  const MyPartyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyParty',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D12),
        primaryColor: Colors.purpleAccent,
        colorScheme: ColorScheme.dark(
          primary: Colors.purpleAccent,
          secondary: Colors.purpleAccent,
          surface: const Color(0xFF0D0D12),
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: const Color(0xFF1A1A24),
          selectedItemColor: Colors.purpleAccent,
          unselectedItemColor: Colors.grey[600],
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: Colors.purpleAccent,
          foregroundColor: Colors.black,
        ),
      ),
      home: const AuthGate(), // <-- Changed from LoginScreen to AuthGate
    );
  }
}