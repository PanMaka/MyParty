/// Party links: `https://mypartycorp.com/p/<party uuid>`.
///
/// A link is a POINTER, not a key. It carries the party's id and nothing else
/// — no token, no inviter, no session — and opening it asks `get_party`, which
/// answers through the parties SELECT policy like every other read. So a
/// link to a private party is worthless to anyone not already invited, and a
/// leaked link leaks nothing. That is why it is safe to put in a share sheet,
/// a clipboard and a chat preview, all of which are places links leak from.
///
/// https on a domain we own rather than a `myparty://` scheme: any app may
/// register a custom scheme and receive its links, whereas an https App Link
/// is verified against `/.well-known/assetlinks.json` on the domain, so only
/// this app opens it. Nothing secret travels today, but this is the property
/// an invite token would need later, and https links are the ones messengers
/// make tappable.
library;

const kPartyLinkHost = 'mypartycorp.com';

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The shareable link for a party.
Uri partyLink(String partyId) => Uri(scheme: 'https', host: kPartyLinkHost, pathSegments: ['p', partyId]);

/// The party id in [uri], or null when [uri] is not exactly a party link.
///
/// Strict on purpose — a link arrives from outside the app and is untrusted
/// input. https only, our host only, exactly `/p/<lowercase uuid>`, with an
/// optional trailing slash. Query and fragment are IGNORED rather than read:
/// nothing a link could carry there is ever acted on, so a link padded with
/// tokens or parameters opens the same party as a clean one and nothing more.
String? partyIdFromLink(Uri uri) {
  if (uri.scheme != 'https') return null;
  if (uri.host != kPartyLinkHost && uri.host != 'www.$kPartyLinkHost') return null;
  if (uri.hasPort && uri.port != 443) return null;
  if (uri.userInfo.isNotEmpty) return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 2 || segments[0] != 'p') return null;

  final id = segments[1];
  return _uuid.hasMatch(id) ? id : null;
}
