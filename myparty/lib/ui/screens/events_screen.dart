import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../data/party_repository.dart';
import '../../models/mp_party.dart';
import '../../models/rsvp_party.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/host_post_strip.dart';
import '../widgets/mp_bottom_nav.dart';
import '../widgets/party_card.dart';
import '../widgets/privacy_badge.dart';
import 'chat_screen.dart';
import 'host_wizard_screen.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key, this.onNavigate, this.repository, this.feed});

  final ValueChanged<MpTab>? onNavigate;

  /// Injectable alongside [repository], for the same reason and by the same
  /// pattern. Supplies the host posts rendered under each RSVP row.
  final FeedRepository? feed;

  /// Injectable so widget tests can subclass [PartyRepository] without a
  /// Supabase client ever existing, the same seam [MapScreen] and
  /// [ProfileScreen] already take. This screen constructed its own repository
  /// in [State.initState], which is why it was untested — the translation
  /// below is the first thing here worth asserting.
  final PartyRepository? repository;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  late final FeedRepository _feed = widget.feed ?? FeedRepository();
  bool _showAll = true;
  late Future<List<RsvpParty>> _rsvpsFuture;

  @override
  void initState() {
    super.initState();
    _rsvpsFuture = _repository.fetchMyRsvps();
    _observe(_rsvpsFuture);
  }

  /// Marks the fetch's failure as handled without consuming it.
  ///
  /// The FutureBuilder that renders the error is on the "Mine" tab, and "All
  /// parties" is the default -- so on a failed fetch nothing is listening to
  /// this future until the user switches tabs, and Dart reports the rejection
  /// as an unhandled async error in the meantime. `_rsvpsFuture` itself is
  /// untouched: the tab still renders `_errorState()` when it is opened.
  void _observe(Future<List<RsvpParty>> future) {
    unawaited(future.then((_) {}, onError: (_) {}));
  }

  void _reloadRsvps() {
    setState(() {
      _rsvpsFuture = _repository.fetchMyRsvps();
      _observe(_rsvpsFuture);
    });
  }

  @override
  Widget build(BuildContext context) {
    final allParties = mpParties.values.toList()..sort((a, b) => a.sortKey.compareTo(b.sortKey));

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // The wordmark replaces the old 'Τα events μου' title.
                  //
                  // Height-constrained so the M keeps its aspect ratio, and
                  // labelled because swapping a Text for an Image otherwise
                  // leaves the screen's heading with no accessible name --
                  // TalkBack would announce nothing where it used to read the
                  // title out.
                  //
                  // 30px is sized for a TRIMMED, TRANSPARENT asset. The file
                  // currently in assets/ is a 1254x1254 square whose alpha is
                  // 255 everywhere, on #040406 rather than the app's #0B0A10,
                  // and the M occupies only the middle ~45% of it -- so today
                  // this renders a ~14px glyph inside a visible black tile.
                  // See the note in the PR: the fix is a new export, not a
                  // BlendMode or a crop here.
                  Semantics(
                    label: 'MyParty',
                    image: true,
                    header: true,
                    child: Image.asset(
                      'assets/images/content.png',
                      height: 30,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(99)),
                    child: Row(
                      children: [
                        _segment('MY PARTIES', !_showAll, () => setState(() => _showAll = false)),
                        _segment('ALL PARTIES', _showAll, () => setState(() => _showAll = true)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Deliberately quiet. This used to be a full-bleed brand-gradient
            // card with a 30px glow and a two-line pitch, which made hosting
            // the loudest thing on a screen whose subject is other people's
            // parties. It is now the same hairline pill idiom the reaction
            // buttons on PartyCard use, shrink-wrapped and left-aligned, so it
            // reads as one more control rather than the headline. The pitch
            // copy went with it -- an ad inside a button is exactly the weight
            // being removed.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HostWizardScreen())),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: AppColors.hairline),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add, size: 15, color: AppColors.purpleLight),
                        const SizedBox(width: 6),
                        Text('Host a party',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.1,
                                color: AppColors.textAlpha(0.85))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: _showAll
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 9),
                          child: Text('ALL PARTIES', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
                        ),
                        for (final party in allParties) ...[
                          PartyCard(partyId: party.id),
                          const SizedBox(height: 14),
                        ],
                      ],
                    )
                  : FutureBuilder<List<RsvpParty>>(
                      future: _rsvpsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: CircularProgressIndicator(color: AppColors.purple));
                        }
                        if (snapshot.hasError) {
                          return _errorState();
                        }

                        final now = DateTime.now();
                        final todayEnd = DateTime(now.year, now.month, now.day + 1);
                        final weekEnd = now.add(const Duration(days: 7));
                        final upcoming = snapshot.data!.where((r) => r.startsAt.isAfter(now)).toList()
                          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

                        final tonight = <RsvpParty>[];
                        final thisWeek = <RsvpParty>[];
                        final later = <RsvpParty>[];
                        for (final rsvp in upcoming) {
                          if (rsvp.startsAt.isBefore(todayEnd)) {
                            tonight.add(rsvp);
                          } else if (rsvp.startsAt.isBefore(weekEnd)) {
                            thisWeek.add(rsvp);
                          } else {
                            later.add(rsvp);
                          }
                        }

                        if (upcoming.isEmpty) return _emptyState(context);

                        return ListView(
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                          children: [
                            if (tonight.isNotEmpty) _rsvpSection(context, 'TONIGHT', tonight, live: true),
                            if (thisWeek.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _rsvpSection(context, 'THIS WEEK', thisWeek),
                            ],
                            if (later.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              _rsvpSection(context, 'LATER', later),
                            ],
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rsvpSection(BuildContext context, String title, List<RsvpParty> rsvps, {bool live = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 9),
          child: Row(
            children: [
              if (live) ...[
                Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.pink, shape: BoxShape.circle)),
                const SizedBox(width: 7),
              ],
              Text(title, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
            ],
          ),
        ),
        Column(
          children: [for (final rsvp in rsvps) _rsvpRow(context, rsvp)],
        ),
      ],
    );
  }

  Widget _rsvpRow(BuildContext context, RsvpParty rsvp) {
    final accent = rsvp.isPrivate ? AppColors.private : AppColors.purple;
    // Attendance, so a private party has none to show. Computed inside the
    // guard rather than blanked afterwards: an unused `crowd` string built
    // from two counts is exactly the value a later edit renders by accident.
    final crowd = rsvp.isPrivate
        ? null
        : (rsvp.goingCount > 0 ? '${rsvp.goingCount} going' : '${rsvp.interestedCount} interested');
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: GestureDetector(
        // PRIVATE parties only. A public party has no group chat since
        // 20260825094044, so there is nothing for this row to open and it is
        // inert rather than opening a screen that would come back empty.
        //
        // The button being absent is the courtesy; the rule is that
        // can_chat_in_party returns false, and the messages policy would
        // refuse the write even if this tap were restored by hand.
        onTap: rsvp.isPrivate
            ? () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    partyId: rsvp.partyId,
                    partyTitle: rsvp.title,
                    isPrivate: rsvp.isPrivate,
                    memberCount: rsvp.goingCount,
                  ),
                ))
            : null,
        // The rounding moved from the BoxDecoration onto a ClipRRect; the
        // asymmetric border below is unchanged.
        //
        // Flutter asserts at PAINT time that a borderRadius may only be given
        // on a border with uniform sides, and this row pairs a 3px left accent
        // with 1px elsewhere — so it threw on every debug build the moment an
        // RSVP rendered. It survived because this screen had no widget test
        // until now. Clipping instead of rounding keeps the design intact.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.035),
              border: Border(
                top: BorderSide(color: accent.withValues(alpha: 0.3)),
                bottom: BorderSide(color: accent.withValues(alpha: 0.3)),
                right: BorderSide(color: accent.withValues(alpha: 0.3)),
                left: BorderSide(color: accent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 70,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(11)),
                  child: DiagonalStripePlaceholder(
                    colors: rsvp.isPrivate ? const [Color(0xFF1C1622), Color(0xFF151020)] : const [Color(0xFF1D1730), Color(0xFF161126)],
                    label: 'cover',
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PrivacyBadge(isPrivate: rsvp.isPrivate, english: true),
                          const SizedBox(width: 5),
                          // 'COMING' on a private party. Its rsvp row is
                          // always 'going' -- the policy permits nothing else
                          // -- so the word is the only thing that varies, and
                          // it matches the button that wrote it.
                          Text(
                            rsvp.isPrivate
                                ? 'COMING'
                                : (rsvp.rsvpStatus == 'going' ? 'GOING' : 'INTERESTED'),
                            style: AppTextStyles.mono(size: 9, color: AppColors.textAlpha(0.45)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(rsvp.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(formatPartyStartEn(rsvp.startsAt),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.55))),
                      ),
                      if (crowd != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(crowd, style: TextStyle(fontSize: 10.5, color: AppColors.textAlpha(0.5))),
                        ),
                      // The host's photos of this party. Nothing is drawn when
                      // there are none — no placeholder, no skeleton, no "no
                      // photos yet": an empty strip would take vertical space
                      // on every row to say nothing, and most parties have no
                      // posts.
                      HostPostStrip(partyId: rsvp.partyId, feed: _feed),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _errorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('We couldn’t load your events.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _reloadRsvps,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                decoration: BoxDecoration(gradient: AppColors.purpleGradient, borderRadius: BorderRadius.circular(12)),
                child: const Text('Try again', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.5),
              ),
              child: const Icon(Icons.explore_outlined, color: AppColors.purple, size: 26),
            ),
            const SizedBox(height: 14),
            const Text('You’re not going anywhere yet', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('The map shows what’s happening near you right now. There’s something within two blocks.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.55))),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () => widget.onNavigate?.call(MpTab.map),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(gradient: AppColors.purpleGradient, borderRadius: BorderRadius.circular(13)),
                child: const Text('Open the map', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
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
        child: Text(label, style: AppTextStyles.mono(size: 10.5, color: active ? AppColors.text : AppColors.textAlpha(0.45))),
      ),
    );
  }
}
