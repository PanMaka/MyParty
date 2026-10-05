import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../data/party_repository.dart';
import '../../models/party_list_item.dart';
import '../../models/rsvp_party.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/host_post_strip.dart';
import '../widgets/mp_bottom_nav.dart';
import '../../state/mp_store.dart' show MpRsvp;
import '../../state/rsvp_changes.dart';
import '../widgets/party_card.dart';
import '../widgets/privacy_badge.dart';
import 'chat_screen.dart';
import 'host_wizard_screen.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({
    super.key,
    this.onNavigate,
    this.repository,
    this.feed,
    this.clock = DateTime.now,
  });

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

  /// What "now" is when the RSVP rows are bucketed into TONIGHT / THIS WEEK /
  /// LATER. Injectable because TONIGHT ends at local midnight, so a test that
  /// reads the real clock files "two hours from now" under THIS WEEK whenever
  /// it runs after 22:00.
  final DateTime Function() clock;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  late final FeedRepository _feed = widget.feed ?? FeedRepository();
  bool _showAll = true;
  late Future<List<RsvpParty>> _rsvpsFuture;

  // ALL PARTIES state. The list is paged and SERVER-SORTED, so all three of
  // these belong together: changing _sort invalidates the page and the cursor
  // at once, which is why nothing here re-sorts _items locally. A client-side
  // reorder would also silently break pagination -- the cursor is the last row
  // in SERVER order, and a local sort changes which row that is.
  PartySort _sort = PartySort.soonest;
  final List<PartyListItem> _items = [];
  Map<String, String> _coverUrls = {};
  PartyListCursor? _cursor;
  bool _loading = false;
  bool _exhausted = false;
  Object? _listError;
  final ScrollController _listScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _rsvpsFuture = _repository.fetchMyRsvps();
    _observe(_rsvpsFuture);
    rsvpChanges.addListener(_onRsvpChanged);
    _listScroll.addListener(_onScroll);
    _loadList(reset: true);
  }

  @override
  void dispose() {
    rsvpChanges.removeListener(_onRsvpChanged);
    _listScroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_listScroll.hasClients) return;
    final remaining = _listScroll.position.maxScrollExtent - _listScroll.position.pixels;
    if (remaining < 600) _loadList();
  }

  /// Fetches a page, or re-fetches the list from scratch when [reset].
  ///
  /// The sort is a PARAMETER, not a post-processing step: "most interested"
  /// has to mean most interested of all of them, not of whatever this page
  /// happened to contain.
  Future<void> _loadList({bool reset = false}) async {
    if (_loading) return;
    if (!reset && (_exhausted || _cursor == null)) return;

    setState(() {
      _loading = true;
      if (reset) {
        _listError = null;
        _exhausted = false;
      }
    });

    try {
      final page = await _repository.fetchPartiesList(
        sort: _sort,
        cursor: reset ? null : _cursor,
      );

      // One batch signature for the page, not one request per card --
      // party-covers is a private bucket and signing is per-object, but
      // createSignedUrls takes the whole list at once. Keyed by party id, so
      // a card never has to hold a storage key to find its own image.
      final urls = await _repository.signedListCoverUrls(page.items);

      if (!mounted) return;
      setState(() {
        if (reset) {
          _items.clear();
          _coverUrls = {};
        }
        _items.addAll(page.items);
        _coverUrls = {..._coverUrls, ...urls};
        _cursor = page.cursor;
        _exhausted = page.cursor == null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A failed FIRST page is an error state; a failed later page leaves
        // what is already on screen alone and simply stops paging, because
        // replacing a list the reader is using with an error is worse than
        // quietly ending it.
        if (reset || _items.isEmpty) _listError = error;
        _exhausted = true;
      });
    }
  }

  void _changeSort(PartySort sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _cursor = null;
    });
    if (_listScroll.hasClients) _listScroll.jumpTo(0);
    _loadList(reset: true);
  }

  /// Writes an RSVP and reflects it, without re-fetching the list.
  ///
  /// Optimistic on the ROW only. The counters are deliberately not adjusted
  /// here: on the interested sort they are the sort key, so nudging them
  /// locally would put the row out of order with the server's ranking and the
  /// next page would then overlap or skip. The number refreshes on the next
  /// load; the button state, which is what the user just pressed, is instant.
  Future<void> _setRsvp(PartyListItem item, MpRsvp status) async {
    final previous = item.myRsvp;
    final withdrawing = previous == status;
    final index = _items.indexWhere((i) => i.partyId == item.partyId);
    if (index < 0) return;

    setState(() {
      _items[index] = item.copyWith(myRsvp: status, clearRsvp: withdrawing);
    });

    try {
      await _repository.setRsvp(
        partyId: item.partyId,
        status: status,
        current: previous,
      );
      // MY PARTIES is now stale -- it is the same rsvps rows seen from the
      // other end. Published rather than reloaded here so the map's pins hear
      // about it too; [_onRsvpChanged] does the reload.
      rsvpChanges.value = RsvpChange(
        partyId: item.partyId,
        status: withdrawing ? null : status,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _items[index] = item);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That did not save.'), behavior: SnackBarBehavior.floating),
      );
    }
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

  /// An RSVP was saved, here or on another tab (the map sheet, search).
  ///
  /// MY PARTIES is refetched, since a new answer adds a row and a withdrawal
  /// removes one. A matching ALL PARTIES card has its button patched in place
  /// rather than the list reloaded, which would lose the reader's scroll
  /// position and page; its counters refresh on the next load, for the reason
  /// [_setRsvp] gives.
  void _onRsvpChanged() {
    final change = rsvpChanges.value;
    if (change == null || !mounted) return;
    final index = _items.indexWhere((i) => i.partyId == change.partyId);
    if (index >= 0) {
      _items[index] = _items[index].copyWith(
        myRsvp: change.status,
        clearRsvp: change.status == null,
      );
    }
    _reloadRsvps();
  }

  void _reloadRsvps() {
    setState(() {
      _rsvpsFuture = _repository.fetchMyRsvps();
      _observe(_rsvpsFuture);
    });
  }

  @override
  Widget build(BuildContext context) {
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
                  ? _allPartiesList()
                  : FutureBuilder<List<RsvpParty>>(
                      future: _rsvpsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: CircularProgressIndicator(color: AppColors.purple));
                        }
                        if (snapshot.hasError) {
                          return _errorState();
                        }

                        final now = widget.clock();
                        final todayEnd = DateTime(now.year, now.month, now.day + 1);
                        final weekEnd = now.add(const Duration(days: 7));
                        // "Not over" is the MAP's rule, `ends_at is null or
                        // ends_at > now()`, not "has not started": a party you
                        // RSVP'd to from its pin while it was under way has to
                        // show up here, or the answer looks like it was lost.
                        final current = snapshot.data!
                            .where((r) => r.endsAt == null || r.endsAt!.isAfter(now))
                            .toList()
                          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
                        final happening = current.where((r) => !r.startsAt.isAfter(now)).toList();
                        final upcoming = current.where((r) => r.startsAt.isAfter(now)).toList();

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

                        if (current.isEmpty) return _emptyState(context);

                        return ListView(
                          padding: const EdgeInsets.fromLTRB(14, 16, 14, 96),
                          children: [
                            if (happening.isNotEmpty) _rsvpSection(context, 'HAPPENING NOW', happening, live: true),
                            if (tonight.isNotEmpty) ...[
                              if (happening.isNotEmpty) const SizedBox(height: 20),
                              _rsvpSection(context, 'TONIGHT', tonight, live: true),
                            ],
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

  /// The ALL PARTIES list: a sort control, then server-ordered cards.
  ///
  /// The header is OUTSIDE the scroll view rather than being its first item.
  /// Inside, it disappeared with the list -- so an empty result, an error and
  /// the first load all removed the sort control, and the one thing a reader
  /// looking at an empty "most interested" list wants is the way back to
  /// "soonest". It is chrome for the list, not a row of it.
  Widget _allPartiesList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 9),
          child: _listHeader(),
        ),
        Expanded(child: _allPartiesBody()),
      ],
    );
  }

  Widget _allPartiesBody() {
    if (_listError != null && _items.isEmpty) {
      return _listErrorState();
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purple));
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Nothing on right now.\nBe the first to host something.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.textAlpha(0.5)),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _listScroll,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 96),
      // +1 footer: the paging spinner, or the end of the list.
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return _loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2)),
                )
              : const SizedBox(height: 8);
        }
        final item = _items[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: PartyCard(
            item: item,
            coverUrl: _coverUrls[item.partyId],
            onRsvp: (status) => _setRsvp(item, status),
          ),
        );
      },
    );
  }

  Widget _listHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('ALL PARTIES', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.6))),
        Row(
          children: [
            for (final sort in PartySort.values) ...[
              _sortChip(sort),
              if (sort != PartySort.values.last) const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }

  /// One sort option.
  ///
  /// A SORT, not a filter -- picking one reorders the same set and never
  /// narrows it, which is also why it does not touch anything else on screen.
  /// (The map's time chips ARE a filter; the two are independent axes and
  /// would compose rather than reset each other if the chips ever came here.)
  Widget _sortChip(PartySort sort) {
    final selected = _sort == sort;
    return GestureDetector(
      onTap: () => _changeSort(sort),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.purple.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: selected ? AppColors.purple : AppColors.hairline),
        ),
        child: Text(
          sort.label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected ? AppColors.text : AppColors.textAlpha(0.6),
          ),
        ),
      ),
    );
  }

  Widget _listErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 30, color: AppColors.textAlpha(0.3)),
            const SizedBox(height: 12),
            Text('We couldn’t load the parties.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _loadList(reset: true),
              child: const Text('Try again', style: TextStyle(color: AppColors.purpleLight)),
            ),
          ],
        ),
      ),
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
                        child: Text(formatPartyStartEn(rsvp.startsAt, now: widget.clock()),
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
