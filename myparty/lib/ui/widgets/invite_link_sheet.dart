import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/invite_link_store.dart';
import '../../data/party_repository.dart';
import '../../models/host_party_stats.dart';
import '../../utils/party_link.dart';
import '../../utils/share_party.dart';
import '../theme/app_theme.dart';

/// "Invite with link" for a PRIVATE party: create, share, copy, regenerate or
/// turn off the party's invite link (20261014133500).
///
/// The server keeps only the token's hash, so this sheet can show a link only
/// if THIS device made it ([InviteLinkStore]). Otherwise it says so, plainly:
/// sharing from here means a new link, and a new link turns the old one off.
/// People who already joined keep their invitation either way — removing them
/// is the guest list's Remove.
Future<void> showInviteLinkSheet(
  BuildContext context, {
  required String partyId,
  required PartyRepository repository,
  InviteLinkStore? store,
  ShareText? share,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InviteLinkSheet(partyId: partyId, repository: repository, store: store, share: share),
  );
}

class InviteLinkSheet extends StatefulWidget {
  const InviteLinkSheet({
    super.key,
    required this.partyId,
    required this.repository,
    this.store,
    this.share,
  });

  final String partyId;
  final PartyRepository repository;
  final InviteLinkStore? store;
  final ShareText? share;

  @override
  State<InviteLinkSheet> createState() => _InviteLinkSheetState();
}

class _InviteLinkSheetState extends State<InviteLinkSheet> {
  late final InviteLinkStore _store = widget.store ?? InviteLinkStore();

  /// The max-uses choices the dashboard offers; null is "no limit".
  static const maxUseChoices = <int?>[null, 10, 25, 50];

  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  InviteLinkStatus? _status;
  String? _token;
  int? _maxUses;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final status = await widget.repository.fetchInviteLink(widget.partyId);
      final token = status == null ? null : await _store.tokenFor(widget.partyId, status.createdAt);
      if (!mounted) return;
      setState(() {
        _status = status;
        _token = token;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final token = await widget.repository.createInviteLink(widget.partyId, maxUses: _maxUses);
      final status = await widget.repository.fetchInviteLink(widget.partyId);
      if (status != null) await _store.save(widget.partyId, token, status.createdAt);
      if (!mounted) return;
      setState(() {
        _status = status;
        _token = token;
      });
    } catch (_) {
      _say('The link wasn’t created. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    if (!await _confirm(
      title: 'Turn off this link?',
      body: 'Nobody new can join with it. People who already joined keep their invitation — '
          'remove them from the guest list if you need to.',
      action: 'Turn off',
    )) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.repository.disableInviteLink(widget.partyId);
      await _store.forget(widget.partyId);
      if (!mounted) return;
      setState(() {
        _status = null;
        _token = null;
      });
    } catch (_) {
      _say('That did not save.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenerate() async {
    if (!await _confirm(
      title: 'Make a new link?',
      body: 'The current link stops working straight away. People who already joined keep their invitation.',
      action: 'New link',
    )) {
      return;
    }
    await _create();
  }

  Future<bool> _confirm({required String title, required String body, required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: Text(title),
        content: Text(body, style: TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.textAlpha(0.75))),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep it')),
          TextButton(
            key: const Key('confirm-link-action'),
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.destructive),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  Future<void> _copy(String token) async {
    await Clipboard.setData(ClipboardData(text: inviteLink(token).toString()));
    _say('Link copied.');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Invite with link', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'Anyone who opens the link while signed in gets an invitation to this private party.',
              style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.textAlpha(0.6)),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator(color: AppColors.purple, strokeWidth: 2))
            else if (_failed)
              Center(child: OutlinedButton(onPressed: _load, child: const Text('Try again')))
            else
              ..._body(),
          ],
        ),
      ),
    );
  }

  List<Widget> _body() {
    final status = _status;
    final token = _token;

    if (status == null) {
      return [
        _maxUsesPicker(),
        const SizedBox(height: 14),
        _primary('Create link', key: const Key('create-link'), onPressed: _busy ? null : _create),
      ];
    }

    final uses = status.maxUses == null
        ? '${status.useCount} joined'
        : status.usedUp
            ? 'Used up · ${status.useCount} of ${status.maxUses} joined'
            : '${status.useCount} of ${status.maxUses} joined';

    if (token == null) {
      // Made on another device (or this one, before a reinstall). Not
      // recoverable, by design.
      return [
        Text(uses, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.55))),
        const SizedBox(height: 10),
        Container(
          key: const Key('link-other-device'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Text(
            'This link was made on another device, and for security it can’t be shown again here. '
            'To share from this phone, make a new link — that turns the old one off, '
            'so anyone you sent it to will need the new one.',
            style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.textAlpha(0.75)),
          ),
        ),
        const SizedBox(height: 14),
        _maxUsesPicker(),
        const SizedBox(height: 14),
        _primary('Make a new link', key: const Key('regenerate-link'), onPressed: _busy ? null : _regenerate),
        const SizedBox(height: 8),
        _secondary('Turn off link', key: const Key('disable-link'), onPressed: _busy ? null : _turnOff),
      ];
    }

    return [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Text(
          inviteLink(token).toString(),
          key: const Key('invite-link-text'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.mono(size: 11.5, color: AppColors.textAlpha(0.8)),
        ),
      ),
      const SizedBox(height: 6),
      Text(uses, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.55))),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(child: _primary('Copy link', key: const Key('copy-link'), onPressed: () => _copy(token))),
          const SizedBox(width: 8),
          Expanded(
            child: _secondary(
              'Share',
              key: const Key('share-link'),
              onPressed: () => (widget.share ?? systemShare)(inviteShareText(token)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: _secondary('New link', key: const Key('regenerate-link'), onPressed: _busy ? null : _regenerate)),
          const SizedBox(width: 8),
          Expanded(child: _secondary('Turn off', key: const Key('disable-link'), onPressed: _busy ? null : _turnOff)),
        ],
      ),
    ];
  }

  Widget _maxUsesPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('HOW MANY PEOPLE CAN JOIN WITH IT', style: AppTextStyles.mono(size: 9.5, color: AppColors.textAlpha(0.45))),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final n in maxUseChoices)
              ChoiceChip(
                key: Key('max-uses-${n ?? 'none'}'),
                label: Text(n == null ? 'No limit' : '$n'),
                selected: _maxUses == n,
                onSelected: (_) => setState(() => _maxUses = n),
              ),
          ],
        ),
      ],
    );
  }

  Widget _primary(String label, {required Key key, VoidCallback? onPressed}) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          key: key,
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 13),
            backgroundColor: AppColors.private,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        ),
      );

  Widget _secondary(String label, {required Key key, VoidCallback? onPressed}) => SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          key: key,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 13),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            foregroundColor: AppColors.text,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          ),
          child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
        ),
      );
}
