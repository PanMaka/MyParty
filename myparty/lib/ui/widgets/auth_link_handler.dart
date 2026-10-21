import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/party_links.dart';
import '../../utils/auth_link.dart';
import '../../utils/auth_messages.dart';
import '../screens/forgot_password_screen.dart';

/// Acts on the two auth links (Phase 47), signed in or out, unlike
/// `PartyLinkHandler`, which waits for an onboarded session.
///
/// Sits above `AuthGate` as the home route's content, so it has the app's
/// Navigator and ScaffoldMessenger whichever screen the gate is showing.
///
///  * A reset link is exchanged only through [AuthService.openResetLink],
///    which refuses unless THIS phone asked for a reset for that address in
///    the last hour. On success the new-password step opens over everything.
///  * An email-change link exchanges nothing: the server already applied that
///    confirmation. The handler re-reads the account and says where it stands.
class AuthLinkHandler extends StatefulWidget {
  const AuthLinkHandler({super.key, required this.child, this.authService, this.links});

  final Widget child;
  final AuthService? authService;

  /// Defaults to [PartyLinks.pendingAuth]; injectable for tests.
  final ValueNotifier<AuthLink?>? links;

  @override
  State<AuthLinkHandler> createState() => _AuthLinkHandlerState();
}

class _AuthLinkHandlerState extends State<AuthLinkHandler> {
  late final AuthService _auth = widget.authService ?? AuthService();
  late final ValueNotifier<AuthLink?> _links = widget.links ?? PartyLinks.pendingAuth;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    _links.addListener(_onLink);
    // A link that launched the app arrived before this widget existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLink());
  }

  @override
  void dispose() {
    _links.removeListener(_onLink);
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  Future<void> _onLink() async {
    final link = _links.value;
    if (link == null || _handling || !mounted) return;
    // Consumed before acting, so a rebuild or a second listener never runs it
    // twice.
    _links.value = null;
    _handling = true;
    try {
      switch (link) {
        case ResetLink():
          await _openReset(link);
        case ResetLinkFailed():
          _snack(resetLinkExpiredMessage);
        case EmailChangeLink():
          await _emailChange(link);
      }
    } catch (_) {
      _snack(somethingWentWrongMessage);
    } finally {
      _handling = false;
    }
  }

  Future<void> _openReset(ResetLink link) async {
    final outcome = await _auth.openResetLink(link);
    if (!mounted) return;
    switch (outcome) {
      case ResetLinkOutcome.ready:
        final navigator = Navigator.of(context);
        navigator.popUntil((route) => route.isFirst);
        navigator.push(MaterialPageRoute(
          builder: (_) => ForgotPasswordScreen(authService: _auth, startAtNewPassword: true),
        ));
      case ResetLinkOutcome.notRequestedHere:
        _snack(resetLinkNotRequestedHere);
      case ResetLinkOutcome.expired:
        _snack(resetLinkExpiredMessage);
    }
  }

  Future<void> _emailChange(EmailChangeLink link) async {
    if (link.failed) {
      _snack(emailChangeLinkFailed);
      return;
    }
    if (_auth.currentEmail == null) {
      _snack(emailChangeLinkSignedOut);
      return;
    }
    await _auth.reloadUser();
    if (_auth.pendingNewEmail != null) {
      _snack(emailChangeLinkConfirmedOne);
    } else {
      _snack(emailChangedMessage(_auth.currentEmail!));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
