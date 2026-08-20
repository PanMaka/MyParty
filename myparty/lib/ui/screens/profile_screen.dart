import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../data/social_repository.dart';
import '../../models/feed_post.dart';
import '../../models/party_summary.dart';
import '../../models/profile.dart';
import '../../models/profile_privacy.dart';
import '../../models/profile_stats.dart';
import '../../services/auth_service.dart';
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/follow_button.dart';
import '../widgets/report_sheet.dart';
import 'account_deletion_screen.dart';
import 'host_wizard_screen.dart';
import 'notification_settings_screen.dart';

/// Whose profile the screen is showing, and — when it is the owner's — whether
/// they are previewing how it looks to everybody else.
///
/// This replaces a `String? userId` paired with a `bool _selfView`, which
/// spelled four states when only three exist. The missing constraint was
/// `userId != null && _selfView == true`: someone else's profile rendering the
/// OWNER sections, which is to say your privacy tiers (`fetchPrivacy` is
/// self-only and would have loaded YOURS under THEIR name), your notification
/// settings, your account-deletion row and your sign-out button. Nothing in the
/// old type prevented it — the tab bar simply never passed a `userId`, so it
/// never happened. The moment step 5 makes the tab bar pass one, "never
/// happens" stops being true, so the state is made unrepresentable instead.
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

  /// Whether the owner-only sections render — privacy, notifications, account
  /// deletion, sign out.
  bool get showsOwnerSections;

  /// Whether the follow button and the report menu render.
  ///
  /// True only on another user's profile. You cannot follow or report yourself,
  /// and no value of this type makes both this and [showsOwnerSections] true.
  bool get showsRelationshipActions;
}

/// The signed-in user's own profile. Carries no uuid on purpose — see
/// [ProfileTarget.userIdOrNull].
final class OwnProfile extends ProfileTarget {
  const OwnProfile({this.previewingPublicView = false});

  /// The ΕΓΩ / ΔΗΜΟΣΙΑ segment. Changes which sections render, and nothing else
  /// — previewing your public profile does not make you a stranger to yourself,
  /// so the relationship actions stay off.
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
  /// Supabase client ever existing, the same way [NotificationSettingsScreen]
  /// takes a [DeviceRepository].
  final ProfileRepository? repository;

  /// Injectable for the same reason. Needed now that the ΑΚΟΛΟΥΘΕΙ rail loads
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

  /// Mutable only through the ΕΓΩ / ΔΗΜΟΣΙΑ segment, and only ever between the
  /// two [OwnProfile] values — an [OtherProfile] never becomes an [OwnProfile].
  late ProfileTarget _target = widget.target;

  late final Future<List<Profile>> _theirFollowing = _social.fetchFollowing(
    userId: widget.target.userIdOrNull,
  );

  /// Upcoming parties this profile is hosting — the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card.
  late final Future<List<PartySummary>> _hostingNow = _parties.fetchHostedParties(
    hostId: widget.target.userIdOrNull,
    window: PartyWindow.upcoming,
    limit: 5,
  );

  /// Public parties this profile has already hosted — the ΔΗΜΟΣΙΑ ΠΑΡΤΙ card.
  /// `publicOnly` because the heading says public; see [PartyRepository].
  late final Future<List<PartySummary>> _hostedPublicPast = _parties.fetchHostedParties(
    hostId: widget.target.userIdOrNull,
    window: PartyWindow.past,
    publicOnly: true,
    limit: 3,
  );

  /// Where the owner has actually been — the ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ strip. Owner-only
  /// by construction: the `rsvps` policy makes the question unanswerable about
  /// anyone else, which is why this takes no id.
  late final Future<List<PartySummary>> _myHistory = _parties.fetchAttendedParties();

  Profile? _profile;
  ProfilePrivacy? _privacy;
  ProfileStats _stats = ProfileStats.empty;

  /// Header state. [_profile] non-null wins over both of these, so a privacy
  /// write reloading in the background never blanks a header that already has
  /// something true to show.
  bool _loading = true;
  Object? _loadError;

