import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import '../../data/party_host_channel.dart';
import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../models/host_party_stats.dart';
import '../../models/map_party_pin.dart';
import '../../state/data_changes.dart';
import '../../state/live_refresh.dart';
import '../../utils/english_date.dart';
import '../../utils/share_party.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/follower_split_bar.dart';
import '../widgets/map_pin_sheet.dart';
import '../widgets/mp_bottom_nav.dart' show MpTab;
import '../widgets/privacy_badge.dart';
import '../widgets/rsvp_timeline_chart.dart';
import '../widgets/skeleton_box.dart';
import '../widgets/user_link.dart';
import 'host_wizard_screen.dart';

/// What a host sees when they open their own party, from any door — a map
/// pin, a search hit, MY PARTIES, ALL PARTIES, a party link, or their own
/// profile. [showMapPinSheet] and [showPartyDetailSheet] redirect here when
/// the viewer is the host, so no door can forget to.
///
/// Every number comes from host-only server functions (20261014113213): the
/// header and aggregates from `get_party_host_stats`, the chart from
/// `get_party_rsvp_timeline`, the list from `get_party_guests`. Nothing here
/// computes a count.
///
/// **Live** the same two ways as the Direct tab: [LiveRefresh] for the
/// viewer's own writes and app resumes, plus the `party_host:{uuid}` topic for
/// everyone else's RSVPs. The topic carries no content; any traffic refetches.
class HostDashboardScreen extends StatefulWidget {
  const HostDashboardScreen({
    super.key,
    required this.partyId,
    this.repository,
    this.profiles,
    this.share,
  });

  final String partyId;
  final PartyRepository? repository;

  /// Guest avatars, and the host's own username for "View as guest".
  final ProfileRepository? profiles;

  /// The system share sheet by default; tests record instead.
  final ShareText? share;

  @override
  State<HostDashboardScreen> createState() => _HostDashboardScreenState();
}

class _HostDashboardScreenState extends State<HostDashboardScreen> with LiveRefresh<HostDashboardScreen> {
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  late final ProfileRepository _profiles = widget.profiles ?? ProfileRepository();

  /// How long a burst of RSVPs is allowed to settle before one refetch.
  static const _settle = Duration(milliseconds: 700);

  HostPartyStats? _stats;
  bool _statsFailed = false;
  String? _coverUrl;

  RsvpTimeline? _timeline;
  bool _timelineFailed = false;

  /// The guest tab on screen: true = Going (or Coming), false = Interested.
  bool _goingTab = true;
  final Map<bool, _GuestList> _guests = {true: _GuestList(), false: _GuestList()};

  bool _cancelling = false;

  PartyHostChannel? _topic;
  final List<StreamSubscription<Object?>> _topicSubs = [];
  Timer? _debounce;

  @override
  MpTab? get liveTab => null;

