import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../data/profile_repository.dart';
import '../../models/host_party_stats.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';

/// The host's followers, to invite to a party that already exists.
///
/// Everything that decides who appears is the server's
/// (`get_invitable_followers`): people who follow the host, minus
/// block-paired accounts, searched by username. Someone already invited or
/// already answered is shown locked, with what they are, so a second invite
/// is never on offer. Pops with the number of invitations actually written.
class InviteFollowersScreen extends StatefulWidget {
  const InviteFollowersScreen({
    super.key,
    required this.partyId,
    required this.isPrivate,
    this.repository,
    this.profiles,
  });

  final String partyId;

  /// Decides the wording of a locked row: a private party's "going" is "Coming".
  final bool isPrivate;
  final PartyRepository? repository;
  final ProfileRepository? profiles;

  @override
  State<InviteFollowersScreen> createState() => _InviteFollowersScreenState();
}

class _InviteFollowersScreenState extends State<InviteFollowersScreen> {
  late final PartyRepository _repository = widget.repository ?? PartyRepository();
  late final ProfileRepository _profiles = widget.profiles ?? ProfileRepository();

  static const _searchSettle = Duration(milliseconds: 300);

  final _search = TextEditingController();
  Timer? _debounce;

  final List<InvitableFollower> _people = [];
  InvitableFollower? _cursor;
  bool _loaded = false;
  bool _loading = false;
  bool _failed = false;

  /// Bumped per search, so a slow answer to an old query cannot land on top
  /// of a newer one.
  int _generation = 0;

  final Set<String> _selected = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(_searchSettle, () => _load(reset: true));
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      if (reset) _failed = false;
    });
    try {
      final page = await _repository.fetchInvitableFollowers(
        widget.partyId,
        query: _search.text.trim().isEmpty ? null : _search.text.trim(),
        after: reset ? null : _cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (reset) _people.clear();
        _people.addAll(page.followers);
        _cursor = page.cursor;
        _loaded = true;
        _failed = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final written = await _repository.inviteToParty(widget.partyId, _selected.toList());
      if (mounted) Navigator.of(context).pop(written);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The invites didn’t go out. Try again.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  String _lockedLabel(InvitableFollower f) {
    switch (f.rsvpStatus) {
      case 'going':
        return widget.isPrivate ? 'Coming' : 'Going';
      case 'interested':
        return 'Interested';
      default:
        return 'Invited';
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _selected.length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('Invite followers', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const Key('invite-search'),
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: 'Search your followers',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                  borderSide: BorderSide(color: AppColors.hairline),
                ),
              ),
            ),
          ),
          Expanded(child: _list()),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('send-invites'),
                  onPressed: n == 0 || _sending ? null : _send,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: AppColors.purple,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.white.withValues(alpha: 0.08),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    _sending ? 'Sending…' : (n == 0 ? 'Send invites' : 'Send ${n == 1 ? '1 invite' : '$n invites'}'),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (!_loaded && _failed) {
      return _notice('Your followers didn’t load.', retry: true);
    }
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2));
    }
    if (_people.isEmpty) {
      final q = _search.text.trim();
      return _notice(q.isEmpty ? 'Nobody follows you yet.' : 'No followers match “$q”.');
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (final f in _people) _row(f),
        if (_cursor != null)
          Center(
            child: TextButton(
              onPressed: _loading ? null : () => _load(),
              child: Text(_loading ? 'Loading…' : 'Show more'),
            ),
          ),
      ],
    );
  }

  Widget _row(InvitableFollower f) {
    final selected = _selected.contains(f.userId);
    String? url;
    try {
      url = _profiles.avatarUrl(f.avatarPath);
    } catch (_) {}
    const placeholder = DiagonalStripePlaceholder(colors: [Color(0xFF2A2247), Color(0xFF1E1836)]);

    return InkWell(
      key: Key('follower-${f.userId}'),
      onTap: f.locked
          ? null
          : () => setState(() => selected ? _selected.remove(f.userId) : _selected.add(f.userId)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: url == null
                  ? placeholder
                  : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                '@${f.username}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: f.locked ? AppColors.textAlpha(0.5) : AppColors.text,
                ),
              ),
            ),
            if (f.locked)
              Text(_lockedLabel(f), style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.5)))
            else
              Checkbox(
                value: selected,
                onChanged: (_) => setState(() => selected ? _selected.remove(f.userId) : _selected.add(f.userId)),
                activeColor: AppColors.purple,
              ),
          ],
        ),
      ),
    );
  }

  Widget _notice(String text, {bool retry = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.6))),
            if (retry) ...[
              const SizedBox(height: 10),
              OutlinedButton(onPressed: () => _load(reset: true), child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
