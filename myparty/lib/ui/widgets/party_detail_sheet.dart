import 'package:flutter/material.dart';

import '../../models/party_list_item.dart';
import '../../state/mp_store.dart' show MpRsvp;
import '../../utils/english_date.dart';
import '../screens/chat_screen.dart';
import '../screens/story_viewer_screen.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';

Future<void> showPartyDetailSheet(
  BuildContext context,
  PartyListItem item, {
  String? coverUrl,
  ValueChanged<MpRsvp>? onRsvp,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PartyDetailSheet(item: item, coverUrl: coverUrl, onRsvp: onRsvp),
  );
}

/// Opens the party's group chat.
///
/// **PRIVATE ONLY** — `can_chat_in_party` has been
/// `can_access_party AND party_is_private` since 20260825094044, so a public
/// party has no chat to open. Callers guard on [PartyListItem.isPrivate];
/// this asserts rather than silently no-ops, because a public party reaching
/// here means a guard was dropped and the server would answer the first send
/// with a 42501 anyway.
void openPartyChat(BuildContext context, PartyListItem item) {
  assert(item.isPrivate, 'a public party has no group chat (20260825094044)');
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChatScreen(
      partyId: item.partyId,
      partyTitle: item.title,
      isPrivate: item.isPrivate,
      // Null on a private party, which is correct: the header renders no
      // member count when it has none rather than printing a 0.
      memberCount: item.goingCount,
    ),
  ));
}

/// The party's story reel.
///
/// Gated by the WIDE `can_access_party`, not `can_chat_in_party` — deliberately
/// the opposite call from chat. A story is read-only content attached to a
/// party, so anyone who may look at the party may watch its reel; chat is
/// writable, which is why it narrows to participants. Nothing is re-checked
/// here: `get_party_stories` is invoker-rights and RLS answers it.
void openPartyStories(BuildContext context, PartyListItem item) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => StoryViewerScreen(
      partyId: item.partyId,
      partyTitle: item.title,
      isPrivate: item.isPrivate,
    ),
  ));
}

/// The party detail sheet, on a real `parties` row.
///
/// **Both of its dead ends are gone.** The "Group chat" button and the story
/// tiles were placeholders for one reason and one reason only: this sheet was
/// driven by the const `mpParties` map, whose keys were strings like
/// `'taratsa'`, and `ChatScreen`/`StoryViewerScreen` both need a real
/// `parties.id`. Phase 18 gave the sheet a uuid, so both now open the real
/// screens. That was the whole of CLAUDE.md's "one job, not three".
///
/// Three fields did NOT survive the move, because no column answers them:
/// `hostSub` ("your friend · 3rd party this year"), `dist` ("400 m") and
/// `posters` ("11 people posting"). Distance is not gone from the app — it is
/// still on `MapPinSheet`, which is a spatial query and therefore knows it.
class PartyDetailSheet extends StatelessWidget {
  const PartyDetailSheet({
    super.key,
    required this.item,
    this.coverUrl,
    this.onRsvp,
  });

  final PartyListItem item;
  final String? coverUrl;
  final ValueChanged<MpRsvp>? onRsvp;

