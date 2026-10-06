import 'package:flutter/material.dart';

import '../../data/party_repository.dart';
import '../../models/party_list_item.dart';
import '../../services/party_links.dart';
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
  const PartyLinkHandler({super.key, required this.child, this.repository, this.pending});

  final Widget child;

  /// Injectable so widget tests can fake the fetch, as every screen does.
  final PartyRepository? repository;

  /// Defaults to the app-scoped [PartyLinks.pending]; tests hand in their own.
  final ValueNotifier<String?>? pending;

  @override
  State<PartyLinkHandler> createState() => _PartyLinkHandlerState();
}

class _PartyLinkHandlerState extends State<PartyLinkHandler> {
  late final PartyRepository _parties = widget.repository ?? PartyRepository();
  late final ValueNotifier<String?> _pending = widget.pending ?? PartyLinks.pending;

  @override
  void initState() {
    super.initState();
    _pending.addListener(_open);
    // A link that arrived before sign-in is already waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _pending.removeListener(_open);
    super.dispose();
  }

  Future<void> _open() async {
    final id = _pending.value;
    if (id == null || !mounted) return;
    // Consumed before the fetch, so the same link is never opened twice.
    _pending.value = null;

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
    await showPartyDetailSheet(context, item, coverUrl: coverUrl);
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
