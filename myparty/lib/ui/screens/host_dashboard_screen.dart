import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import '../../data/invite_link_store.dart';

import '../../data/party_host_channel.dart';
import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../models/host_party_stats.dart';
import '../../models/map_party_pin.dart';
import '../../state/data_changes.dart';
import '../../state/live_refresh.dart';
import '../../utils/english_date.dart';
import '../../utils/party_link.dart';
import '../../utils/share_party.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';
import '../widgets/follower_split_bar.dart';
import '../widgets/invite_link_sheet.dart';
import '../widgets/map_pin_sheet.dart';
import '../widgets/mp_bottom_nav.dart' show MpTab;
import '../widgets/privacy_badge.dart';
import '../widgets/skeleton_box.dart';
import '../widgets/user_link.dart';
import 'host_wizard_screen.dart';
import 'invite_followers_screen.dart';

/// What a host sees when they open their own party, from any door — a map
/// pin, a search hit, MY PARTIES, ALL PARTIES, a party link, or their own
/// profile. [showMapPinSheet] and [showPartyDetailSheet] redirect here when
/// the viewer is the host, so no door can forget to.
///
/// Every number comes from host-only server functions (20261014113213): the
/// header and aggregates from `get_party_host_stats`, the Going/Interested
/// lists from `get_party_guests`, the Invited list from `get_party_invitees`.
/// Nothing here computes a count. (`get_party_rsvp_timeline` still exists and
/// is still fed; the chart that drew it was removed in Phase 40.)
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
    this.linkStore,
  });

  final String partyId;
  final PartyRepository? repository;

  /// Guest avatars, and the host's own username for "View as guest".
  final ProfileRepository? profiles;

  /// The system share sheet by default; tests record instead.
  final ShareText? share;

  /// This device's copy of invite-link tokens; tests hand in their own.
  final InviteLinkStore? linkStore;

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

  /// The guest tab on screen. A private party has no Interested tab.
  _GuestTab _tab = _GuestTab.going;
  final Map<_GuestTab, _GuestList> _guests = {for (final t in _GuestTab.values) t: _GuestList()};

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
            PartyCancelled(:final partyId) ||
            PartyGuestsChanged(:final partyId) when partyId == widget.partyId:
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
      _loadGuests(_tab, reset: true),
    ]);
    // The other tabs are fetched again the next time they are shown.
    for (final t in _GuestTab.values) {
      if (t != _tab) _guests[t] = _GuestList();
    }
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
        // A private party has no Interested tab.
        if (stats != null && stats.isPrivate && _tab == _GuestTab.interested) _tab = _GuestTab.going;
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

  Future<void> _loadGuests(_GuestTab tab, {bool reset = false}) async {
    final list = _guests[tab]!;
    if (list.loading) return;
    final after = reset ? null : list.cursor;
    setState(() => list.loading = true);
    try {
      final (rows, cursor) = await _fetchRows(tab, after);
      if (!mounted) return;
      setState(() {
        if (reset) list.items.clear();
        list.items.addAll(rows);
        list.cursor = cursor;
        list.loaded = true;
        list.failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => list.failed = true);
    } finally {
      if (mounted) setState(() => list.loading = false);
    }
  }

  /// One page of [tab], as rows the list draws. Going/Interested read rsvps
  /// (`get_party_guests`); Invited reads invitations (`get_party_invitees`),
  /// which is where someone who joined through a link and never answered is.
  Future<(List<_GuestRow>, Object?)> _fetchRows(_GuestTab tab, Object? after) async {
    final private = _stats?.isPrivate ?? false;
    if (tab == _GuestTab.invited) {
      final page = await _repository.fetchInvitees(widget.partyId, after: after as PartyInvitee?);
      return (
        [
          for (final i in page.invitees)
            _GuestRow(
              userId: i.userId,
              username: i.username,
              avatarPath: i.avatarPath,
              badges: [
                if (i.viaLink) ('VIA LINK', null),
                switch (i.rsvpStatus) {
                  'going' => (private ? 'COMING' : 'GOING', AppColors.purpleLight),
                  'interested' => ('INTERESTED', AppColors.purpleLight),
                  _ => ('NO ANSWER', null),
                },
              ],
            ),
        ],
        page.cursor,
      );
    }
    final goingOnly = tab == _GuestTab.going;
    final page = await _repository.fetchGuests(widget.partyId, goingOnly: goingOnly, after: after as PartyGuest?);
    return (
      [
        for (final g in page.guests)
          _GuestRow(
            userId: g.userId,
            username: g.username,
            avatarPath: g.avatarPath,
            badges: [
              if (g.followsHost) ('FOLLOWS YOU', null),
              if (!goingOnly && g.going) ('GOING', AppColors.purpleLight),
            ],
          ),
      ],
      page.cursor,
    );
  }

  void _showTab(_GuestTab tab) {
    setState(() => _tab = tab);
    if (!_guests[tab]!.loaded) unawaited(_loadGuests(tab, reset: true));
  }

  // ---------------------------------------------------------------- actions

  void _share(HostPartyStats stats) {
    (widget.share ?? systemShare)(
      partyShareText(partyId: stats.partyId, title: stats.title, isPrivate: stats.isPrivate),
    );
  }

  /// The two ways to invite. A public party's link is its ordinary /p/ link
  /// (it already opens for everyone); a private party's is an invite link,
  /// which grants an invitation and is managed in its own sheet.
  Future<void> _invite(HostPartyStats stats) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.sheet,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            ListTile(
              key: const Key('invite-followers'),
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('Invite followers'),
              subtitle: const Text('Pick people who follow you'),
              onTap: () {
                Navigator.of(sheet).pop();
                _inviteFollowers(stats);
              },
            ),
            if (stats.isPrivate)
              ListTile(
                key: const Key('invite-with-link'),
                leading: const Icon(Icons.link),
                title: const Text('Invite with link'),
                subtitle: const Text('Anyone who opens it gets an invitation'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  showInviteLinkSheet(
                    context,
                    partyId: stats.partyId,
                    repository: _repository,
                    store: widget.linkStore,
                    share: widget.share,
                  );
                },
              )
            else ...[
              ListTile(
                key: const Key('share-party-link'),
                leading: const Icon(Icons.ios_share),
                title: const Text('Share link'),
                subtitle: const Text('Your party is public, so the link opens it for anyone'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _share(stats);
                },
              ),
              ListTile(
                key: const Key('copy-party-link'),
                leading: const Icon(Icons.copy),
                title: const Text('Copy link'),
                onTap: () async {
                  Navigator.of(sheet).pop();
                  await Clipboard.setData(ClipboardData(text: partyLink(stats.partyId).toString()));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copied.'), behavior: SnackBarBehavior.floating),
                  );
                },
              ),
            ],
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _inviteFollowers(HostPartyStats stats) async {
    final written = await Navigator.of(context).push<int>(MaterialPageRoute(
      builder: (_) => InviteFollowersScreen(
        partyId: stats.partyId,
        isPrivate: stats.isPrivate,
        repository: _repository,
        profiles: widget.profiles,
      ),
    ));
    if (written == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(written == 0
          ? 'Nobody new was invited.'
          : 'Invited ${written == 1 ? '1 person' : '$written people'}.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Takes someone off the guest list. Says what it does on THIS party: on a
  /// private one they lose it entirely and a leaked link will not bring them
  /// back; on a public one the party stays visible to them.
  Future<void> _remove(HostPartyStats stats, _GuestRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text('Remove @${row.username}?'),
        content: Text(
          stats.isPrivate
              ? 'They lose access to the party and its chat. Your invite link won’t let them back in — '
                  'only inviting them again yourself will.'
              : 'Their RSVP and invitation are removed. The party is public, so they can still see it '
                  'and answer again. Block them to keep them out completely.',
          style: TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.textAlpha(0.75)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          TextButton(
            key: const Key('confirm-remove-guest'),
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await _repository.removeGuest(stats.partyId, row.userId);
      messenger.showSnackBar(SnackBar(content: Text('Removed @${row.username}.'), behavior: SnackBarBehavior.floating));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('That did not save.'), behavior: SnackBarBehavior.floating));
    }
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
        const SkeletonBox(height: 120, radius: 16),
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
  /// are never added up.
  Widget _tiles(HostPartyStats stats) {
    final tiles = <Widget>[
      if (stats.isPrivate)
        _tile('Coming', stats.goingCount, key: const Key('tile-coming'))
      else ...[
        _tile('Going', stats.goingCount, key: const Key('tile-going')),
        _tile('Interested', stats.interestedCount, key: const Key('tile-interested')),
      ],
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

  Widget _tile(String label, int value, {Key? key}) {
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
    final list = _guests[_tab]!;
    final tabs = <(_GuestTab, String)>[
      (_GuestTab.going, '${stats.isPrivate ? 'Coming' : 'Going'} · ${stats.goingCount}'),
      if (!stats.isPrivate) (_GuestTab.interested, 'Interested · ${stats.interestedCount}'),
      (_GuestTab.invited, 'Invited'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (tab, label) in tabs)
              _tabChip(label, key: Key('tab-${tab.name}'), selected: _tab == tab, onTap: () => _showTab(tab)),
          ],
        ),
        const SizedBox(height: 10),
        if (!list.loaded && list.failed)
          _notice('The guest list didn’t load.', action: ('Try again', () => _loadGuests(_tab, reset: true)))
        else if (!list.loaded)
          Column(children: [
            for (var i = 0; i < 3; i++)
              const Padding(padding: EdgeInsets.only(bottom: 8), child: SkeletonBox(height: 48)),
          ])
        else if (list.items.isEmpty)
          _notice(switch (_tab) {
            _GuestTab.going => stats.isPrivate ? 'Nobody has said they’re coming yet.' : 'Nobody is going yet.',
            _GuestTab.interested => 'Nobody is interested yet.',
            _GuestTab.invited => 'Nobody is invited yet. Use Invite people below.',
          })
        else ...[
          for (final row in list.items) _guestRow(stats, row),
          if (list.cursor != null)
            Center(
              child: TextButton(
                onPressed: list.loading ? null : () => _loadGuests(_tab),
                child: Text(list.loading ? 'Loading…' : 'Show more'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _tabChip(String label, {Key? key, required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      key: key,
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

  Widget _guestRow(HostPartyStats stats, _GuestRow row) {
    final url = _avatarUrl(row.avatarPath);
    const placeholder = DiagonalStripePlaceholder(colors: [Color(0xFF2A2247), Color(0xFF1E1836)]);
    return Row(
      children: [
        Expanded(
          child: UserLink(
            userId: row.userId,
            username: row.username,
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
                        ? placeholder
                        : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text('@${row.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                  for (final (text, color) in row.badges) ...[
                    const SizedBox(width: 6),
                    _badge(text, color: color),
                  ],
                ],
              ),
            ),
          ),
        ),
        // Removing is a host action on a live guest list; a cancelled
        // party's list is history.
        if (!stats.isCancelled)
          IconButton(
            key: Key('remove-${row.userId}'),
            onPressed: () => _remove(stats, row),
            icon: Icon(Icons.person_remove_outlined, size: 19, color: AppColors.textAlpha(0.55)),
            tooltip: 'Remove',
          ),
      ],
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
        if (canChange && !stats.isOver) ...[
          ElevatedButton.icon(
            key: const Key('dashboard-invite'),
            onPressed: () => _invite(stats),
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: const Text('Invite people', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: stats.isPrivate ? AppColors.private : AppColors.purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 8),
        ],
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

enum _GuestTab { going, interested, invited }

/// One row of any guest tab, already turned into what the row draws.
class _GuestRow {
  const _GuestRow({required this.userId, required this.username, required this.avatarPath, required this.badges});

  final String userId;
  final String username;
  final String? avatarPath;

  /// Text and colour (null for the muted default).
  final List<(String, Color?)> badges;
}

/// One guest tab's loaded pages. [cursor] is the last row of the source
/// model (a PartyGuest or a PartyInvitee), echoed back for the next page.
class _GuestList {
  final List<_GuestRow> items = [];
  Object? cursor;
  bool loaded = false;
  bool loading = false;
  bool failed = false;
}