  @override
  Widget build(BuildContext context) {
    final priv = item.isPrivate;
    final rsvp = item.myRsvp;

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cover(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    _chip(formatPartyStartEn(item.startsAt), mono: true),
                    if (item.area != null) _chip(item.area!),
                    // The attendance chip. Absent rather than empty on a
                    // private row, and `attendeeLabel` is null exactly when
                    // the server sent NULL counts — so there is no number here
                    // to forget to hide. Time and area stay: they are
                    // properties of the event, not of who is at it.
                    if (item.attendeeLabel != null) _chip(item.attendeeLabel!),
                  ],
                ),
              ),
              if (item.description != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Text(item.description!,
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.textAlpha(0.75))),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('THE PARTY STORY',
                        style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.5))),
                    const SizedBox(height: 9),
                    GestureDetector(
                      // A real reel now. The tiles stay placeholders visually
                      // — the sheet does not fetch the story list, and adding
                      // a second round trip to draw three thumbnails behind a
                      // tap is not worth it — but the TAP is real and lands on
                      // the party's actual stories.
                      onTap: () => openPartyStories(context, item),
                      child: Row(
                        children: [
                          for (var i = 0; i < 3; i++)
                            Expanded(
                              child: Container(
                                margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
                                height: 76,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(11),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                                ),
                                child: DiagonalStripePlaceholder(
                                  colors: const [Color(0xFF1D1730), Color(0xFF161126)],
                                  borderRadius: BorderRadius.circular(11),
                                  childAlignment: Alignment.center,
                                  child: i == 1
                                      ? Icon(Icons.play_arrow_rounded,
                                          size: 22, color: AppColors.textAlpha(0.5))
                                      : const SizedBox.shrink(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // One answer on a private party, two on a public one --
                    // 20260825090050 refuses an 'interested' rsvp on a private
                    // party.
                    if (!item.acceptsInterested)
                      _cta(
                        label: 'Coming',
                        selected: rsvp == MpRsvp.going,
                        gradient: AppColors.privateGradient,
                        accent: AppColors.private,
                        onTap: () => _answer(context, MpRsvp.going),
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: _cta(
                              label: 'Going',
                              selected: rsvp == MpRsvp.going,
                              gradient: AppColors.purpleGradient,
                              accent: AppColors.purple,
                              onTap: () => _answer(context, MpRsvp.going),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _cta(
                              label: 'Interested',
                              selected: rsvp == MpRsvp.interested,
                              gradient: AppColors.purpleGradient,
                              accent: AppColors.purple,
                              onTap: () => _answer(context, MpRsvp.interested),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        // PRIVATE only. A public party has no group chat since
                        // 20260825094044, so the entry point is gone rather
                        // than disabled -- and on a private party it is no
                        // longer a placeholder.
                        if (priv) ...[
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => openPartyChat(context, item),
                              style: _secondaryStyle,
                              child: const Text('Group chat', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: OutlinedButton(
                            // Still a placeholder, and for a reason that did
                            // NOT go away with mpParties: this list is not a
                            // spatial query, so the row carries no coordinates
                            // to hand a maps intent. Directions work from the
                            // map, which has them.
                            onPressed: () => comingSoon(context),
                            style: _secondaryStyle,
                            child: const Text('Directions', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      priv
                          ? 'Only the guests can see this. The address shows up nowhere else.'
                          : 'Public party — everyone on the map can see it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.35)),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Answers, then closes.
  ///
  /// The sheet does not hold RSVP state: it was handed an immutable row, so
  /// re-rendering a new selection would mean re-fetching. Closing hands the
  /// question back to the list, which owns both the write and the refresh —
  /// and the list is where the user sees the result anyway.
  void _answer(BuildContext context, MpRsvp status) {
    Navigator.of(context).pop();
    onRsvp?.call(status);
  }

  Widget _cover(BuildContext context) {
    return SizedBox(
      height: 196,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (coverUrl != null)
            Image.network(coverUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => _coverPlaceholder())
          else
            _coverPlaceholder(),
          Container(
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [AppColors.sheet, Colors.transparent],
                stops: [0.03, 0.75],
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 16, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Row(
              children: [
                PrivacyBadge(
                  isPrivate: item.isPrivate,
                  suffix: item.isPrivate ? 'INVITE ONLY' : null,
                  fontSize: 9,
                ),
                if (item.isLive) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('NOW', style: AppTextStyles.mono(size: 9)),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
                const SizedBox(height: 4),
                Text(
                  // Replaces `sub` ("Private · Dimitris invited you"), built
                  // from columns instead of from a hand-written string. The
                  // invited clause is only true when it is true: is_invited is
                  // a property of the CALLER, like my_rsvp_status.
                  [
                    item.isPrivate ? 'Private' : 'Public',
                    '@${item.hostUsername}',
                    if (item.isPrivate && item.isInvited) 'you are invited',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.68)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => DiagonalStripePlaceholder(
        colors: item.isPrivate
            ? const [Color(0xFF221A2A), Color(0xFF191320)]
            : const [Color(0xFF1F1936), Color(0xFF171229)],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        label: item.isPrivate ? 'private party' : 'no cover yet',
      );

  Widget _chip(String text, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
      child: mono
          ? Text(text, style: AppTextStyles.mono(size: 11.5, weight: FontWeight.w600))
          : Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500)),
    );
  }
}

final ButtonStyle _secondaryStyle = OutlinedButton.styleFrom(
  padding: const EdgeInsets.symmetric(vertical: 12),
  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
  backgroundColor: Colors.white.withValues(alpha: 0.06),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
  foregroundColor: AppColors.text,
);

/// One RSVP answer in the sheet's footer, lit when it is the viewer's current
/// one. Mirrors PartyCard's `_rsvpButton` at sheet scale.
///
/// Tapping the lit one withdraws the answer -- a DELETE of the row, not a
/// third enum value.
Widget _cta({
  required String label,
  required bool selected,
  required Gradient gradient,
  required Color accent,
  required VoidCallback onTap,
}) {
  return SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        backgroundColor: Colors.transparent,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Ink(
        decoration: BoxDecoration(
          gradient: selected ? null : gradient,
          color: selected ? accent.withValues(alpha: 0.16) : null,
          border: selected ? Border.all(color: accent) : null,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            selected ? '$label ✓' : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ),
  );
}

/// For the affordances that are STILL placeholders after Phase 18.
///
/// That is now only "Directions", and for a reason mpParties was never
/// responsible for: this list is not a spatial query, so the row carries no
/// coordinates. Chat and stories stopped needing this the moment the sheet had
/// a uuid.
void comingSoon(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Coming soon'), behavior: SnackBarBehavior.floating),
  );
}
