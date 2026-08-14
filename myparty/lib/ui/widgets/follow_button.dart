import 'package:flutter/material.dart';

import '../../data/social_repository.dart';
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
  });

  final String targetUserId;

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

  @override
  void initState() {
    super.initState();
    _load();
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

    try {
      if (wasFollowing) {
        await _repository.unfollow(widget.targetUserId);
      } else {
        await _repository.follow(widget.targetUserId);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _following = wasFollowing);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Δεν έγινε. Δοκίμασε ξανά.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _following ? 'Ακολουθείς' : 'Ακολούθησε';

    if (widget.compact) {
      return OutlinedButton(
        onPressed: _loading ? null : _toggle,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          backgroundColor: _following ? Colors.white.withValues(alpha: 0.08) : null,
          side: _following ? BorderSide.none : const BorderSide(color: AppColors.purple),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
          foregroundColor: _following ? AppColors.textAlpha(0.6) : AppColors.purpleLight,
        ),
        child: Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
      );
    }

    return GestureDetector(
      onTap: _loading ? null : _toggle,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: _following ? null : AppColors.purpleGradient,
          color: _following ? Colors.white.withValues(alpha: 0.07) : null,
          border: _following ? Border.all(color: AppColors.hairline) : null,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
