import 'package:flutter/material.dart';

import '../../data/social_repository.dart';
import '../../models/profile.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';

/// The people you have blocked, each with an Unblock button.
///
/// This is the undo for the Block action on a profile, and it has to live
/// somewhere other than that profile: a block hides the pair from each other,
/// so the blocked account drops out of search, out of your Direct list and out
/// of every screen that could have led back to it. Only blocks YOU made are
/// listed — there is no way to ask who blocked you, here or anywhere.
class BlockedAccountsScreen extends StatefulWidget {
  const BlockedAccountsScreen({super.key, this.social});

  /// Injectable for tests; production callers let it default.
  final SocialRepository? social;

  @override
  State<BlockedAccountsScreen> createState() => _BlockedAccountsScreenState();
}

class _BlockedAccountsScreenState extends State<BlockedAccountsScreen> {
  late final SocialRepository _social = widget.social ?? SocialRepository();

  List<Profile>? _blocked;
  bool _failed = false;

  /// Ids with an unblock in flight, so a double tap does not send two.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final blocked = await _social.fetchBlocked();
      if (!mounted) return;
      setState(() {
        _blocked = blocked;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _unblock(Profile profile) async {
    if (_busy.contains(profile.id)) return;
    setState(() => _busy.add(profile.id));
    try {
      await _social.unblock(profile.id);
      if (!mounted) return;
      setState(() => _blocked?.removeWhere((p) => p.id == profile.id));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn’t unblock this account. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(profile.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: const Text('Blocked accounts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final blocked = _blocked;

    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Your blocked accounts didn’t load.',
                style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.6))),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }

    if (blocked == null) return const Center(child: CircularProgressIndicator());

    if (blocked.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'You haven’t blocked anyone.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textAlpha(0.5)),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: blocked.length,
      separatorBuilder: (_, _) => Container(height: 1, color: AppColors.hairline),
      itemBuilder: (_, i) {
        final profile = blocked[i];
        final busy = _busy.contains(profile.id);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: DiagonalStripePlaceholder(colors: profile.placeholderColors),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('@${profile.username}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: busy ? null : () => _unblock(profile),
                child: Text(busy ? '…' : 'Unblock'),
              ),
            ],
          ),
        );
      },
    );
  }
}
