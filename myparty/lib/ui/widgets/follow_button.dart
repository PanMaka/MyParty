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
    return _FollowSkin(
      following: _following,
      compact: widget.compact,
      onTap: _loading ? null : _toggle,
    );
  }
}

/// The follow button as a visitor sees it, wired to nothing.
///
/// Exists for the owner's ΔΗΜΟΣΙΑ preview, where the honest thing to draw in
/// the action row is what a visitor actually gets — and the one thing it must
/// not do is act. A real [FollowButton] there would query `isFollowing` about
/// the viewer themself and, on a tap, attempt a self-follow the `follows`
/// INSERT policy refuses; the preview would report a failure that is really the
/// database being right.
///
/// It renders through the same [_FollowSkin] as the live button rather than
/// copying its decoration, which is the whole reason it lives in this file: a
/// preview that drifts from the thing it previews is worse than no preview.
/// That includes the label — it stays whatever the live button says, even while
/// the rest of the profile tab is English, because a preview claiming visitors
/// see "Follow" when they see "Ακολούθησε" is exactly the lie it exists to
/// prevent.
///
/// Always the not-following state: a visitor who already follows you is one of
/// several audiences, and the preview has to pick the one that is true of
/// somebody arriving at your profile for the first time.
class FollowButtonPreview extends StatelessWidget {
  const FollowButtonPreview({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => _FollowSkin(following: false, compact: compact);
}

/// Every pixel of both buttons, so neither can drift from the other.
///
/// A null [onTap] is how the live button already spends its first frames, while
/// `isFollowing` is in flight — so the inert preview is not a new visual state,
/// it is a state the button was always able to be in.
class _FollowSkin extends StatelessWidget {
  const _FollowSkin({required this.following, required this.compact, this.onTap});

  final bool following;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = following ? 'Ακολουθείς' : 'Ακολούθησε';

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
