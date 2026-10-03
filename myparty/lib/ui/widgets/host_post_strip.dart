import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../models/host_post.dart';

/// The host's photos of one party, as a row of thumbnails.
///
/// Renders NOTHING when the host has posted nothing — no placeholder, no
/// skeleton, no "no photos yet". Deliberate: most parties have no posts, and
/// an empty strip would take vertical space on every row in the list to say
/// so. The same goes for the loading and error states — a spinner that appears
/// under every row for a moment and then usually collapses to nothing is worse
/// than nothing appearing at all, and a failed fetch is indistinguishable to
/// the reader from a host who posted nothing.
///
/// Two round trips, not one: the rows first, then one batch signature for
/// whichever of them carry media. `post-media` is a private bucket whose paths
/// are storage keys rather than URLs, and signing is per-object — but
/// `createSignedUrlsResult` takes the whole list at once, so this is one
/// request regardless of how many photos come back.
class HostPostStrip extends StatefulWidget {
  const HostPostStrip({super.key, required this.partyId, required this.feed});

  final String partyId;
  final FeedRepository feed;

  @override
  State<HostPostStrip> createState() => _HostPostStripState();
}

class _HostPostStripState extends State<HostPostStrip> {
  late Future<List<_SignedPost>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant HostPostStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A list row can be recycled onto a different party as the user scrolls,
    // and the future would otherwise keep resolving against the old id.
    if (oldWidget.partyId != widget.partyId) {
      _future = _load();
    }
  }

  Future<List<_SignedPost>> _load() async {
    final posts = await widget.feed.fetchPartyPosts(widget.partyId);
    final withMedia = posts.where((p) => p.hasMedia).toList();
    if (withMedia.isEmpty) return const [];

    final urls = await widget.feed.signedPostMediaUrls(
      withMedia.map((p) => p.mediaPath!).toList(),
    );

    // A post whose signature failed is dropped rather than drawn as a broken
    // tile — the same policy PartyRepository applies to covers.
    return [
      for (final post in withMedia)
        if (urls[post.mediaPath!] != null)
          _SignedPost(post: post, url: urls[post.mediaPath!]!),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_SignedPost>>(
      future: _future,
      builder: (context, snapshot) {
        final posts = snapshot.data;
        // Covers "still loading", "failed", and "the host posted nothing" with
        // one branch, on purpose: all three should look identical, because to
        // the reader they are.
        if (posts == null || posts.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(top: 9),
          child: SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: posts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  posts[i].url,
                  width: 46,
                  height: 46,
                  fit: BoxFit.cover,
                  // A signed URL that 404s or expires between signing and
                  // painting collapses the tile rather than drawing Flutter's
                  // broken-image glyph.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  frameBuilder: (_, child, frame, wasSync) {
                    if (wasSync || frame != null) return child;
                    // No shimmer: the strip's whole contract is that it is
                    // either photos or nothing.
                    return Container(
                      width: 46,
                      height: 46,
                      color: Colors.white.withValues(alpha: 0.04),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SignedPost {
  const _SignedPost({required this.post, required this.url});
  final HostPost post;
  final String url;
}
