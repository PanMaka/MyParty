import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'state/mp_store.dart';
import 'ui/screens/auth_gate.dart';
import 'ui/theme/app_theme.dart';


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
    return ChangeNotifierProvider(
      create: (_) => MpStore(),
      // Above MaterialApp so every route on the Navigator (pushed screens,
      // modal bottom sheets) can reach it — routes are siblings on the
      // Navigator, not descendants of whichever screen pushed them.
      child: MaterialApp(
        title: 'MyParty',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const AuthGate(), // <-- Changed from LoginScreen to AuthGate
      ),
    );
  }
}