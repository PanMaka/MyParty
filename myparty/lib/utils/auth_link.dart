/// The two links an auth email can open the app with (Phase 47), parsed as
/// strictly as `party_link.dart` parses party links: one host, no port, no
/// userinfo, an exact path.
///
/// **Nothing here ever reads a token.** `detectSessionInUri` stays off
/// (`main.dart`), because a link that carries `access_token`/`refresh_token`
/// can sign anyone into the attacker's account. Restricting it to these paths
/// would not help: the attacker would simply use the allowed path. So:
///
///  * a reset link is accepted only as a PKCE `?code=`, which GoTrue redeems
///    only with the secret this phone stored when it asked for the reset. A
///    code from somebody else's request is refused (`bad_code_verifier`,
///    measured). Any link that also carries a token is dropped outright;
///  * an email-change link is a signal and nothing more. The change happens on
///    the server when each inbox confirms; the app only re-reads the account.
library;

import 'party_link.dart' show kPartyLinkHost;

/// Where GoTrue sends a reset link after it has checked the email token.
/// Must be in the project's redirect allow-list, exactly (config.toml, and
/// the hosted dashboard: backlog 1.44).
const kResetRedirect = 'https://$kPartyLinkHost/auth/reset';

/// Where GoTrue sends an email-change link.
const kEmailChangeRedirect = 'https://$kPartyLinkHost/auth/email-change';

/// What an auth link asked for.
sealed class AuthLink {
  const AuthLink();
}

/// A reset link carrying a PKCE code, to be exchanged for a session only if
/// this phone asked for a reset (`ResetRequestStore`).
class ResetLink extends AuthLink {
  const ResetLink(this.code);
  final String code;
}

/// A reset link GoTrue sent back with an error instead of a code: the token
/// had expired or had already been used (a mail scanner opening links does
/// this).
class ResetLinkFailed extends AuthLink {
  const ResetLinkFailed();
}

/// An email-change link. [confirmedOne] is true when GoTrue said one address is
/// confirmed and the other is still to come; [failed] when it sent an error.
class EmailChangeLink extends AuthLink {
  const EmailChangeLink({this.confirmedOne = false, this.failed = false});
  final bool confirmedOne;
  final bool failed;
}

// GoTrue's PKCE auth codes are uuids (measured: ?code=56237d44-469d-…).
final _code = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

const _tokenKeys = {'access_token', 'refresh_token', 'provider_token', 'provider_refresh_token', 'token_hash'};

/// The link's query and fragment parameters, together. GoTrue puts errors and
/// messages in the fragment and the PKCE code in the query.
Map<String, String> _params(Uri uri) {
  final params = <String, String>{...uri.queryParameters};
  if (uri.fragment.contains('=')) {
    try {
      params.addAll(Uri.splitQueryString(uri.fragment));
    } catch (_) {
      // An unparsable fragment is treated as no fragment.
    }
  }
  return params;
}

String? _authPath(Uri uri) {
  if (uri.scheme != 'https') return null;
  if (uri.host != kPartyLinkHost) return null;
  if (uri.hasPort && uri.port != 443) return null;
  if (uri.userInfo.isNotEmpty) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 2 || segments[0] != 'auth') return null;
  return segments[1];
}

/// Null for anything that is not one of the two auth links, and for any auth
/// link that carries a token: that shape is what a forged sign-in link looks
/// like, and nothing we send ever has it.
AuthLink? authLinkFrom(Uri uri) {
  final path = _authPath(uri);
  if (path == null) return null;
  final params = _params(uri);
  final hasError = params.containsKey('error') || params.containsKey('error_code');

  switch (path) {
    case 'reset':
      if (params.keys.any(_tokenKeys.contains)) return null;
      if (hasError) return const ResetLinkFailed();
      final code = params['code'];
      return code != null && _code.hasMatch(code) ? ResetLink(code) : null;
    case 'email-change':
      // Tokens here are ignored rather than refused: GoTrue's own completion
      // redirect carries them (measured), and nothing reads them anyway.
      if (hasError) return const EmailChangeLink(failed: true);
      final message = params['message'] ?? '';
      return EmailChangeLink(confirmedOne: message.toLowerCase().contains('other email'));
    default:
      return null;
  }
}