  bool _busy = false;

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
      // Self-only by construction, and pointless on someone else's profile —
      // it would load the VIEWER's tiers, which is the bug the old bool made
      // possible. Skipped rather than merely hidden.
      final privacy = _target is OwnProfile ? await _profiles.fetchPrivacy() : null;

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _stats = stats;
        _privacy = privacy;
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

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _load();
  }

  /// Wraps every privacy write, exactly as [NotificationSettingsScreen] does:
  /// two taps cannot race each other into the database, and a rejected write
  /// reloads rather than leaving a switch showing a state the server never
  /// accepted. That last part matters more here than on a notification
  /// preference — a privacy control that displays a setting the server did not
  /// store is worse than one that fails loudly.
  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Κάτι πήγε στραβά: $error'), behavior: SnackBarBehavior.floating),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _comingSoon() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Έρχεται σύντομα'), behavior: SnackBarBehavior.floating));
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
                    'Προφίλ',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                  ),
                  // Only the owner gets the toggle: it previews YOUR public
                  // profile, and there is no second view of somebody else's.
                  if (_target case final OwnProfile own)
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Row(
                        children: [
                          _segment(
                            'ΕΓΩ',
                            !own.previewingPublicView,
                            () => setState(() => _target = const OwnProfile()),
                          ),
                          _segment(
                            'ΔΗΜΟΣΙΑ',
                            own.previewingPublicView,
                            () => setState(() => _target = const OwnProfile(previewingPublicView: true)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            _header(),
            // Two tiles, and the same two for every viewer.
            //
            // Gated on a loaded profile rather than defaulting to 0, for the
            // reason _headerBody already gives below: "0 ΑΚΟΛΟΥΘΟΙ" sitting
            // under "Το προφίλ δεν είναι διαθέσιμο" asserts that an account
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
                    Expanded(child: _statTile('${loaded.followerCount}', 'ΑΚΟΛΟΥΘΟΙ')),
                    const SizedBox(width: 10),
                    Expanded(child: _statTile('${_stats.partiesHosted}', 'ΔΙΟΡΓΑΝΩΣΕ', pink: true)),
                  ],
                ),
              ),
            _actionRow(),
            if (_target.showsOwnerSections) ..._selfSections(context) else ..._publicSections(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _selfSections(BuildContext context) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            FutureBuilder<List<PartySummary>>(
              future: _hostingNow,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _sectionNotice('…');
                }
                if (snapshot.hasError) {
                  return _sectionNotice('Δεν φόρτωσαν τα πάρτι σου');
                }
                final parties = snapshot.data ?? const <PartySummary>[];
                if (parties.isEmpty) {
                  // The prototype's answer to "you host nothing" was a party
                  // called Ταράτσα στο Κουκάκι. An empty state is the only
                  // honest one: a host with no upcoming party has no card.
                  return _sectionNotice('Δεν διοργανώνεις κάποιο πάρτι αυτή τη στιγμή.');
                }
                return Column(
                  children: [
                    for (final party in parties)
                      Padding(
                        padding: EdgeInsets.only(bottom: party == parties.last ? 0 : 8),
                        child: _hostedPartyCard(party),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            // Parties you WENT to, not ones you hosted -- the section above is
            // explicitly "as organizer", and this pairs with the "πάρτι φέτος"
            // tile at the top, which counts the same `going` RSVPs. Owner-only
            // by construction: the rsvps SELECT policy makes the question
            // unanswerable about anybody else.
            FutureBuilder<List<PartySummary>>(
              future: _myHistory,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return _sectionNotice('…');
                }
                if (snapshot.hasError) {
                  return _sectionNotice('Δεν φόρτωσε το ιστορικό σου');
                }
                final parties = snapshot.data ?? const <PartySummary>[];
                if (parties.isEmpty) {
                  return _sectionNotice('Δεν έχεις πάει ακόμα σε κάποιο πάρτι.');
                }
                final tiles = parties.take(3).toList();
                return Row(
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(width: 5),
                      Expanded(child: _historyTile(tiles[i])),
                    ],
                    // Keeps three columns' worth of width when there are fewer
                    // than three, so one past party does not render as a single
                    // tile stretched across the screen.
                    for (var i = tiles.length; i < 3; i++) ...[
                      const SizedBox(width: 5),
                      const Expanded(child: SizedBox.shrink()),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΙΔΙΩΤΙΚΟΤΗΤΑ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Column(
                children: [
                  // Still unwired, and deliberately so: there is no column
                  // behind it yet. It is also the reason the "πάρτι φέτος" tile
                  // is owner-only — until this setting exists, the rsvps policy
                  // IS the answer to "who sees where I go", and get_profile_stats
                  // does not invent a different one.
                  _settingsRow(
                    'Ποιος βλέπει σε ποια πάρτι πάω',
                    'Έρχεται σύντομα',
                    chevron: true,
                    onTap: _comingSoon,
                  ),
                  Container(height: 1, color: AppColors.hairline),
                  // Was a two-state switch on MpStore.mapVisible, which no
                  // server ever read. Now three tiers on profiles.map_visibility,
                  // enforced inside get_parties_near_user.
                  _settingsRow(
                    'Ποιος βλέπει τα πάρτι μου στον χάρτη',
                    _privacy?.mapVisibility.label ?? '…',
                    chevron: true,
                    onTap: _privacy == null ? null : _pickMapVisibility,
                  ),
                  Container(height: 1, color: AppColors.hairline),
                  _settingsRow(
                    'Ποιος μπορεί να με καλέσει',
                    _privacy?.invitePolicy.label ?? '…',
                    chevron: true,
                    onTap: _privacy == null ? null : _pickInvitePolicy,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
              child: Text(
                'Τα ιδιωτικά πάρτι στα οποία πας δεν φαίνονται ποτέ σε άτομα που δεν είναι καλεσμένα — ούτε στο προφίλ σου.',
                style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
              ),
            ),
          ],
        ),
      ),
      // Phase 7c. The consent toggles and the nearby preferences have to be
      // reachable from somewhere, and this is the screen that already owns
      // ΙΔΙΩΤΙΚΟΤΗΤΑ. Kept as its own section rather than folded into the
      // privacy card above because two of its rows are consent — a legal state
      // with a deletion consequence — and the rows above them are settings.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΕΙΔΟΠΟΙΗΣΕΙΣ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.hairline),
              ),
              child: _settingsRow(
                'Ειδοποιήσεις & τοποθεσία',
                'Πάρτι κοντά σου, ώρες ησυχίας, απόσταση',
                chevron: true,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => const NotificationSettingsScreen())),
              ),
            ),
          ],
        ),
      ),
      // Phase 9. App Store Review Guideline 5.1.1(v) requires an in-app
      // deletion path wherever an account can be created, and requires it to
      // actually start the deletion rather than link to support. Placed
      // directly above sign-out because that is where a user looks for it, and
      // kept as its own section rather than a row in ΕΙΔΟΠΟΙΗΣΕΙΣ because
      // everything under that heading is reversible and this is not.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ΛΟΓΑΡΙΑΣΜΟΣ', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
            const SizedBox(height: 9),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.hairline),
              ),
              child: _settingsRow(
                'Δεδομένα & διαγραφή',
                'Εξαγωγή των δεδομένων σου, διαγραφή λογαριασμού',
                chevron: true,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => const AccountDeletionScreen())),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: GestureDetector(
          onTap: () => AuthService().signOut(),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              color: Colors.white.withValues(alpha: 0.035),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Center(
              child: Text(
                'Αποσύνδεση',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.6)),
              ),
            ),
          ),
        ),
      ),
    ];
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
              'ΔΗΜΟΣΙΑ ΠΑΡΤΙ ΠΟΥ ΔΙΟΡΓΑΝΩΣΕ',
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
                  return _sectionNotice('Δεν φόρτωσαν τα πάρτι');
                }
                final parties = snapshot.data ?? const <PartySummary>[];
                if (parties.isEmpty) {
                  return _sectionNotice('Κανένα δημόσιο πάρτι ακόμα.');
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
                  'Τα ιδιωτικά πάρτι αυτού του προφίλ και τα stories τους δεν είναι ορατά σε σένα.',
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
                    'ΑΚΟΛΟΥΘΕΙ · ${people.length}',
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
  /// uuid, so a user looks the same here as in the ΑΚΟΛΟΥΘΕΙ rail below, and it
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
          // ΑΚΟΛΟΥΘΟΙ tile. [Profile] still carries it.
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
            'Δεν φόρτωσε το προφίλ',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.7)),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _retryLoad,
            child: const Text(
              'Δοκίμασε ξανά',
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
      'Το προφίλ δεν είναι διαθέσιμο',
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.55)),
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
  /// proves the two cases exhaustive, there is no third state in which the
  /// wrong pair could appear, and no bool is reintroduced to carry a
  /// distinction the type already carries. `userId` comes out of the pattern,
  /// which is what keeps [FollowButton.targetUserId] and `reports.target_id`
  /// non-null without a `!`.
  ///
  /// It deliberately does not consult [OwnProfile.previewingPublicView].
  /// Previewing your own public profile does not make you a stranger to
  /// yourself, and "Ακολούθησε" over your own row would offer an action the
  /// `follows` INSERT policy refuses anyway (`follower_id <> followee_id`).
  Widget _actionRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: switch (_target) {
        OwnProfile() => Row(
          children: [
            Expanded(
              child: _actionButton(
                'Διοργάνωσε πάρτι',
                primary: true,
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const HostWizardScreen())),
              ),
            ),
            const SizedBox(width: 8),
            // There is no profile-editing screen yet, so this says so rather
            // than pretending — the same treatment "Μήνυμα" already gets, and
            // the same reason the ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ card's "Διαχείριση" pill was
            // deleted instead of wired.
            Expanded(child: _actionButton('Επεξεργασία προφίλ', onTap: _comingSoon)),
          ],
        ),
        OtherProfile(:final userId) => Row(
          children: [
            Expanded(child: FollowButton(targetUserId: userId)),
            const SizedBox(width: 8),
            Expanded(child: _actionButton('Μήνυμα', onTap: _comingSoon)),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, size: 20, color: AppColors.textAlpha(0.5)),
              color: AppColors.sheet,
              onSelected: (_) =>
                  showReportSheet(context, target: ReportTarget.profile, targetId: userId),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'report',
                  child: Text('Αναφορά', style: TextStyle(fontSize: 13)),
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
  Widget _actionButton(String label, {required VoidCallback onTap, bool primary = false}) {
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

  /// One upcoming party the profile is hosting.
  ///
  /// The "Διαχείριση" pill the prototype drew here is gone rather than wired:
  /// there is no management screen to send anyone to, and a button that does
  /// nothing is the same fabrication as a fake party title -- it just fails a
  /// beat later. The card is informational until that screen exists.
  Widget _hostedPartyCard(PartySummary party) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.28)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.pink.withValues(alpha: 0.14), Colors.white.withValues(alpha: 0.03)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  party.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
              ),
              if (party.isPrivate)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(Icons.lock_outline, size: 14, color: AppColors.textAlpha(0.45)),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            // "18/24 δέχτηκαν" needed a denominator nothing computed. going_count
            // is a real trigger-maintained column; the only real denominator is
            // max_capacity, which is nullable -- so a host who set no cap gets
            // the count on its own instead of a ratio against an invented target.
            party.hasCapacity
                ? '${formatPartyStart(party.startsAt)} · ${party.goingCount}/${party.maxCapacity} θέσεις'
                : '${formatPartyStart(party.startsAt)} · ${party.goingCount} δηλώσεις συμμετοχής',
            style: const TextStyle(fontSize: 11.5, color: Color(0x8CF4F1F8)),
          ),
          // Only drawn when there is something to be a fraction OF. The
          // prototype's widthFactor: 0.75 was a picture of a ratio, not a ratio.
          if (party.hasCapacity) ...[
            const SizedBox(height: 11),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Container(
                height: 6,
                color: Colors.white.withValues(alpha: 0.08),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: party.capacityFraction,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [AppColors.purpleDeep, AppColors.pink]),
                    ),
                  ),
                ),
              ),
            ),
          ],
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
            '${formatPartyPast(party.startsAt)} · ${party.goingCount} ήρθαν',
            style: const TextStyle(fontSize: 11.5, color: Color(0x8CF4F1F8)),
          ),
        ],
      ),
    );
  }

  /// A past party as one square in the ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ strip.
  ///
  /// The title is real; the image is not, because there is none. `party-covers`
  /// is a real bucket with a `{party_id}/…` convention and nothing points into
  /// it, so the stripe is the same acknowledged placeholder the avatars use --
  /// keyed off the uuid so a party keeps its colours between rebuilds.
  Widget _historyTile(PartySummary party) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DiagonalStripePlaceholder(colors: party.placeholderColors),
            Positioned(
              bottom: 5,
              left: 6,
              right: 6,
              child: Text(
                party.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.mono(size: 8, color: AppColors.textAlpha(0.55)),
              ),
            ),
          ],
        ),
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

  Widget _settingsRow(String title, String sub, {bool chevron = false, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.45))),
                ],
              ),
            ),
            if (chevron) Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
          ],
        ),
      ),
    );
  }

  /// A switch cannot express three tiers, and squeezing map_visibility into one
  /// would have to drop a tier or overload it. A sheet also gives each option
  /// room for the sentence that says what it actually does — which is the
  /// difference between a control someone sets correctly and one they guess at.
  Future<void> _pickMapVisibility() async {
    final chosen = await _pickTier<MapVisibility>(
      title: 'Ποιος βλέπει τα πάρτι μου στον χάρτη',
      options: MapVisibility.values,
      current: _privacy!.mapVisibility,
      labelOf: (v) => v.label,
      explanationOf: (v) => v.explanation,
      // The one thing the tiers do NOT do, stated where the choice is made:
      // people already tied to a specific party keep seeing it at every tier.
      footnote:
          'Όσοι έχουν πρόσκληση ή έχουν ήδη δηλώσει συμμετοχή '
          'συνεχίζουν να βλέπουν το συγκεκριμένο πάρτι.',
    );
    if (chosen == null || chosen == _privacy!.mapVisibility) return;
    await _mutate(() => _profiles.updatePrivacy(mapVisibility: chosen));
  }

  Future<void> _pickInvitePolicy() async {
    final chosen = await _pickTier<InvitePolicy>(
      title: 'Ποιος μπορεί να με καλέσει',
      options: InvitePolicy.values,
      current: _privacy!.invitePolicy,
      labelOf: (v) => v.label,
      explanationOf: (v) => v.explanation,
    );
    if (chosen == null || chosen == _privacy!.invitePolicy) return;
    await _mutate(() => _profiles.updatePrivacy(invitePolicy: chosen));
  }

  Future<T?> _pickTier<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) labelOf,
    required String Function(T) explanationOf,
    String? footnote,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.sheet,
      // Both are needed, and neither is cosmetic. A default modal sheet is
      // capped at 9/16 of the screen, which three tiers plus their explanations
      // and the footnote overflow on a short handset — and an overflowing sheet
      // clips the last option rather than scrolling to it, so a tier would
      // simply be unreachable. isScrollControlled lifts the cap;
      // SingleChildScrollView covers the rest (large text scale, small screen).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              for (final option in options)
                InkWell(
                  onTap: () => Navigator.of(sheetContext).pop(option),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                labelOf(option),
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                explanationOf(option),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: AppColors.textAlpha(0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (option == current)
                          const Padding(
                            padding: EdgeInsets.only(left: 10, top: 2),
                            child: Icon(Icons.check, size: 18, color: AppColors.pinkLight),
                          ),
                      ],
                    ),
                  ),
                ),
              if (footnote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    footnote,
                    style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
