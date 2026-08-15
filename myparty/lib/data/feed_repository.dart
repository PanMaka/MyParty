import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/feed_post.dart';

/// Raised when a report is filed twice against the same target by the same
/// user. `reports_one_per_target_idx` enforces that server-side, so this is
/// the client naming the resulting unique violation rather than trying to
/// pre-empt it with a lookup that would race anyway.
class AlreadyReportedException implements Exception {
  const AlreadyReportedException();
}

/// Every widget-level Supabase call for posts, likes, comments and reports
/// goes through here — screens never call `Supabase.instance.client`
/// directly. Mirrors [PartyRepository] and [SocialRepository].
///
/// Nothing here re-checks visibility. `party_posts` defers to
/// `can_access_party`, and `post_likes`/`post_comments` defer to
/// `party_posts`, so a party the user cannot access simply has no rows to
/// return. A client-side filter would be a second copy of that rule and
/// would drift from it.
class FeedRepository {
  FeedRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved lazily for the same reason [SocialRepository] does it: a test
  /// double subclasses this and overrides every method, and constructing a
  /// real client just to discard it starts a realtime heartbeat that
  /// `pumpAndSettle` then blocks on.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get _uid => _client.auth.currentUser?.id;

  /// Who is signed in. Exposed because the cards need it to decide whether a
  /// post is the viewer's own (delete vs report), and reaching into
  /// `Supabase.instance` from a widget would break the rule this class
  /// exists to enforce — and make the widget untestable, since there is no
  /// initialized client under `flutter test`.
  String? get currentUserId => _uid;

  /// One page of the feed, newest first.
  ///
  /// [after] is the last post of the previous page — its `(created_at, id)`
  /// is the keyset cursor. Both halves travel together because posts made in
  /// the same transaction share a timestamp, and the id is then the only
  /// thing producing a total order. Never an offset (CLAUDE.md #5).
  Future<List<FeedPost>> fetchFeed({FeedPost? after, int limit = 20}) async {
    final rows = await _client.rpc('get_feed', params: {
      'p_before_created_at': after?.createdAt.toUtc().toIso8601String(),
      'p_before_id': after?.postId,
      'p_limit': limit,
    });

    return (rows as List)
        .map((row) => FeedPost.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<PostComment>> fetchComments(
    String postId, {
    PostComment? after,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_post_comments', params: {
      'p_post_id': postId,
      'p_before_created_at': after?.createdAt.toUtc().toIso8601String(),
      'p_before_id': after?.id,
      'p_limit': limit,
    });

    return (rows as List)
        .map((row) => PostComment(
              id: row['id'] as String,
              postId: row['post_id'] as String,
              authorId: row['author_id'] as String,
              authorUsername: row['author_username'] as String,
              body: row['body'] as String,
              createdAt: DateTime.parse(row['created_at'] as String),
            ))
        .toList();
  }

  /// Throws if the party is not accessible — the `party_posts` INSERT policy
  /// rejects it, which is what makes "you cannot post to a party you cannot
  /// see" a server-side rule rather than a UI one.
  Future<void> createPost({
    required String partyId,
    String? body,
    String? mediaPath,
  }) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('party_posts').insert({
      'party_id': partyId,
      'author_id': id,
      'body': body,
      'media_path': mediaPath,
    });
  }

  Future<void> like(String postId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('post_likes').insert({
      'post_id': postId,
      'user_id': id,
    });
  }

  Future<void> unlike(String postId) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client
        .from('post_likes')
        .delete()
        .eq('post_id', postId)
        .eq('user_id', id);
  }

  Future<void> comment(String postId, String body) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('post_comments').insert({
      'post_id': postId,
      'author_id': id,
      'body': body,
    });
  }

  /// Soft delete, never a hard one (CLAUDE.md #7). An RPC rather than a
  /// PATCH because these tables carry no update grant at all: on UPDATE
  /// Postgres applies the SELECT policy to the *new* row, and the new row is
  /// hidden, so a client-side soft-delete is structurally impossible.
  /// `hide_post` re-checks authorship/hosting server-side.
  Future<void> hidePost(String postId, {String? reason}) async {
    await _client.rpc('hide_post', params: {
      'p_post_id': postId,
      'p_reason': reason,
    });
  }

  Future<void> hideComment(String commentId, {String? reason}) async {
    await _client.rpc('hide_comment', params: {
      'p_comment_id': commentId,
      'p_reason': reason,
    });
  }

  /// Files a report. `status` and `created_at` are deliberately absent: they
  /// are not in the column-level insert grant, so triage stays server-side.
  Future<void> report({
    required ReportTarget target,
    required String targetId,
    required String reason,
  }) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    try {
      await _client.from('reports').insert({
        'reporter_id': id,
        'target_type': target.wireName,
        'target_id': targetId,
        'reason': reason,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') throw const AlreadyReportedException();
      rethrow;
    }
  }
}
