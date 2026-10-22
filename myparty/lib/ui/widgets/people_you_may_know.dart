import 'package:flutter/material.dart';

import '../../data/social_repository.dart';
import '../../models/follow_suggestion.dart';
import '../../state/data_changes.dart';
import '../../state/live_refresh.dart';
import '../screens/follow_suggestions_screen.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'follow_button.dart';
import 'mp_bottom_nav.dart' show MpTab;
import 'user_link.dart';

/// "People you may know" on the owner's profile: one row of cards and a door
/// to the full list.
///
/// Renders nothing at all while loading, on a failed fetch and when the server
/// has no one to suggest. A heading over an empty row, a spinner or an error
/// would each spend the most visible slot on the profile saying nothing.
///
/// Following from a card leaves the card in place, now reading "Following":
/// the [FollowButton] hears its own [FollowChanged]. The list itself does not
/// refetch on a follow, or the card would vanish under the thumb that tapped
/// it; it drops out on the next ordinary refresh (tab focus or resume after
/// [liveStaleAfter], or pull to refresh).
class PeopleYouMayKnow extends StatefulWidget {
  const PeopleYouMayKnow({
    super.key,
    required this.social,
    required this.avatarUrl,
    required this.liveTab,
    this.refreshGeneration = 0,
  });

  final SocialRepository social;

  /// [ProfileRepository.avatarUrl], passed down rather than rebuilt here so
  /// the bucket stays the only authority on how an avatar is reached.
  final String? Function(String? path) avatarUrl;

  /// The tab the profile is on, for [LiveRefresh]; null when pushed.
  final MpTab? liveTab;

  /// Bumped by the profile's pull to refresh, so one gesture refreshes the
  /// whole screen, this row included.
  final int refreshGeneration;

  @override
  State<PeopleYouMayKnow> createState() => _PeopleYouMayKnowState();
}

class _PeopleYouMayKnowState extends State<PeopleYouMayKnow> with LiveRefresh<PeopleYouMayKnow> {
  List<FollowSuggestion>? _items;

