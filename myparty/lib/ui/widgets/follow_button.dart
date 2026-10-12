import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/social_repository.dart';
import '../../state/data_changes.dart';
import '../theme/app_theme.dart';

/// Follow/unfollow a real profile. Replaces `MpStore.toggleFollow`, which was
/// a single app-wide bool shared by every screen that showed a follow button.
///
/// Owns its own state rather than living in `MpStore`: follow state is
/// per-target and server-authoritative, so a global ChangeNotifier flag was
/// always going to be wrong once more than one profile existed.
class FollowButton extends StatefulWidget {
  const FollowButton({
    super.key,
    required this.targetUserId,
    this.compact = false,
    this.repository,
    this.onChanged,
  });

  final String targetUserId;

  /// Called with the new state the instant the button flips, and again with
  /// the old one if the write is refused. This is how the follower count
  /// beside the button moves optimistically with it and rolls back with it —
  /// the counter belongs to the screen, the button only says what happened.
  final ValueChanged<bool>? onChanged;

  /// Pill-shaped variant used inside feed cards; the default is the wide
  /// block button on the profile screen.
  final bool compact;

  final SocialRepository? repository;

  @override
  State<FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<FollowButton> {
  late final SocialRepository _repository = widget.repository ?? SocialRepository();

  bool _following = false;
  bool _loading = true;

  /// Another copy of this button (the same profile pushed twice, a feed card)
  /// followed or unfollowed the same person, and the server said yes.
  StreamSubscription<DataChange>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = dataChanges.stream.listen((change) {
      if (change is FollowChanged && change.targetUserId == widget.targetUserId && mounted) {
        setState(() => _following = change.following);
      }
    });
    _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final following = await _repository.isFollowing(widget.targetUserId);
      if (!mounted) return;
      setState(() {
        _following = following;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    if (_loading) return;

    final wasFollowing = _following;
    // Optimistic: the tap should feel instant, but a block makes the insert
    // fail server-side (the follows INSERT policy), so the flag has to be
    // rolled back rather than assumed.
    setState(() => _following = !wasFollowing);
    widget.onChanged?.call(!wasFollowing);

    try {
      if (wasFollowing) {
        await _repository.unfollow(widget.targetUserId);
      } else {
        await _repository.follow(widget.targetUserId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _following = wasFollowing);
      widget.onChanged?.call(wasFollowing);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          // English because the button above it is. The same sentence is still
          // Greek in feed_screen, chat_screen and story_viewer_screen — it is
          // copied per screen rather than shared, so this one moved alone.
          content: Text('That did not work. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return _FollowSkin(
      following: _following,
      compact: widget.compact,
      onTap: _loading ? null : _toggle,
    );
  }
}

/// Every pixel of the button. A null [onTap] is how it spends its first frames,
/// while `isFollowing` is in flight.
class _FollowSkin extends StatelessWidget {
  const _FollowSkin({required this.following, required this.compact, this.onTap});

  final bool following;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = following ? 'Following' : 'Follow';

    if (compact) {
      return OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          backgroundColor: following ? Colors.white.withValues(alpha: 0.08) : null,
          side: following ? BorderSide.none : const BorderSide(color: AppColors.purple),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
          foregroundColor: following ? AppColors.textAlpha(0.6) : AppColors.purpleLight,
        ),
        child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: following ? null : AppColors.purpleGradient,
          color: following ? Colors.white.withValues(alpha: 0.07) : null,
          border: following ? Border.all(color: AppColors.hairline) : null,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
