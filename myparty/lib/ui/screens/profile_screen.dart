import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/social_repository.dart';
import '../../models/feed_post.dart';
import '../../models/hosted_parties.dart';
import '../../models/party_summary.dart';
import '../../models/profile.dart';
import '../../models/profile_stats.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/follow_button.dart';
import '../widgets/profile_party_card.dart';
import '../widgets/report_sheet.dart';
import 'host_wizard_screen.dart';
import 'profile_edit_screen.dart';
import 'settings_screen.dart';

/// Whose profile the screen is showing, and — when it is the owner's — whether
/// they are previewing how it looks to everybody else.
///
/// This replaces a `String? userId` paired with a `bool _selfView`, which
/// spelled four states when only three exist. The missing constraint was
/// `userId != null && _selfView == true`: someone else's profile rendering the
/// OWNER sections — your hosted-party list, and the gear that opens your
/// privacy tiers, your notification settings, your account-deletion row and
/// your sign-out button. Nothing in the old type prevented it — the tab bar
/// simply never passed a `userId`, so it never happened. The moment step 5
/// makes the tab bar pass one, "never happens" stops being true, so the state
/// is made unrepresentable instead.
///
/// The two render questions are answered here, once, rather than at each of the
/// six call sites that used to re-derive them from the bool.
sealed class ProfileTarget {
  const ProfileTarget();

  /// What to hand a repository, where null means "resolve from the session".
  ///
  /// Never an identity claim: [ProfileRepository.fetchProfile] resolves the
  /// owner from `auth.uid()` itself, and [OwnProfile] deliberately carries no
  /// uuid to pass — there is nothing here that could be wrong.
  String? get userIdOrNull;

  /// Whether the owner-only content renders — today that is the hosted-party
  /// list, which comes from `get_my_hosted_parties` and has no user id to point
  /// at anybody else. The settings themselves are a screen away now, behind the
  /// gear, which [OwnProfile] gates on its own.
  bool get showsOwnerSections;

  /// Whether the follow button and the report menu render **and work**.
  ///
  /// True only on another user's profile. You cannot follow or report yourself,
  /// and no value of this type makes both this and [showsOwnerSections] true.
  ///
  /// The owner's public preview draws a follow button and stays false here.
  /// That is not a contradiction: the preview renders an inert lookalike, and
  /// this flag guards the wiring — a repository call and a write against a real
  /// relationship — not the pixels.
  bool get showsRelationshipActions;
}

/// The signed-in user's own profile. Carries no uuid on purpose — see
/// [ProfileTarget.userIdOrNull].
final class OwnProfile extends ProfileTarget {
  const OwnProfile({this.previewingPublicView = false});

  /// The ME / PUBLIC segment.
  ///
  /// Changes which sections render, and — since the preview is supposed to
  /// answer "what does a visitor see" — what the action row draws: a visitor
  /// gets a follow button, never "Host a party" and "Edit profile", so the
  /// preview draws a follow button too.
  ///
  /// It is a drawing, not a relationship. [showsRelationshipActions] stays
  /// false here, because you cannot follow, message or report yourself and
  /// nothing in the preview may reach the database on your own row. See
  /// [FollowButtonPreview].
  final bool previewingPublicView;

  @override
  String? get userIdOrNull => null;

  @override
  bool get showsOwnerSections => !previewingPublicView;

  @override
  bool get showsRelationshipActions => false;
}

/// Somebody else's profile. There is no public-view toggle because there is no
/// other view to toggle to.
final class OtherProfile extends ProfileTarget {
  const OtherProfile(this.userId);

  final String userId;

  @override
  String? get userIdOrNull => userId;

  @override
  bool get showsOwnerSections => false;

