import '../ui/widgets/auth_branding.dart';

/// What has been typed into the sign-in / sign-up forms, kept so stepping back
/// returns to a filled form instead of an empty one.
///
/// Needed because the screens do not survive the trip: the username screen's
/// back arrow signs out, which makes AuthGate build a brand-new LoginScreen and
/// the register screen is pushed fresh on top of it. Their own State objects
/// are gone; this is what outlives them.
///
/// Memory only, never written to disk — it holds a password. Cleared once
/// onboarding completes, and dies with the process otherwise.
class AuthDrafts {
  AuthDrafts._();

  static final AuthDrafts instance = AuthDrafts._();

  String loginEmail = '';
  String loginPassword = '';

  String registerEmail = '';
  String registerPassword = '';
  DateTime? registerDateOfBirth;
  Gender? registerGender;

  String firstName = '';
  String lastName = '';
  String username = '';

  void clear() {
    loginEmail = '';
    loginPassword = '';
    registerEmail = '';
    registerPassword = '';
    registerDateOfBirth = null;
    registerGender = null;
    firstName = '';
    lastName = '';
    username = '';
  }
}
