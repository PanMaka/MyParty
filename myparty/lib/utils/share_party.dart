import 'package:share_plus/share_plus.dart';

import 'party_link.dart';

/// Hands text to the system share sheet. A seam so widget tests can record
/// what would have been shared instead of opening a platform sheet.
typedef ShareText = Future<void> Function(String text);

Future<void> systemShare(String text) async {
  await SharePlus.instance.share(ShareParams(text: text));
}

/// What sharing a party actually sends.
///
/// A public party's title goes with its link — it is on everyone's map
/// already. A private party's does NOT: the link is harmless to anyone not
/// invited (it opens nothing), but a title pasted into a group chat is read by
/// everyone in it, and a guest forwarding the link should not forward the
/// name of a party those people were not invited to.
String partyShareText({required String partyId, required String title, required bool isPrivate}) {
  final link = partyLink(partyId).toString();
  return isPrivate ? link : '$title on MyParty: $link';
}
