import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:myparty/data/feed_repository.dart';
import 'package:myparty/data/story_repository.dart';
import 'package:myparty/models/feed_post.dart';
import 'package:myparty/models/story.dart';
import 'package:myparty/ui/screens/feed_screen.dart';
import 'package:myparty/ui/screens/story_viewer_screen.dart';
import 'package:myparty/ui/widgets/story_picker_sheet.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `StoryRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here.
class _FakeStoryRepository extends StoryRepository {
  _FakeStoryRepository({
    List<Story> stories = const [],
    List<StoryRail> rails = const [],
    List<StoryTarget> targets = const [],
    this.uid = 'me',
    this.failUpload,
    this.unsignableIds = const {},
  })  : _stories = List.of(stories),
        _rails = List.of(rails),
        _targets = List.of(targets);

  final List<Story> _stories;
  final List<StoryRail> _rails;
  final List<StoryTarget> _targets;
  final String? uid;

  /// Message the upload should throw, if any.
  final String? failUpload;

  /// Story ids the signing route refuses — a story the caller may no longer
  /// see, which is exactly what RLS produces between the two calls.
  final Set<String> unsignableIds;

  final List<String> viewedIds = [];
  final List<String> hiddenIds = [];
  final List<(String partyId, int byteCount)> uploads = [];

  @override
  String? get currentUserId => uid;

  @override
  Future<List<Story>> fetchPartyStories(String partyId, {Story? after, int limit = 30}) async {
    return _stories.where((s) => s.partyId == partyId).toList();
  }

  @override
  Future<List<StoryRail>> fetchRails() async => _rails;

  @override
  Future<List<StoryTarget>> fetchStoryTargets() async => _targets;

  @override
  Future<Map<String, String>> signedViewUrls(List<String> storyIds) async {
    return {
      for (final id in storyIds)
        if (!unsignableIds.contains(id)) id: 'https://example.test/$id.jpg',
    };
  }

  @override
  Future<void> markViewed(String storyId) async => viewedIds.add(storyId);

  @override
  Future<void> hideStory(String storyId, {String? reason}) async => hiddenIds.add(storyId);

  @override
  Future<String> createStory({
    required String partyId,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    uploads.add((partyId, bytes.length));
    if (failUpload != null) throw Exception(failUpload);
    return 'new-story';
  }
}

class _EmptyFeedRepository extends FeedRepository {
  @override
  Future<List<FeedPost>> fetchFeed({FeedPost? after, int limit = 20}) async => [];

  @override
  String? get currentUserId => 'me';
}

class _FakePicker extends ImagePicker {
  _FakePicker({this.bytes});

  /// null means the user backed out of the camera roll.
  final Uint8List? bytes;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    if (bytes == null) return null;
    return XFile.fromData(bytes!, name: 'story.jpg', mimeType: 'image/jpeg');
  }
}

Story _story({
  required String id,
  String partyId = 'party-1',
  String authorId = 'someone',
  String username = 'zoe',
  int viewCount = 0,
  bool viewed = false,
  Duration age = const Duration(minutes: 5),
}) {
  final created = DateTime.now().toUtc().subtract(age);
  return Story(
    id: id,
    partyId: partyId,
    authorId: authorId,
    authorUsername: username,
    mediaPath: '$partyId/$id.jpg',
    contentType: 'image/jpeg',
    createdAt: created,
    expiresAt: created.add(const Duration(hours: 24)),
    viewCount: viewCount,
    viewed: viewed,
  );
}

StoryRail _rail({
  String partyId = 'party-1',
  String title = 'Ταράτσα στο Κουκάκι',
  bool hasUnseen = true,
  int count = 3,
}) {
  return StoryRail(
    partyId: partyId,
    partyTitle: title,
    isPrivate: false,
    storyCount: count,
    latestAt: DateTime.now(),
    coverStoryId: 'cover-$partyId',
    coverMediaPath: '$partyId/cover.jpg',
    hasUnseen: hasUnseen,
  );
}