  @override
  bool get showsRelationshipActions => true;
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.target = const OwnProfile(),
    this.repository,
    this.social,
    this.parties,
  });

  /// Injectable so widget tests can subclass [ProfileRepository] without a
  /// Supabase client ever existing, the same way [SettingsScreen] takes one.
  final ProfileRepository? repository;

  /// Injectable for the same reason. Needed now that the FOLLOWING rail loads
  /// on the owner's public preview too: it used to be unreachable without a
  /// `userId`, so no test ever caused a [SocialRepository] method to run.
  final SocialRepository? social;

  /// Injectable for the same reason again. [PartyRepository] had to be moved
  /// to a lazy client before this was possible at all.
  final PartyRepository? parties;

  /// Whose profile this is. Defaults to the signed-in user, which is how the
  /// tab bar mounts it.
  final ProfileTarget target;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final SocialRepository _social = widget.social ?? SocialRepository();
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();
  late final PartyRepository _parties = widget.parties ?? PartyRepository();

  /// Mutable only through the ME / PUBLIC segment, and only ever between the
  /// two [OwnProfile] values — an [OtherProfile] never becomes an [OwnProfile].
  late ProfileTarget _target = widget.target;

  late final Future<List<Profile>> _theirFollowing = _social.fetchFollowing(
    userId: widget.target.userIdOrNull,
  );

  /// The owner's whole party list, plus the signed cover URLs it renders with.
  ///
  /// One future for both because a card is not renderable until both halves
  /// are in, and two futures would make every card flip from placeholder to
  /// photo a beat after it appeared. Owner-only: `get_my_hosted_parties` takes
  /// no user id, so this cannot be pointed at [OtherProfile] even by mistake.
  late final Future<(HostedParties, Map<String, String>)> _myParties = _loadMyParties();

  /// Public parties this profile has already hosted — the PUBLIC PARTIES card.
  /// `publicOnly` because the heading says public; see [PartyRepository].
  late final Future<List<PartySummary>> _hostedPublicPast = _parties.fetchHostedParties(
    hostId: widget.target.userIdOrNull,
    window: PartyWindow.past,
    publicOnly: true,
    limit: 3,
  );


  Profile? _profile;
  ProfileStats _stats = ProfileStats.empty;

  /// Header state. [_profile] non-null wins over both of these, so a reload in
  /// the background never blanks a header that already has something true to
  /// show.
  bool _loading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = _target.userIdOrNull;
    try {
      final profile = await _profiles.fetchProfile(userId: id);
      final stats = await _profiles.fetchStats(userId: id);

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _stats = stats;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  /// Fetches the list, then signs the covers for it.
  ///
  /// Sequential rather than concurrent because the second call's argument IS
  /// the first call's result — there is nothing to overlap.
  ///
  /// A failed signing does not fail the list. Every card falls back to its
  /// uuid-keyed gradient when a URL is missing, so losing the images costs
  /// decoration; losing the list costs the content. Swallowed here rather than
  /// surfaced for that reason, and only here — the list's own failure still
  /// reaches the FutureBuilder.
  Future<(HostedParties, Map<String, String>)> _loadMyParties() async {
    final parties = await _parties.fetchMyHostedParties();

    var covers = const <String, String>{};
    try {
      covers = await _parties.signedCoverUrls([...parties.upcoming, ...parties.past]);
    } catch (_) {
      // Placeholders, then.
    }

    return (parties, covers);
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _load();
  }

  /// Opens the editor and re-reads the profile when it closes.
  ///
  /// Unconditional rather than gated on the popped value: "nothing changed" is
  /// the cheap case and being wrong about it leaves a stale bio or a stale
  /// avatar on screen, which is the one outcome a fresh fetch cannot produce.
  Future<void> _openEditor() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
    if (mounted) await _load();
  }

  void _comingSoon() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Coming soon'), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Profile',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                  ),
                  // Only the owner gets the toggle: it previews YOUR public
                  // profile, and there is no second view of somebody else's.
                  // The gear beside it is owner chrome for the same reason —
                  // and it stays put in the public preview, along with the
                  // segment it sits next to, because previewing your profile
                  // does not take your own settings away from you.
                  if (_target case final OwnProfile own)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Row(
                            children: [
                              _segment(
                                'ME',
                                !own.previewingPublicView,
                                () => setState(() => _target = const OwnProfile()),
                              ),
                              _segment(
                                'PUBLIC',
                                own.previewingPublicView,
                                () => setState(
                                  () => _target = const OwnProfile(previewingPublicView: true),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _settingsButton(),
                      ],
                    ),
                ],
              ),
            ),
            _header(),
            // Two tiles, and the same two for every viewer.
            //
            // Gated on a loaded profile rather than defaulting to 0, for the
            // reason _headerBody already gives below: "0 FOLLOWERS" sitting
            // under "This profile is not available" asserts that an account
            // exists and that nobody follows it, when what actually happened is
            // that the SELECT policy filtered the row or it is not there.
            //
            // Three counters that used to render here are gone rather than
            // moved. ProfileStats still carries all of them and
            // get_profile_stats still returns them; nothing draws them:
            //
            //  * `stories` — no tile in the two-tile layout.
            //  * `πάρτι φέτος` (`parties_attended`) — was owner-only, because
            //    get_profile_stats runs with invoker rights and the `rsvps`
            //    SELECT policy is `user_id = auth.uid() OR I host it`, which
            //    makes it structurally zero for any other viewer. Dropping it
            //    also removes the last thing that made this row's SHAPE depend
            //    on who is looking.
            //  * `following_count` — see _headerBody.
            if (_profile case final loaded?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    // follower_count, and labelled as followers. The prototype
                    // said "184 φίλοι", naming a relation this schema cannot
                    // represent: the graph is follows-only and asymmetric,
                    // there is no `friendships` table, and its absence is a
                    // decision rather than a gap (docs/backend-plan.md 3.1,
                    // reversed on purpose). Calling followers friends would
                    // imply a mutual, consented edge to a user looking at a
                    // number that is neither.
                    Expanded(child: _statTile('${loaded.followerCount}', 'FOLLOWERS')),
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('${_stats.partiesHosted}', 'HOSTED', pink: true)),
                  ],
                ),
              ),
            _actionRow(),
            // The owner's half of the screen is now one thing: their parties.
            // Privacy, notifications, account deletion and sign out moved
            // behind the gear in the header — see [SettingsScreen].
            if (_target.showsOwnerSections) _myPartyList() else ..._publicSections(context),
          ],
        ),
      ),
    );
  }

  /// The owner's party list: one heading, two groups, one request.
  ///
  /// Replaces ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ (upcoming hosted) and ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ (past
  /// ATTENDED). The second is gone rather than moved: both groups here are
  /// about hosting, so the list reads `parties` and never `rsvps` — which is
  /// also what makes it structurally incapable of the lie that a merged
  /// host+attend list would tell on somebody else's profile.
  ///
  /// Loading and error are shared by both groups, deliberately. There is ONE
  /// request behind this, so a per-group spinner would be describing a fetch
  /// that is not happening — two "…" placeholders for one round trip is
  /// theatre, and it would also imply the groups can fail independently when
  /// they cannot. Empty IS per group, because a host with nothing coming up
  /// and a shelf full of past parties is two different true statements.
  Widget _myPartyList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: FutureBuilder<(HostedParties, Map<String, String>)>(
        future: _myParties,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _partyListShell(null, _sectionNotice('…'));
          }
          if (snapshot.hasError) {
            return _partyListShell(null, _sectionNotice('Your parties did not load'));
          }

          final (parties, covers) = snapshot.data ?? (HostedParties.empty, const <String, String>{});

          // Both groups empty is ONE absence, not two. Printing HOSTING and
          // PAST over a pair of empty notices would make an account that
          // has simply never hosted look like a screen that failed twice.
          if (parties.isEmpty) {
            return _partyListShell(
              null,
              _sectionNotice('You have not hosted a party yet.'),
            );
          }

          return _partyListShell(
            parties.total,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _partyGroup(
                  'HOSTING',
                  parties.upcoming,
                  covers,
                  relationship: 'hosting',
                  emptyMessage: 'You are not hosting anything right now.',
                ),
                // The line between the two categories. A real divider rather
                // than extra whitespace, because the groups are read as one
                // list and the boundary is the only thing saying where "ahead"
                // stops and "behind" starts.
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Container(height: 1, color: AppColors.hairline),
                ),
                _partyGroup(
                  'PAST',
                  parties.past,
                  covers,
                  relationship: 'hosted',
                  emptyMessage: 'No past parties yet.',
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The heading and whatever goes under it.
  ///
  /// [total] null means "not known yet" and prints the bare word. It is never
  /// defaulted to 0: "PARTIES · 0" over a spinner asserts that the user hosts
  /// nothing, which is a claim this screen has not finished checking — and on
  /// a slow connection it would be the first thing they read.
  Widget _partyListShell(int? total, Widget body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          total == null ? 'PARTIES' : 'PARTIES · $total',
          style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45)),
        ),
        const SizedBox(height: 9),
        body,
      ],
    );
  }

  /// One group: its label, and either its cards or its own empty line.
  ///
  /// [relationship] is passed down rather than derived in the card, because
  /// the `parties` row does not know who is looking at it. Both values are
  /// "you host this" in different tenses today — the list is hosted-only, so
  /// there is deliberately no enum here carrying `going`/`interested` arms
  /// that nothing can currently produce.
  Widget _partyGroup(
    String label,
    List<PartySummary> parties,
    Map<String, String> covers, {
    required String relationship,
    required String emptyMessage,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.35))),
        const SizedBox(height: 8),
        if (parties.isEmpty)
          _sectionNotice(emptyMessage)
        else
          for (final party in parties)
            Padding(
              padding: EdgeInsets.only(bottom: party == parties.last ? 0 : 8),
              child: ProfilePartyCard(
                party: party,
                relationship: relationship,
                // Absent for a party with no cover AND for one whose URL did
                // not sign. The card draws the same placeholder either way,
                // which is the truth in both cases: there is no image here.
                coverUrl: covers[party.id],
              ),
            ),
      ],
    );
  }

  List<Widget> _publicSections(BuildContext context) {
    // The follow / message / report row used to open this list, gated on an
    // OtherProfile. It has moved into _actionRow directly under the header,
    // because the owner now has a pair of buttons in that same slot — and one
    // widget switching on the target beats two sections each rendering half the
    // answer to the same question.
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PUBLIC PARTIES THEY HOSTED',
              style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45)),
            ),
            const SizedBox(height: 9),
            FutureBuilder<List<PartySummary>>(
              future: _hostedPublicPast,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _sectionNotice('…');
                }
                if (snapshot.hasError) {
                  return _sectionNotice('The parties did not load');
                }
                final parties = snapshot.data ?? const <PartySummary>[];
                if (parties.isEmpty) {
                  return _sectionNotice('No public parties yet.');
                }
                return Column(
                  children: [
                    for (final party in parties)
                      Padding(
                        padding: EdgeInsets.only(bottom: party == parties.last ? 0 : 8),
                        child: _pastPublicPartyCard(party),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: Colors.white.withValues(alpha: 0.13)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 16, color: AppColors.textAlpha(0.45)),
              const SizedBox(width: 9),
              // Was "τα ιδιωτικά πάρτι της Κατερίνας". Not merely a stale
              // literal now: under a real header it would name the wrong
              // person, and on the owner's own public preview it would name
              // somebody else entirely. Phrased without a possessive rather
              // than interpolating the handle, because Greek would force a
              // gendered article (του/της) onto a schema that stores no gender
              // and has no business guessing one.
              Expanded(
                child: Text(
                  'The private parties on this profile, and their stories, are not visible to you.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.5)),
                ),
              ),
            ],
          ),
        ),
      ),
      // Was "ΚΟΙΝΟΙ ΦΙΛΟΙ", rendered from the const mpFriends list. There is
      // no friendship in the schema — only the asymmetric follow graph — so
      // this is now who they follow, and it only renders for a real profile.
      // Now loads on the owner's public preview too, not just on somebody
      // else's profile: the rail is part of what other people see, so a preview
      // that omitted it would be previewing the wrong page.
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: FutureBuilder<List<Profile>>(
            future: _theirFollowing,
            builder: (context, snapshot) {
              final people = snapshot.data ?? const <Profile>[];
              if (people.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FOLLOWING · ${people.length}',
                    style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45)),
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      for (final f in people.take(3))
                        Padding(
                          padding: const EdgeInsets.only(right: 9),
                          child: Column(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                clipBehavior: Clip.antiAlias,
                                decoration: const BoxDecoration(shape: BoxShape.circle),
                                child: DiagonalStripePlaceholder(colors: f.placeholderColors),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                f.username,
                                style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.55)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
    ];
  }

  /// The identity block: an avatar and exactly two lines of text.
  ///
  /// What is NOT here is as deliberate as what is. The prototype's display name
  /// ("Κατερίνα Βλάχου") and its "· ΕΚΠΑ, Ψυχολογία" subtitle stay gone rather
  /// than defaulted: there is no `display_name`, no `school` and no `department`
  /// column to default FROM, and a fabricated name on a real account is worse
  /// than a handle — it is wrong about a person while looking authoritative.
  Widget _header() {
    final profile = _profile;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Row(
        children: [
          _avatar(profile),
          const SizedBox(width: 14),
          Expanded(child: _headerBody(profile)),
        ],
      ),
    );
  }

  /// The avatar, from the `avatars` bucket when `avatar_path` points at one.
  ///
  /// The URL comes back from [ProfileRepository.avatarUrl], which asks Storage
  /// for it — nothing here builds `/object/public/avatars/<path>` by
  /// convention, so the bucket stays the single authority on how its objects
  /// are reached and a change of policy is a change in one method.
  ///
  /// [DiagonalStripePlaceholder] is the fallback in three cases that are one
  /// case to whoever is looking: no profile row loaded, `avatar_path` null, and
  /// an object that failed to load. The third is why the `errorBuilder` is not
  /// optional — an `Image.network` without one renders a broken-image glyph,
  /// which is a worse "no avatar" than no avatar. The gradient is keyed off the
  /// uuid, so a user looks the same here as in the FOLLOWING rail below, and it
  /// visibly is not a photograph rather than being a stock face that reads as
  /// one.
  ///
  /// The `label: 'avatar'` the placeholder used to carry is gone with it. It
  /// labelled a slot that had no column behind it; there is a column now, so a
  /// bare circle means "this user has not set one" rather than "this feature is
  /// unbuilt".
  Widget _avatar(Profile? profile) {
    final placeholder = DiagonalStripePlaceholder(
      colors: profile?.placeholderColors ?? const [Color(0xFF241E3C), Color(0xFF1B1630)],
    );
    final url = _profiles.avatarUrl(profile?.avatarPath);

    return Container(
      width: 74,
      height: 74,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.5), width: 2),
      ),
      child: url == null
          ? placeholder
          : Image.network(
              url,
              width: 74,
              height: 74,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
            ),
    );
  }

  Widget _headerBody(Profile? profile) {
    if (profile != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${profile.username}',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3),
          ),
          // The whole of the second line, or no second line at all — never a
          // blank one. `hasBio` is the only guard needed: the
          // `profiles_bio_one_short_line` CHECK already refuses '' and the
          // whitespace-only string, so null is the single spelling of "unset"
          // (see [Profile.bio]).
          //
          // Nothing is substituted when it is null. A bio is the user's own
          // words, and a generated sentence rendered in that slot reads as
          // theirs — which is also why the header has to look finished with
          // `@username` alone. That is what every account looks like the day it
          // is created, so it is the common case, not the degraded one.
          //
          // One line, capped by the design rather than by the data: the column
          // allows 160 characters and forbids newlines, so without the ellipsis
          // a long bio would silently change the header's height.
          if (profile.hasBio)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                profile.bio!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.35, color: AppColors.textAlpha(0.55)),
              ),
            ),
          // `following_count` was a second inline pair here and is now rendered
          // nowhere: the header is two lines, and `follower_count` moved to the
          // FOLLOWERS tile. [Profile] still carries it.
        ],
      );
    }

    if (_loading) {
      return Text(
        '…',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.textAlpha(0.35)),
      );
    }

    if (_loadError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The profile did not load',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.7)),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _retryLoad,
            child: const Text(
              'Try again',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.pinkLight),
            ),
          ),
        ],
      );
    }

    // fetchProfile returned null. Either there is no such row or the `profiles`
    // SELECT policy filtered it — a block, in either direction. Rendered
    // identically because they are indistinguishable from the client by design,
    // and a screen that could tell them apart would be a block oracle.
    return Text(
      'This profile is not available',
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.55)),
    );
  }

  /// The gear. Sized to the same 32px pill as the segment beside it, and given
  /// a [Semantics] label because an icon-only control that leads to consent and
  /// account deletion is the last place to leave a screen reader guessing.
  Widget _settingsButton() {
    return Semantics(
      button: true,
      label: 'Settings',
      child: GestureDetector(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.settings_outlined, size: 17, color: AppColors.textAlpha(0.7)),
        ),
      ),
    );
  }

  Widget _segment(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono(size: 10.5, color: active ? AppColors.text : AppColors.textAlpha(0.45)),
        ),
      ),
    );
  }

  /// The two header actions.
  ///
  /// Which pair renders is a question about the [ProfileTarget] and about
  /// nothing else, so a switch on the sealed type answers it: the compiler
  /// proves the three cases exhaustive, there is no fourth state in which the
  /// wrong pair could appear, and no bool is reintroduced to carry a
  /// distinction the type already carries. `userId` comes out of the pattern,
  /// which is what keeps [FollowButton.targetUserId] and `reports.target_id`
  /// non-null without a `!` — and it is unavailable in the two [OwnProfile]
  /// arms, which is what makes it impossible for either to reach the follow
  /// graph or the report table on your own row.
  ///
  /// Three arms rather than two because `previewingPublicView` is matched
  /// inside the pattern. The preview draws the visitor's row; only
  /// [OtherProfile] wires it.
  Widget _actionRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: switch (_target) {
        // The preview draws the visitor's row, not the owner's. "Host a party"
        // and "Edit profile" are the two things a visitor provably cannot do,
        // so leaving them here made the one screen whose entire job is showing
        // what somebody else sees the one screen that got it wrong.
        //
        // Inert, and see [FollowButtonPreview] for why it has to be: the live
        // button would ask the database whether you follow yourself and then
        // offer you an insert it refuses. The message button is inert for the
        // same reason rather than a technical one — a preview where one control
        // acts and the other does not is a worse explanation of itself than one
        // where nothing does.
        //
        // The report menu stays off. It is the one visitor action that is not
        // about the profile but about escalating it, and an inert ⋯ that opens
        // an empty menu explains nothing; the row's SHAPE — follow, message —
        // is what the preview is answering.
        OwnProfile(previewingPublicView: true) => Row(
          children: [
            const Expanded(child: FollowButtonPreview()),
            const SizedBox(width: 8),
            Expanded(child: _actionButton('Message')),
          ],
        ),
        OwnProfile() => Row(
          children: [
            Expanded(
              child: _actionButton(
                'Host a party',
                primary: true,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const HostWizardScreen())),
              ),
            ),
            const SizedBox(width: 8),
            // Reloads on the way back rather than trusting what it pushed.
            // The editor may have committed a bio, an avatar, or one of the
            // two when the other failed — and the header renders all of it, so
            // re-reading the row beats teaching two screens to agree about
            // which halves of a partial save went through.
            Expanded(child: _actionButton('Edit profile', onTap: _openEditor)),
          ],
        ),
        OtherProfile(:final userId) => Row(
          children: [
            Expanded(child: FollowButton(targetUserId: userId)),
            const SizedBox(width: 8),
            Expanded(child: _actionButton('Message', onTap: _comingSoon)),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, size: 20, color: AppColors.textAlpha(0.5)),
              color: AppColors.sheet,
              onSelected: (_) =>
                  showReportSheet(context, target: ReportTarget.profile, targetId: userId),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'report',
                  child: Text('Report', style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ],
        ),
      },
    );
  }

  /// One header action button. Deliberately the same metrics as
  /// [FollowButton]'s non-compact shape — same vertical padding, same radius,
  /// same gradient — because on an [OtherProfile] the two sit side by side and
  /// any drift between them shows immediately.
  ///
  /// [onTap] is nullable so the PUBLIC preview can draw the button without
  /// wiring it. A null one is inert and looks identical — which is the point:
  /// the preview must not invent a disabled style visitors never see.
  Widget _actionButton(String label, {VoidCallback? onTap, bool primary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: primary ? AppColors.purpleGradient : null,
          color: primary ? null : Colors.white.withValues(alpha: 0.07),
          border: primary ? null : Border.all(color: AppColors.hairline),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      ),
    );
  }

  /// One of the two large tiles. Grown from the three-across version — more
  /// padding, a bigger number — because two tiles have the width to spend, and
  /// the label is mono uppercase now to match every other heading on the screen
  /// (ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ, ΙΔΙΩΤΙΚΟΤΗΤΑ, ΑΚΟΛΟΥΘΕΙ).
  Widget _statTile(String value, String label, {bool pink = false}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 13),
      decoration: BoxDecoration(
        color: pink ? AppColors.pink.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: pink ? AppColors.pink.withValues(alpha: 0.3) : AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: pink ? AppColors.pinkLight : AppColors.text,
            ),
          ),
          const SizedBox(height: 3),
          Text(label, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.5))),
        ],
      ),
    );
  }

  /// One public party the profile has already hosted.
  ///
  /// The prototype's "Πέρσι · 140 ήρθαν · Κουκάκι" loses its third clause:
  /// `going_count` is real, the date is real, and the neighbourhood has no
  /// column anywhere in the schema -- `parties.location` is a geography point.
  Widget _pastPublicPartyCard(PartySummary party) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        color: Colors.white.withValues(alpha: 0.035),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            party.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            '${formatPartyPastEn(party.startsAt)} · ${party.goingCount} went',
            style: const TextStyle(fontSize: 11.5, color: Color(0x8CF4F1F8)),
          ),
        ],
      ),
    );
  }

  /// The one-line stand-in a section shows when it is loading, broken, or
  /// genuinely empty. Deliberately plain: an empty section should read as an
  /// absence of parties, not as a broken card.
  Widget _sectionNotice(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.textAlpha(0.45)),
      ),
    );
  }
}
