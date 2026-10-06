import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'services/notifications.dart';
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
    // OFF, and this is a security setting rather than a preference. When on,
    // supabase_flutter inspects EVERY link that opens the app, and a link
    // carrying access_token/refresh_token/expires_in/token_type is validated
    // only as "a real user's token" and then saved as the session (gotrue's
    // getSessionFromUrl, PKCE or not). Once party links open the app, that
    // is one tap from login CSRF: a link built from the attacker's own
    // tokens silently swaps the victim into the attacker's account, and
    // everything they post, upload or export afterwards lands where the
    // attacker can read it. Nothing here signs in through a link (no email
    // confirmation, password reset or OAuth), so this costs nothing today.
    // If one of those arrives, re-enable it with detectSessionInUriPredicate
    // restricted to that one callback path, never globally.
    authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
  );

  // Phase 7c. Firebase, plus the background message handler — which has to be
  // registered before runApp, because a push can wake the app into a state
  // where no widget has been built yet. Never throws: with no Firebase config
  // present this logs and the app runs with push unavailable.
  await Notifications.initialise();

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