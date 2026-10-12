import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../screens/profile_screen.dart';

/// `complete_account_erasure`'s tombstone handle: `deleted_` and the uuid's
/// 32 hex digits. The one sign a client has that an account is gone — the row
/// itself stays visible to the `profiles` policy on purpose (CLAUDE.md, Phase 9).
final RegExp _erasedHandle = RegExp(r'^deleted_[0-9a-f]{32}$');

/// Whether [username] is an erased account's tombstone handle.
///
/// Nothing in the schema stops a live user from registering a handle of this
/// shape, so such a user is merely untappable here; nothing is hidden or
/// granted by it.
bool isErasedHandle(String? username) => username != null && _erasedHandle.hasMatch(username);

/// Builds the screen [openUserProfile] pushes. A seam for widget tests, which
/// have no Supabase client for the real repositories to reach; production
/// never reassigns it.
@visibleForTesting
Widget Function(ProfileTarget target) userProfileScreenBuilder = _defaultProfileScreen;

Widget _defaultProfileScreen(ProfileTarget target) => ProfileScreen(target: target);

/// Opens [userId]'s profile as a pushed route, over whatever is on screen.
///
/// Pushed rather than switching tabs, for the viewer's own id too: a pushed
/// route is the only thing whose back arrow returns to exactly where the tap
/// was — the chat at its scroll position, the bottom sheet still open over the
/// list. The Profile tab cannot do that, because getting to it means popping
/// everything above the tab shell.
///
/// Whether [userId] is the viewer is decided by [ProfileScreen] from the
/// session, not here: no caller has to know who is signed in, and no widget
/// passes an identity anywhere.
Future<void> openUserProfile(BuildContext context, String userId) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => userProfileScreenBuilder(OtherProfile(userId)),
  ));
}

/// Makes a user's avatar or name open their profile — the one tap handler for
/// a person anywhere in the app.
///
/// Renders [child] unchanged and adds two things the eye only notices on a
/// press: the hit area grows to at least [minTapSize] square without moving a
/// pixel of layout, and the child dims while held.
///
/// Inert, returning [child] as it is, when there is no one to open: a null id
/// (a pin with no host row) or an erased account's tombstone handle.
///
/// Answers taps only. A long press is left to whatever sits under it, which is
/// what keeps a chat bubble's hide action working when the name above it is a
/// link.
///
/// Blocks need nothing here: [ProfileScreen] already renders "not available"
/// for a profile hidden by either side's block, and the same for an id that
/// does not exist, so a tap cannot tell the viewer which it was.
class UserLink extends StatefulWidget {
  const UserLink({
    super.key,
    required this.userId,
    required this.username,
    required this.child,
    this.minTapSize = 44,
    this.hitSlop,
  });

  final String? userId;

  /// The handle as rendered, used only to recognise a tombstone.
  final String? username;

  final Widget child;

  /// The smallest hit area, per axis. Reached by hit-testing past the child's
  /// bounds rather than by padding it, so the design is untouched — which also
  /// means the extra reach stops at the edge of the enclosing widgets. Place
  /// the link where its parent has the room.
  final double minTapSize;

  /// Extra reach on chosen sides, added to what [minTapSize] already gives.
  /// For a link at the edge of its parent, where an even split would spend
  /// half the growth outside the parent's bounds and reach nothing: send it to
  /// the side that has room instead.
  final EdgeInsets? hitSlop;

  @override
  State<UserLink> createState() => _UserLinkState();
}

class _UserLinkState extends State<UserLink> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId;
    if (userId == null || userId.isEmpty || isErasedHandle(widget.username)) {
      return widget.child;
    }

    // Outermost on purpose: every render box hit-tests its own bounds first,
    // so anything wrapped around this would cut the reach back to the child's
    // size.
    return _MinTapArea(
      minSize: widget.minTapSize,
      slop: widget.hitSlop ?? EdgeInsets.zero,
      child: Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          onTap: () => openUserProfile(context, userId),
          child: AnimatedOpacity(
            opacity: _pressed ? 0.55 : 1,
            duration: const Duration(milliseconds: 90),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Accepts hits up to [minSize] square around its child and hands them on,
/// clamped onto the child, so the child's gesture detector sees them as its
/// own. Lays out and paints exactly as the child does.
class _MinTapArea extends SingleChildRenderObjectWidget {
  const _MinTapArea({required this.minSize, required this.slop, required super.child});

  final double minSize;
  final EdgeInsets slop;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMinTapArea(minSize, slop);

  @override
  void updateRenderObject(BuildContext context, _RenderMinTapArea renderObject) {
    renderObject
      ..minSize = minSize
      ..slop = slop;
  }
}

class _RenderMinTapArea extends RenderProxyBox {
  _RenderMinTapArea(this.minSize, this.slop);

  double minSize;
  EdgeInsets slop;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || size.isEmpty) return false;

    final dx = math.max(0.0, (minSize - size.width) / 2);
    final dy = math.max(0.0, (minSize - size.height) / 2);
    final area = Rect.fromLTRB(
      -dx - slop.left,
      -dy - slop.top,
      size.width + dx + slop.right,
      size.height + dy + slop.bottom,
    );
    if (!area.contains(position)) return false;

    // Size.contains excludes the far edge, so clamp just inside it.
    final onChild = Offset(
      position.dx.clamp(0.0, math.max(0.0, size.width - 0.01)),
      position.dy.clamp(0.0, math.max(0.0, size.height - 0.01)),
    );
    if (child.hitTest(result, position: onChild)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