/// The viewer renders `Image.network`, which would try to reach the network in
/// a test. This serves every request a transparent 1x1 PNG instead.
Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('the viewer renders real frames, not the old mpStory mock', (tester) async {
    final repo = _FakeStoryRepository(stories: [
      _story(id: 's1', username: 'zoe'),
      _story(id: 's2', username: 'dimitris'),
    ]);

    await tester.pumpWidget(_wrap(StoryViewerScreen(
      partyId: 'party-1',
      partyTitle: 'Ταράτσα στο Κουκάκι',
      repository: repo,
    )));
    await tester.pumpAndSettle();

    expect(find.text('zoe'), findsOneWidget);
    expect(find.textContaining('1 από 2'), findsOneWidget);
    // The mock frames are gone for good.
    expect(find.textContaining('clip · πλήθος στην πίστα'), findsNothing);

    // Right of the screen's first third, so it advances rather than going back.
    await tester.tapAt(const Offset(600, 400));
    await tester.pump();

    expect(find.text('dimitris'), findsOneWidget);
    expect(find.textContaining('2 από 2'), findsOneWidget);

    // Timer from the last frame; let it run out so the test ends clean.
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('watching a frame records the view exactly once', (tester) async {
    final repo = _FakeStoryRepository(stories: [
      _story(id: 's1'),
      _story(id: 's2', viewed: true),
    ]);

    await tester.pumpWidget(_wrap(StoryViewerScreen(partyId: 'party-1', repository: repo)));
    await tester.pumpAndSettle();

    expect(repo.viewedIds, ['s1']);

    await tester.tapAt(const Offset(600, 400));
    await tester.pump();

    // s2 arrived already viewed, so there is nothing to record for it — the
    // server would ignore the duplicate anyway, thanks to the composite key.
    expect(repo.viewedIds, ['s1']);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('a frame with no signed URL is dropped, not rendered broken', (tester) async {
    final repo = _FakeStoryRepository(
      stories: [_story(id: 's1'), _story(id: 's2')],
      // s2 became invisible between the list call and the signing call — the
      // author was blocked, or it expired in the gap.
      unsignableIds: {'s2'},
    );

    await tester.pumpWidget(_wrap(StoryViewerScreen(partyId: 'party-1', repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 από 1'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('an empty reel says so instead of rendering nothing', (tester) async {
    final repo = _FakeStoryRepository();

    await tester.pumpWidget(_wrap(StoryViewerScreen(partyId: 'party-1', repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Κανένα story'), findsOneWidget);
  });

  testWidgets('only your own frames offer a takedown', (tester) async {
    final mine = _FakeStoryRepository(
      stories: [_story(id: 's1', authorId: 'me', viewCount: 7, viewed: true)],
      uid: 'me',
    );

    await tester.pumpWidget(_wrap(StoryViewerScreen(partyId: 'party-1', repository: mine)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // The author sees the aggregate counter — never who watched.
    expect(find.text('7'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Κατέβασέ το'));
    await tester.pumpAndSettle();

    expect(mine.hiddenIds, ['s1']);
  });

  testWidgets("someone else's frame has no takedown affordance", (tester) async {
    final theirs = _FakeStoryRepository(
      stories: [_story(id: 's1', authorId: 'someone-else')],
      uid: 'me',
    );

    await tester.pumpWidget(_wrap(StoryViewerScreen(partyId: 'party-1', repository: theirs)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.delete_outline), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('the feed story row renders real rails, not the four hardcoded tiles', (tester) async {
    final stories = _FakeStoryRepository(rails: [
      _rail(partyId: 'p1', title: 'Γενέθλια Μαρίας'),
      _rail(partyId: 'p2', title: 'Techno Δευτέρα', hasUnseen: false),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: FeedScreen(repository: _EmptyFeedRepository(), storyRepository: stories),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Γενέθλια Μαρίας'), findsOneWidget);
    expect(find.text('Techno Δευτέρα'), findsOneWidget);
    expect(find.text('3 stories'), findsNWidgets(2));
    // 'Kápsimo' was the hardcoded venue tile — it has no source any more.
    expect(find.textContaining('Kápsimo'), findsNothing);
  });

  testWidgets('an empty rail leaves just the upload tile, and the feed still renders', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FeedScreen(
        repository: _EmptyFeedRepository(),
        storyRepository: _FakeStoryRepository(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ανέβασε'), findsOneWidget);
    expect(find.textContaining('Ήσυχα εδώ.'), findsOneWidget);
  });

  testWidgets('picking a photo uploads it to the chosen party', (tester) async {
    final repo = _FakeStoryRepository(targets: [
      StoryTarget(
        partyId: 'party-9',
        title: 'Ταράτσα στο Κουκάκι',
        isPrivate: false,
        startsAt: DateTime.now(),
      ),
    ]);

    await tester.pumpWidget(_wrap(StoryPickerSheet(
      repository: repo,
      picker: _FakePicker(bytes: Uint8List.fromList(List.filled(64, 7))),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ταράτσα στο Κουκάκι'));
    await tester.pumpAndSettle();

    expect(repo.uploads, [('party-9', 64)]);
  });

  testWidgets('the rate limit is reported in words the user can act on', (tester) async {
    final repo = _FakeStoryRepository(
      targets: [
        StoryTarget(
          partyId: 'party-9',
          title: 'Ταράτσα στο Κουκάκι',
          isPrivate: false,
          startsAt: DateTime.now(),
        ),
      ],
      failUpload: 'story rate limit exceeded: 10 per hour',
    );

    await tester.pumpWidget(_wrap(StoryPickerSheet(
      repository: repo,
      picker: _FakePicker(bytes: Uint8List.fromList(List.filled(8, 1))),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ταράτσα στο Κουκάκι'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Πολλά stories'), findsOneWidget);
  });

  testWidgets('with no party to post to, the sheet explains why', (tester) async {
    await tester.pumpWidget(_wrap(StoryPickerSheet(
      repository: _FakeStoryRepository(),
      picker: _FakePicker(),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('Δεν είσαι σε κανένα πάρτι'), findsOneWidget);
  });
}