  /// Followed from this list (or anywhere) since it was built. A lazily built
  /// list recreates a card scrolled back into view, and its [FollowButton]
  /// would otherwise start from "Follow" again; this is what it starts from.
  final Set<String> _followed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PeopleYouMayKnow old) {
    super.didUpdateWidget(old);
    if (old.refreshGeneration != widget.refreshGeneration) _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.social.fetchFollowSuggestions();
      if (mounted) setState(() => _items = items);
    } catch (_) {
      // Keeps whatever was there. A first load that fails leaves the section
      // hidden, which is the right failure for a suggestion.
    }
  }

  @override
  MpTab? get liveTab => widget.liveTab;

  @override
  Future<void> liveRefresh() => _load();

  @override
  void onDataChange(DataChange change) {
    switch (change) {
      // Dismissed on See all: the same card leaves this row at once.
      case FollowChanged(:final targetUserId, :final following):
        setState(() => following ? _followed.add(targetUserId) : _followed.remove(targetUserId));
      case SuggestionDismissed(:final userId, dismissed: true):
        _remove(userId);
      // An Undo, made here or on See all: the server's list is the truth.
      case SuggestionDismissed(dismissed: false):
        refreshWhenVisible();
      // A blocked account is never suggested, and an unblocked one may be.
      case BlockChanged(:final userId, :final blocked):
        if (blocked) _remove(userId);
        refreshWhenVisible();
      default:
        break;
    }
  }

  int _remove(String userId) {
    final items = _items;
    if (items == null) return -1;
    final index = items.indexWhere((s) => s.userId == userId);
    if (index >= 0) setState(() => _items = [...items]..removeAt(index));
    return index;
  }

  void _restore(FollowSuggestion s, int index) {
    if (!mounted) return;
    final items = _items ?? const <FollowSuggestion>[];
    if (items.any((x) => x.userId == s.userId)) return;
    setState(() => _items = [...items]..insert(index.clamp(0, items.length), s));
  }

  void _dismiss(FollowSuggestion s) {
    var index = -1;
    dismissSuggestionWithUndo(
      context: context,
      social: widget.social,
      suggestion: s,
      remove: () => index = _remove(s.userId),
      restore: () => _restore(s, index),
    );
  }

  void _openAll() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FollowSuggestionsScreen(social: widget.social, avatarUrl: widget.avatarUrl),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'PEOPLE YOU MAY KNOW',
                    style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45)),
                  ),
                ),
                TextButton(onPressed: _openAll, child: const Text('See all')),
              ],
            ),
          ),
          SizedBox(
            height: 196,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 9),
              itemBuilder: (_, i) => SuggestionCard(
                key: ValueKey(items[i].userId),
                suggestion: items[i],
                social: widget.social,
                avatarUrl: widget.avatarUrl,
                onDismiss: () => _dismiss(items[i]),
                following: _followed.contains(items[i].userId),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Removes a suggestion at once, stores the dismissal, and offers Undo.
///
/// [remove] and [restore] are the calling list's: the card leaves before the
/// server answers ("disappear immediately"), comes back where it was if the
/// write is refused, and comes back the same way on Undo. Both callers must
/// make [restore] safe after dispose: Undo can be pressed after See all has
/// been popped, and then the server's [SuggestionDismissed] is what brings the
/// card back on the profile row.
Future<void> dismissSuggestionWithUndo({
  required BuildContext context,
  required SocialRepository social,
  required FollowSuggestion suggestion,
  required VoidCallback remove,
  required VoidCallback restore,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void snack(String text, {SnackBarAction? action}) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, action: action));
  }

  remove();
  try {
    await social.dismissSuggestion(suggestion.userId);
  } catch (_) {
    restore();
    snack('Couldn’t remove this suggestion. Try again.');
    return;
  }

  snack(
    '${suggestion.username} won’t be suggested again',
    action: SnackBarAction(
      label: 'Undo',
      onPressed: () async {
        restore();
        try {
          await social.undismissSuggestion(suggestion.userId);
        } catch (_) {
          remove();
          snack('Couldn’t undo. Try again.');
        }
      },
    ),
  );
}

/// A circular avatar with the uuid-keyed gradient behind it, which is also
/// what shows when there is no photo or it fails to load.
class SuggestionAvatar extends StatelessWidget {
  const SuggestionAvatar({super.key, required this.suggestion, required this.url, this.size = 56});

  final FollowSuggestion suggestion;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = DiagonalStripePlaceholder(colors: suggestion.placeholderColors);
    final url = this.url;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? placeholder
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
              ),
      ),
    );
  }
}

/// One card in the row: avatar, username, reason, Follow and ✕. Tapping the
/// person opens their profile; the two buttons take their own taps.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.suggestion,
    required this.social,
    required this.avatarUrl,
    required this.onDismiss,
    this.following = false,
  });

  final FollowSuggestion suggestion;

  /// Whether the viewer already followed them from somewhere in this session.
  final bool following;
  final SocialRepository social;
  final String? Function(String? path) avatarUrl;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    return Container(
      width: 148,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 12),
            child: Column(
              children: [
                Expanded(
                  child: UserLink(
                    userId: s.userId,
                    username: s.username,
                    child: Column(
                      children: [
                        SuggestionAvatar(suggestion: s, url: avatarUrl(s.avatarPath)),
                        const SizedBox(height: 8),
                        Text(
                          s.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          suggestionReasonText(s, short: true),
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, height: 1.3, color: AppColors.textAlpha(0.5)),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FollowButton(
                    targetUserId: s.userId,
                    compact: true,
                    repository: social,
                    initialFollowing: following,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 16, color: AppColors.textAlpha(0.45)),
            ),
          ),
        ],
      ),
    );
  }
}
