import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// Make sure main() is async because we have to wait for the environment 
// variables and Supabase to initialize before running the app.
Future<void> main() async {
  // Ensure Flutter binding is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Load the hidden variables from the .env file
  await dotenv.load(fileName: ".env");

  // Initialize Supabase using the loaded variables
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
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
        // We will set up your dark glassmorphism theme here later
        scaffoldBackgroundColor: Colors.black, 
        primarySwatch: Colors.deepPurple,
      ),
      home: const Scaffold(
        body: Center(
          child: Text(
            'Supabase Initialized Successfully!',
            style: TextStyle(color: Colors.white, fontSize: 20),
          ),
        ),
      ),
    );
  }
}