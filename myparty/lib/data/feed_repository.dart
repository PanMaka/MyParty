import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/feed_post.dart';
import '../models/host_post.dart';

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

  /// Client-generated post ids, for the same reason [StoryRepository] needs
  /// them: the upload handshake has to name the row it is filling before the
  /// server has told us anything about it, and RETURNING cannot answer because
  /// the row is hidden until the bytes land.
  static const _uuid = Uuid();

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

  /// A text-only post.
  ///
  /// Throws if the caller does not HOST the party — the `party_posts` INSERT
  /// policy rejects it (20260825095311), which is what makes "only the host
  /// posts" a server-side rule rather than a UI one.
  ///
  /// `mediaPath` is gone from the signature, and could not be honoured if it
  /// came back: the column carries no insert grant any more. Media goes
  /// through [createPostWithMedia], which is the only path that can produce a
  /// post whose bytes actually exist.
  Future<void> createPost({
    required String partyId,
    required String body,
  }) async {
    final id = _uid;
    if (id == null) throw StateError('Not signed in');

    await _client.from('party_posts').insert({
      'party_id': partyId,
      'author_id': id,
      'body': body,
    });
  }

  /// A post with a photo, as the four-step handshake stories use.
  ///
  /// insert → `post_upload_target` (via the edge function, which holds the
  /// service key) → PUT to the signed URL → `confirm_post_upload`. The post is
  /// INVISIBLE between step one and step four, to its author included, which
  /// is what makes abandoning it safe: a client that dies mid-flight leaves a
  /// row nobody can see rather than a broken frame on every phone in the
  /// party.
  ///
  /// The path is never chosen here. It is derived server-side from
  /// `{party_id}/{post_id}.{ext}` by a before-insert trigger and handed back by
  /// the RPC — a client that cannot name the path cannot aim an upload at
  /// another party's folder.
  ///
  /// Returns the new post's id.
  Future<String> createPostWithMedia({
    required String partyId,
    required Uint8List bytes,
    required String contentType,
    String? body,
  }) async {
    final userId = _uid;
    if (userId == null) throw StateError('Not signed in');

    final postId = _uuid.v4();

    // No `.select()` on the insert: RETURNING is a read (gotcha 6), and the
    // SELECT policy hides a media post until its bytes are confirmed, so
    // asking for the row back here returns nothing and looks like a failure.
    await _client.from('party_posts').insert({
      'id': postId,
      'party_id': partyId,
      'author_id': userId,
      'body': body,
      'media_type': contentType,
    });

    final signed = await _client.functions.invoke(
      'post-media/upload-url',
      body: {'post_id': postId},
    );

    final data = signed.data as Map?;
    final path = data?['path'] as String?;
    final token = data?['token'] as String?;
    if (path == null || token == null) {
      throw StateError('Could not get an upload URL for the post');
    }

    // uploadBinaryToSignedUrl, not uploadToSignedUrl: the latter takes a
    // dart:io File, which does not exist on web and would tie this repository
    // to a platform for no reason — the picker already hands us bytes.
    await _client.storage.from('post-media').uploadBinaryToSignedUrl(
          path,
          token,
          bytes,
          FileOptions(contentType: contentType),
        );

    await _client.rpc('confirm_post_upload', params: {'p_post_id': postId});

    return postId;
  }

  /// Signed read URLs for post media, keyed by the path that was asked for.
  ///
  /// Signed straight from the client, with no edge function in the way — and
  /// that is not a shortcut. The `post-media` bucket HAS a select policy
  /// ("Post media follows party visibility"), so RLS decides what signs and
  /// what does not, exactly as it does for `party-covers`. Only the UPLOAD
  /// side needs the service key, because the bucket has no insert policy for
  /// any role.
  ///
  /// One request for the whole list. Failures are dropped rather than thrown:
  /// a photo that will not sign is a tile the card omits, which is the same
  /// thing it does for a post that never had one.
  Future<Map<String, String>> signedPostMediaUrls(
    List<String> mediaPaths, {
    int expiresIn = 3600,
  }) async {
    if (mediaPaths.isEmpty) return {};

    final results = await _client.storage
        .from('post-media')
        .createSignedUrlsResult(mediaPaths, expiresIn);

    return {
      for (final result in results)
        if (result is SignedUrlSuccess) result.path: result.signedUrl,
    };
  }

  /// The host's own posts on one party, newest first.
  ///
  /// A plain select rather than an RPC: `party_posts` grants SELECT to
  /// `authenticated` and its policy already answers the visibility question,
  /// and `party_posts_party_created_idx` is a partial index on
  /// `(party_id, created_at desc, id desc) where hidden_at is null` — exactly
  /// this scan.
  ///
  /// There is deliberately NO `author_id = <host>` filter. Since
  /// 20260825095311 only the host can write a post at all, so the rule is
  /// already true of every row; restating it here would be a second place
  /// expressing one rule, and the two would drift the moment the policy
  /// changed.
  Future<List<HostPost>> fetchPartyPosts(String partyId, {int limit = 12}) async {
    final rows = await _client
        .from('party_posts')
        .select('id, party_id, author_id, body, media_path, like_count, '
            'comment_count, created_at')
        .eq('party_id', partyId)
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit);

    return (rows as List)
        .map((row) => HostPost.fromRow(row as Map<String, dynamic>))
        .toList();
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
