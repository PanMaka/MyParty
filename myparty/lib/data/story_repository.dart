import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/story.dart';

/// Every widget-level Supabase call for stories goes through here — screens
/// never call `Supabase.instance.client` directly. Mirrors [ChatRepository],
/// [FeedRepository] and [PartyRepository].
///
/// Nothing here re-checks visibility. `get_story_rails` and
/// `get_party_stories` run with invoker rights, so the RLS policy on
/// `public.stories` is the only filter, and the signed-URL routes re-ask the
/// database with the caller's own token. A client-side filter would be a second
/// copy of that rule and would drift.
class StoryRepository {
  StoryRepository({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;
  static const _uuid = Uuid();

  /// Resolved lazily for the same reason [ChatRepository] does it: a test
  /// double subclasses this and overrides every method, and constructing a real
  /// client just to discard it needs an initialized Supabase, which does not
  /// exist under `flutter test`.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  /// The feed's story row.
  Future<List<StoryRail>> fetchRails() async {
    final rows = await _client.rpc('get_story_rails');
    return (rows as List)
        .map((row) => StoryRail.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// One party's reel, oldest first — the order a reel plays.
  ///
  /// [after] is the last story of the previous page; its `(created_at, id)` is
  /// the keyset cursor. Both halves travel together because a burst of uploads
  /// from one table shares a timestamp, and the id is then the only thing
  /// producing a total order. Never an offset (CLAUDE.md #5).
  Future<List<Story>> fetchPartyStories(
    String partyId, {
    Story? after,
    int limit = 30,
  }) async {
    final rows = await _client.rpc('get_party_stories', params: {
      'p_party_id': partyId,
      'p_after_created_at': after?.createdAt.toUtc().toIso8601String(),
      'p_after_id': after?.id,
      'p_limit': limit,
    });

    return (rows as List)
        .map((row) => Story.fromRow(row as Map<String, dynamic>))
        .toList();
  }

  /// Trades story ids for short-lived signed URLs, keyed by story id.
  ///
  /// Ids, never paths: the edge function re-selects them through this user's
  /// own JWT, so RLS decides what gets signed. Handing it a path would make it
  /// sign whatever it was told to, which is a readable URL for any object in
  /// the bucket. Ids the caller may not see are simply absent from the result —
  /// the viewer drops those frames rather than rendering a broken image.
  ///
  /// The URLs expire in 60 seconds, so they are fetched right before display
  /// and never cached across a screen's lifetime.
  Future<Map<String, String>> signedViewUrls(List<String> storyIds) async {
    if (storyIds.isEmpty) return {};

    final response = await _client.functions.invoke(
      'story-media/view-urls',
      body: {'story_ids': storyIds},
    );

    final urls = (response.data as Map)['urls'] as Map?;
    if (urls == null) return {};

    // The function returns project-relative paths on purpose — the absolute
    // URL it could build names the API gateway as the edge runtime sees it,
    // which locally is a docker hostname no phone can resolve. The origin this
    // client is already talking to is the right one to join them to.
    final origin = Uri.parse(_client.storage.url).origin;
    return {
      for (final entry in urls.entries)
        entry.key as String: '$origin${entry.value}',
    };
  }

  /// The four-step upload handshake. Returns the new story's id.
  ///
  ///   1. INSERT the row      — RLS checks you may post to this party, the
  ///                            trigger derives media_path, the rate limit is
  ///                            charged. Nothing is uploaded yet, and the row
  ///                            is invisible to everyone until step 4.
  ///   2. ask for a URL       — the edge function verifies authorship through
  ///                            `story_upload_target` and signs one path, once.
  ///   3. PUT the bytes       — to the signed URL. This is the only write the
  ///                            client ever makes to the bucket, and it is
  ///                            a token the server issued for one object.
  ///   4. confirm             — `confirm_story_upload` checks the object really
  ///                            landed before making the row visible.
  ///
  /// Ordered this way so the row always exists before the object does. Every
  /// object therefore has a row naming it, which is what lets the expiry job
  /// enumerate what to delete — an object with no row would be invisible to the
  /// cleanup and paid for forever. It also means a crash between steps leaves a
  /// row that never became visible, which the same job collects as `abandoned`.
  ///
  /// Throws if any step fails; `42501` covers both "you cannot post here" and
  /// "you are posting too fast", which is how they reach the UI.
  Future<String> createStory({
    required String partyId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    final userId = currentUserId;
    if (userId == null) throw StateError('Not signed in');

    final storyId = _uuid.v4();

    // No `.select()` on the insert: RETURNING is a read, and the SELECT policy
    // hides a story until its bytes are confirmed, so asking for the row back
    // here returns nothing and looks like a failed insert.
    await _client.from('stories').insert({
      'id': storyId,
      'party_id': partyId,
      'author_id': userId,
      'content_type': contentType,
    });

    final signed = await _client.functions.invoke(
      'story-media/upload-url',
      body: {'story_id': storyId},
    );

    final data = signed.data as Map?;
    final path = data?['path'] as String?;
    final token = data?['token'] as String?;
    if (path == null || token == null) {
      throw StateError('Could not get an upload URL for the story');
    }

    // uploadBinaryToSignedUrl, not uploadToSignedUrl: the latter takes a
    // dart:io File, which does not exist on web and would tie this repository
    // to a platform for no reason — the picker already hands us bytes.
    await _client.storage.from('story-media').uploadBinaryToSignedUrl(
          path,
          token,
          bytes,
          FileOptions(contentType: contentType),
        );

    await _client.rpc('confirm_story_upload', params: {'p_story_id': storyId});

    return storyId;
  }

  /// Records that this user watched a frame. Idempotent server-side via the
  /// composite primary key, so re-watching costs one ignored insert rather than
  /// needing any client-side bookkeeping.
  Future<void> markViewed(String storyId) async {
    final userId = currentUserId;
    if (userId == null) return;

    await _client.from('story_views').upsert(
      {'story_id': storyId, 'user_id': userId},
      onConflict: 'story_id,user_id',
      ignoreDuplicates: true,
    );
  }

  /// Soft delete, never a hard one (CLAUDE.md #7). An RPC rather than a PATCH
  /// because `stories` carries no update grant at all: on UPDATE Postgres
  /// applies the SELECT policy to the *new* row, and the new row is hidden, so
  /// a client-side soft-delete is structurally impossible. `hide_story`
  /// re-checks authorship/hosting server-side.
  ///
  /// Hiding does not delete the media — it makes the row eligible for the
  /// cleanup job, which is the one code path that removes bytes from the
  /// bucket.
  Future<void> hideStory(String storyId, {String? reason}) async {
    await _client.rpc('hide_story', params: {
      'p_story_id': storyId,
      'p_reason': reason,
    });
  }

  /// Parties this user can post a story to: the ones they host, plus the ones
  /// they have RSVP'd to.
  ///
  /// A convenience list, not an access rule — the INSERT policy on `stories`
  /// (`can_access_party`) is the authority, and it accepts strictly more than
  /// this returns. Offering the user a party they have no relationship with
  /// would be a worse list, not a safer one, so this is deliberately the
  /// narrower set.
  Future<List<StoryTarget>> fetchStoryTargets() async {
    final userId = currentUserId;
    if (userId == null) return [];

    final hosted = await _client
        .from('parties')
        .select('id, title, is_private, starts_at')
        .eq('host_id', userId)
        .eq('status', 'published')
        .order('starts_at', ascending: false)
        .limit(50);

    final attending = await _client
        .from('rsvps')
        .select('parties!inner(id, title, is_private, starts_at, status)')
        .eq('user_id', userId)
        .eq('parties.status', 'published')
        .order('created_at', ascending: false)
        .limit(50);

    final byId = <String, StoryTarget>{};

    void add(Map<String, dynamic> party) {
      final id = party['id'] as String;
      byId[id] ??= StoryTarget(
        partyId: id,
        title: party['title'] as String,
        isPrivate: (party['is_private'] as bool?) ?? false,
        startsAt: DateTime.parse(party['starts_at'] as String).toLocal(),
      );
    }

    for (final row in hosted as List) {
      add(row as Map<String, dynamic>);
    }
    for (final row in attending as List) {
      add((row as Map<String, dynamic>)['parties'] as Map<String, dynamic>);
    }

    final targets = byId.values.toList()
      ..sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return targets;
  }
}