  @override
  void initState() {
    super.initState();
    _holdTopic();
    unawaited(_reloadAll());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final sub in _topicSubs) {
      sub.cancel();
    }
    final topic = _topic;
    if (topic != null) unawaited(topic.dispose());
    super.dispose();
  }

  void _holdTopic() {
    final PartyHostChannel topic;
    try {
      topic = _repository.subscribeHostTopic(widget.partyId);
    } catch (_) {
      // No realtime: the dashboard still refreshes on the viewer's own writes
      // and on resume, which is every other screen's arrangement.
      return;
    }
    _topic = topic;
    // The first `subscribed` is the join; a later one is a reconnect, and
    // broadcast has no replay, so anything said meanwhile is refetched.
    var joined = false;
    _topicSubs
      ..add(topic.activity.listen((_) => _soon()))
      ..add(topic.status.listen((state) {
        if (state != RealtimeSubscribeStatus.subscribed) return;
        if (joined) _soon();
        joined = true;
      }));
  }

  void _soon() {
    if (!mounted) return;
    _debounce?.cancel();
    _debounce = Timer(_settle, () {
      if (mounted) refreshWhenVisible();
    });
  }

  @override
  Future<void> liveRefresh() => _reloadAll();

  @override
  void onDataChange(DataChange change) {
    switch (change) {
      case RsvpChanged(:final partyId) ||
            PartyUpdated(:final partyId) ||
            PartyCoverChanged(:final partyId) ||
            PartyCancelled(:final partyId) when partyId == widget.partyId:
        refreshWhenVisible();
      case BlockChanged():
        // A block hides that guest from the list (not from the numbers).
        refreshWhenVisible();
      default:
    }
  }

  /// Refetches everything, keeping what is on screen until each answer lands.
  Future<void> _reloadAll() async {
    final coverBefore = _stats?.coverPath;
    await Future.wait([
      _loadStats(),
      _loadTimeline(),
      _loadGuests(_goingTab, reset: true),
    ]);
    // The other tab is fetched again the next time it is shown.
    _guests[!_goingTab] = _GuestList();
    final stats = _stats;
    if (stats != null && stats.coverPath != coverBefore) unawaited(_loadCover(stats.coverPath));
  }

  Future<void> _loadStats() async {
    try {
      final stats = await _repository.fetchHostStats(widget.partyId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _statsFailed = stats == null;
        // A private party has one guest tab.
        if (stats != null && stats.isPrivate) _goingTab = true;
      });
    } catch (_) {
      if (mounted) setState(() => _statsFailed = _stats == null);
    }
  }

  Future<void> _loadCover(String? path) async {
    try {
      final url = await _repository.signedCoverUrl(path);
      if (mounted) setState(() => _coverUrl = url);
    } catch (_) {
      // The placeholder is already the right answer.
    }
  }

  Future<void> _loadTimeline() async {
    try {
      final timeline = await _repository.fetchRsvpTimeline(widget.partyId);
      if (mounted) {
        setState(() {
          _timeline = timeline;
          _timelineFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _timelineFailed = _timeline == null);
    }
  }

  Future<void> _loadGuests(bool goingOnly, {bool reset = false}) async {
    final list = _guests[goingOnly]!;
    if (list.loading) return;
    final after = reset ? null : list.cursor;
    setState(() => list.loading = true);
    try {
      final page = await _repository.fetchGuests(widget.partyId, goingOnly: goingOnly, after: after);
      if (!mounted) return;
      setState(() {
        if (reset) list.items.clear();
        list.items.addAll(page.guests);
        list.cursor = page.cursor;
        list.loaded = true;
        list.failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => list.failed = true);
    } finally {
      if (mounted) setState(() => list.loading = false);
    }
  }

  void _showTab(bool going) {
    setState(() => _goingTab = going);
    if (!_guests[going]!.loaded) unawaited(_loadGuests(going, reset: true));
  }

  // ---------------------------------------------------------------- actions

  void _share(HostPartyStats stats) {
    (widget.share ?? systemShare)(
      partyShareText(partyId: stats.partyId, title: stats.title, isPrivate: stats.isPrivate),
    );
  }

  Future<void> _edit(HostPartyStats stats) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => HostWizardScreen(
        repository: _repository,
        profiles: widget.profiles,
        edit: stats,
        editCoverUrl: _coverUrl,
      ),
    ));
    if (saved == true && mounted) unawaited(_reloadAll());
  }

  Future<void> _cancel(HostPartyStats stats) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Cancel this party?'),
        content: Text(
          'It disappears from the map, every list and its link. '
          '${stats.isPrivate ? 'Your guests' : 'People who said they’d come'} are not notified, '
          'so let them know yourself. This can’t be undone.',
          style: TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.textAlpha(0.75)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('confirm-cancel-party'),
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Cancel party'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelling = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repository.cancelParty(stats.partyId);
      messenger.showSnackBar(
        const SnackBar(content: Text('Party cancelled.'), behavior: SnackBarBehavior.floating),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That did not save.'), behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  /// The attendee sheet, as a guest would get it: counts withheld on a
  /// private party (what the read RPCs send a guest), no RSVP of the host's
  /// own, and every action that would write disabled.
  Future<void> _viewAsGuest(HostPartyStats stats) async {
    String? username;
    try {
      username = (await _profiles.fetchProfile())?.username;
    } catch (_) {}
    if (!mounted) return;

    final pin = MapPartyPin(
      id: stats.partyId,
      lat: stats.lat,
      lng: stats.lng,
      title: stats.title,
      isPrivate: stats.isPrivate,
      goingCount: stats.isPrivate ? null : stats.goingCount,
      interestedCount: stats.isPrivate ? null : stats.interestedCount,
      startsAt: stats.startsAt,
      endsAt: stats.endsAt,
      area: stats.area,
      description: stats.description,
      hostId: _repository.currentUserId,
      hostUsername: username,
      coverPath: stats.coverPath,
    );
    await showMapPinSheet(context, pin, repository: _repository, asGuest: true);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('Your party', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: stats == null
          ? (_statsFailed ? _unavailable() : _loadingSkeleton())
          : RefreshIndicator(
              color: AppColors.purple,
              onRefresh: _reloadAll,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _header(stats),
                  const SizedBox(height: 16),
                  _tiles(stats),
                  const SizedBox(height: 22),
                  _sectionTitle(stats.isPrivate ? 'COMING OVER TIME' : 'RSVPS OVER TIME'),
                  _card(_chartBody(stats)),
                  const SizedBox(height: 22),
                  _sectionTitle('FOLLOWERS AMONG GUESTS'),
                  _card(_followers(stats)),
                  const SizedBox(height: 22),
                  _sectionTitle('GUEST LIST'),
                  _guestList(stats),
                  const SizedBox(height: 22),
                  _actions(stats),
                ],
              ),
            ),
    );
  }

  Widget _unavailable() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('This dashboard isn’t available.',
                style: TextStyle(fontSize: 14, color: AppColors.textAlpha(0.7))),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                setState(() => _statsFailed = false);
                unawaited(_reloadAll());
              },
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingSkeleton() {
    return ListView(
      key: const Key('dashboard-skeleton'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const AspectRatio(aspectRatio: 16 / 9, child: SkeletonBox(height: double.infinity, radius: 14)),
        const SizedBox(height: 14),
        const SkeletonBox(width: 220, height: 22, radius: 6),
        const SizedBox(height: 8),
        const SkeletonBox(width: 140, height: 14, radius: 6),
        const SizedBox(height: 18),
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              const Expanded(child: SkeletonBox(height: 70)),
            ],
          ],
        ),
        const SizedBox(height: 22),
        const SkeletonBox(height: 210, radius: 16),
      ],
    );
  }

  Widget _header(HostPartyStats stats) {
    final placeholder = DiagonalStripePlaceholder(
      colors: stats.isPrivate
          ? const [Color(0xFF2C1F2A), Color(0xFF20161F)]
          : const [Color(0xFF2A2247), Color(0xFF1E1836)],
      label: stats.coverPath == null ? 'no cover yet' : null,
    );
    final url = _coverUrl;
    final when = stats.isOver || stats.isCancelled
        ? formatPartyPastEn(stats.startsAt)
        : formatPartyStartEn(stats.startsAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: url == null
                ? placeholder
                : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
          ),
        ),
        const SizedBox(height: 14),
        Text(stats.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
        const SizedBox(height: 4),
        Text(
          [when, if (stats.area != null) stats.area!].join(' · '),
          style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.65)),
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            PrivacyBadge(isPrivate: stats.isPrivate, fontSize: 9),
            const SizedBox(width: 6),
            _phaseChip(stats.phase),
          ],
        ),
      ],
    );
  }

  Widget _phaseChip(HostPartyPhase phase) {
    final color = switch (phase) {
      HostPartyPhase.live => AppColors.pinkLight,
      HostPartyPhase.upcoming => AppColors.purpleLight,
      HostPartyPhase.ended => AppColors.textAlpha(0.55),
      HostPartyPhase.cancelled => AppColors.destructive,
    };
    return Container(
      key: Key('phase-${phase.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(phase.label, style: AppTextStyles.mono(size: 9, color: color)),
    );
  }

  /// The headline numbers. Interested includes everyone going, so the tiles
  /// are never added up. "Here now" is going_count once the party has
  /// started — nobody checks in yet (docs/backlog.md 1.23), and the caption
  /// says so rather than letting the number pass for a headcount.
  Widget _tiles(HostPartyStats stats) {
    final tiles = <Widget>[
      if (stats.isPrivate)
        _tile('Coming', stats.goingCount, key: const Key('tile-coming'))
      else ...[
        _tile('Going', stats.goingCount, key: const Key('tile-going')),
        _tile('Interested', stats.interestedCount, key: const Key('tile-interested')),
      ],
      if (stats.isLive)
        _tile('Here now', stats.goingCount, caption: 'said they’d come', key: const Key('tile-here-now')),
    ];
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }

  Widget _tile(String label, int value, {String? caption, Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.5))),
          const SizedBox(height: 4),
          Text('$value', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          if (caption != null)
            Text(caption, style: TextStyle(fontSize: 10, color: AppColors.textAlpha(0.45))),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(text, style: AppTextStyles.mono(size: 10, color: AppColors.textAlpha(0.45))),
      );

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.hairline),
        ),
        child: child,
      );

  Widget _chartBody(HostPartyStats stats) {
    final timeline = _timeline;
    if (timeline == null) {
      return _timelineFailed
          ? _notice('The chart didn’t load.', action: ('Try again', _loadTimeline))
          : const SkeletonBox(key: Key('chart-skeleton'), height: 180);
    }
    if (timeline.isEmpty) {
      return _notice(
        'No RSVPs yet — share your party',
        action: stats.isPublished ? ('Share', () async => _share(stats)) : null,
        key: const Key('chart-empty'),
      );
    }
    return RsvpTimelineChart(timeline: timeline, isPrivate: stats.isPrivate);
  }

  Widget _followers(HostPartyStats stats) {
    if (stats.isPrivate) {
      return FollowerSplitBar(
        label: 'Coming',
        followers: stats.goingFollowers,
        nonFollowers: stats.goingNonFollowers,
        color: AppColors.private,
      );
    }
    return Column(
      children: [
        FollowerSplitBar(label: 'Going', followers: stats.goingFollowers, nonFollowers: stats.goingNonFollowers),
        const SizedBox(height: 16),
        FollowerSplitBar(
          label: 'Interested',
          followers: stats.interestedFollowers,
          nonFollowers: stats.interestedNonFollowers,
        ),
      ],
    );
  }

  Widget _guestList(HostPartyStats stats) {
    final list = _guests[_goingTab]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (stats.isPrivate)
              _tabChip('Coming · ${stats.goingCount}', selected: true, onTap: () {})
            else ...[
              _tabChip('Going · ${stats.goingCount}', selected: _goingTab, onTap: () => _showTab(true)),
              const SizedBox(width: 8),
              _tabChip('Interested · ${stats.interestedCount}', selected: !_goingTab, onTap: () => _showTab(false)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (!list.loaded && list.failed)
          _notice('The guest list didn’t load.', action: ('Try again', () => _loadGuests(_goingTab, reset: true)))
        else if (!list.loaded)
          Column(children: [
            for (var i = 0; i < 3; i++)
              const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(height: 48)),
          ])
        else if (list.items.isEmpty)
          _notice(
            _goingTab
                ? (stats.isPrivate ? 'Nobody has said they’re coming yet.' : 'Nobody is going yet.')
                : 'Nobody is interested yet.',
          )
        else ...[
          for (final guest in list.items) _guestRow(guest, badgeGoing: !_goingTab),
          if (list.cursor != null)
            Center(
              child: TextButton(
                onPressed: list.loading ? null : () => _loadGuests(_goingTab),
                child: Text(list.loading ? 'Loading…' : 'Show more'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _tabChip(String label, {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? Colors.white.withValues(alpha: 0.25) : AppColors.hairline),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.text : AppColors.textAlpha(0.6),
            )),
      ),
    );
  }

  Widget _guestRow(PartyGuest guest, {required bool badgeGoing}) {
    final url = _avatarUrl(guest.avatarPath);
    return UserLink(
      userId: guest.userId,
      username: guest.username,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: url == null
                  ? const DiagonalStripePlaceholder(colors: [Color(0xFF2A2247), Color(0xFF1E1836)])
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const DiagonalStripePlaceholder(colors: [Color(0xFF2A2247), Color(0xFF1E1836)]),
                    ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text('@${guest.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            if (guest.followsHost) _badge('FOLLOWS YOU'),
            if (badgeGoing && guest.going) ...[
              const SizedBox(width: 6),
              _badge('GOING', color: AppColors.purpleLight),
            ],
          ],
        ),
      ),
    );
  }

  String? _avatarUrl(String? path) {
    try {
      return _profiles.avatarUrl(path);
    } catch (_) {
      return null;
    }
  }

  Widget _badge(String text, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: AppTextStyles.mono(size: 8.5, color: color ?? AppColors.textAlpha(0.6))),
      );

  Widget _notice(String text, {(String, Future<void> Function())? action, Key? key}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      child: Column(
        children: [
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
          if (action != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(onPressed: () => action.$2(), child: Text(action.$1)),
          ],
        ],
      ),
    );
  }

  Widget _actions(HostPartyStats stats) {
    final canChange = stats.isPublished;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _actionButton(
                key: const Key('dashboard-edit'),
                icon: Icons.edit_outlined,
                label: 'Edit party',
                onPressed: canChange ? () => _edit(stats) : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _actionButton(
                key: const Key('dashboard-share'),
                icon: Icons.ios_share,
                label: 'Share',
                // A cancelled party's link opens nothing.
                onPressed: canChange ? () => _share(stats) : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _actionButton(
          key: const Key('dashboard-view-as-guest'),
          icon: Icons.visibility_outlined,
          label: 'View as guest',
          onPressed: () => _viewAsGuest(stats),
        ),
        if (canChange && !stats.isOver) ...[
          const SizedBox(height: 18),
          OutlinedButton(
            key: const Key('dashboard-cancel'),
            onPressed: _cancelling ? null : () => _cancel(stats),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
              foregroundColor: AppColors.destructive,
              side: BorderSide(color: AppColors.destructive.withValues(alpha: 0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel party',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ),
        ],
      ],
    );
  }

  Widget _actionButton({required Key key, required IconData icon, required String label, VoidCallback? onPressed}) {
    return OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 13),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        backgroundColor: Colors.white.withValues(alpha: 0.06),
        foregroundColor: AppColors.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// One guest tab's loaded pages.
class _GuestList {
  final List<PartyGuest> items = [];
  PartyGuest? cursor;
  bool loaded = false;
  bool loading = false;
  bool failed = false;
}
