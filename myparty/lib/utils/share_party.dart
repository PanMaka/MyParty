import 'dart:convert';

import 'package:share_plus/share_plus.dart';

import 'party_link.dart';

/// Hands text to the system share sheet. A seam so widget tests can record
/// what would have been shared instead of opening a platform sheet.
typedef ShareText = Future<void> Function(String text);

Future<void> systemShare(String text) async {
  await SharePlus.instance.share(ShareParams(text: text));
}

/// Hands a text file to the system share sheet, which is also where "Save to
/// Files" / "Save to Drive" live: one sheet covers both sharing and saving.
/// A seam for the same reason as [ShareText].
typedef ShareFile = Future<void> Function({required String fileName, required String contents, required String mimeType});

/// Built in memory rather than saved to the app's documents first: an export
/// left there would be a second copy of everything the account holds,
/// outliving the account. share_plus still writes a temporary copy to the
/// app's cache for the hand-off, which the OS may clear at any time.
Future<void> systemShareFile({required String fileName, required String contents, required String mimeType}) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(utf8.encode(contents), mimeType: mimeType, name: fileName)],
    fileNameOverrides: [fileName],
  ));
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

/// What sharing a private party's INVITE link sends. No title, for the same
/// reason as [partyShareText]: the people in the chat it is pasted into are
/// not all invited yet, and the ones who open it will see the party anyway.
String inviteShareText(String token) =>
    'You’re invited to a private party on MyParty: ${inviteLink(token)}';
