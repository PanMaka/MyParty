import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../models/party_list_item.dart';
import '../../services/party_links.dart';
import '../../state/mp_store.dart' show MpRsvp;
import 'party_detail_sheet.dart';

/// Opens the party a link points at, once someone is signed in to see it.
///
/// Wraps the signed-in root, so it exists only after sign-in and onboarding;
/// a link opened before then waits in [PartyLinks.pending] and is consumed
/// here on first build. The party is fetched with `get_party` under the
/// viewer's own session and shown in the same [PartyDetailSheet] the parties
/// tab uses, so a link grants exactly what browsing would.
///
/// When the party is not available the message is the same whatever the
/// reason — no such party, not invited, cancelled, ended, or a network error.
/// Telling those apart would tell a stranger holding a private party's link
/// that the party exists.
class PartyLinkHandler extends StatefulWidget {
  const PartyLinkHandler({
    super.key,
    required this.child,
    this.repository,
    this.pending,
    this.pendingInvite,
  });

  final Widget child;

  /// Injectable so widget tests can fake the fetch, as every screen does.
  final PartyRepository? repository;

  /// Defaults to the app-scoped [PartyLinks.pending]; tests hand in their own.
  final ValueNotifier<String?>? pending;

  /// Defaults to [PartyLinks.pendingInvite]: an invite-link token to redeem.
  final ValueNotifier<String?>? pendingInvite;

  @override
  State<PartyLinkHandler> createState() => _PartyLinkHandlerState();
}

class _PartyLinkHandlerState extends State<PartyLinkHandler> {
  late final PartyRepository _parties = widget.repository ?? PartyRepository();
  late final ValueNotifier<String?> _pending = widget.pending ?? PartyLinks.pending;
  late final ValueNotifier<String?> _pendingInvite = widget.pendingInvite ?? PartyLinks.pendingInvite;

  @override
  void initState() {
    super.initState();
    _pending.addListener(_open);
    _pendingInvite.addListener(_redeem);
    // A link that arrived before sign-in is already waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open();
      _redeem();
    });
  }

  @override
  void dispose() {
    _pending.removeListener(_open);
    _pendingInvite.removeListener(_redeem);
    super.dispose();
  }

  Future<void> _open() async {
    final id = _pending.value;
    if (id == null || !mounted) return;
    // Consumed before the fetch, so the same link is never opened twice.
    _pending.value = null;
    await _show(id);
  }

  /// An invite link: redeem the token first (which writes the invitation),
  /// then open the party exactly as a party link would. One sentence for
  /// every refusal, because the server gives one reason for all of them —
  /// telling "you were blocked" from "the link was turned off" would make the
  /// link a block oracle. The rate limit is the exception, and says only that.
  Future<void> _redeem() async {
    final token = _pendingInvite.value;
    if (token == null || !mounted) return;
    _pendingInvite.value = null;

    final messenger = ScaffoldMessenger.of(context);
    String partyId;
    try {
      partyId = await _parties.redeemInvite(token);
    } on InviteRefused catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.rateLimited
            ? 'You’ve opened a lot of invite links. Try again in a while.'
            : 'This invite link doesn’t work any more.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
        content: Text('This invite link doesn’t work any more.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (!mounted) return;
    await _show(partyId);
  }

  Future<void> _show(String id) async {
    final item = await _fetch(id);
    if (!mounted) return;

    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This party isn’t available.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    String? coverUrl;
    try {
      coverUrl = await _parties.signedCoverUrl(item.coverPath);
    } catch (_) {
      // A missing cover is the placeholder, not a failure to open the party.
    }
    if (!mounted) return;
    await showPartyDetailSheet(
      context,
      item,
      repository: _parties,
      coverUrl: coverUrl,
      onRsvp: (status) => _answer(item, status),
    );
  }

  /// An answer given on a linked party. There is no list under this sheet to
  /// own the write, so it is made here; PartyRepository.setRsvp announces it,
  /// which is what reaches MY PARTIES and the map. The sheet has already
  /// closed, so only a failure has anything to say.
  Future<void> _answer(PartyListItem item, MpRsvp status) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _parties.setRsvp(partyId: item.partyId, status: status, current: item.myRsvp);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That did not save.'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<PartyListItem?> _fetch(String id) async {
    try {
      return await _parties.fetchParty(id);
    } catch (error) {
      debugPrint('Party link $id could not be opened: $error');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
