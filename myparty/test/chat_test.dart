import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import 'package:myparty/data/chat_repository.dart';
import 'package:myparty/models/party_message.dart';
import 'package:myparty/ui/screens/chat_screen.dart';
import 'package:myparty/ui/screens/messages_screen.dart';

/// Stands in for the real repository. Subclasses rather than implements so it
/// stays in sync with the real constructor, and overrides every method that
/// touches the network — `ChatRepository` resolves its client lazily, so no
/// Supabase client is ever constructed here. `currentUserId` is overridden for
/// the same reason it exists on the real class: there is no initialized client
/// under `flutter test`.
class _FakeChatRepository extends ChatRepository {
  _FakeChatRepository({
    List<PartyMessage> history = const [],
    List<PartyChatSummary> chats = const [],
    this.uid = 'me',
    this.failSends = false,
  })  : _history = List.of(history),
        _chats = List.of(chats);

  final List<PartyMessage> _history;
  final List<PartyChatSummary> _chats;
  final String? uid;
  final bool failSends;

  /// Every cursor `fetchMessages` was called with, so a test can prove the
  /// screen pages by keyset row and never by offset.
  final List<PartyMessage?> cursors = [];
  final List<DateTime> gapFillsSince = [];
  int markReadCalls = 0;
  int subscribeCalls = 0;

  /// Lets a test hold a send open and assert on what is rendered mid-flight.
  Completer<void>? sendGate;

  final messageEvents = StreamController<PartyMessage>.broadcast();
  final hiddenEvents = StreamController<String>.broadcast();
  final statusEvents = StreamController<RealtimeSubscribeStatus>.broadcast();

  @override
  String? get currentUserId => uid;

  @override
  Future<List<PartyMessage>> fetchMessages(
    String partyId, {
    PartyMessage? before,
    int limit = 30,
  }) async {
    cursors.add(before);
    if (before == null) {
      return _history.reversed.take(limit).toList();
    }
    // Newest-first, strictly older than the cursor — the same total order the
    // server's (created_at desc, id desc) keyset produces.
    return _history.reversed
        .where((m) => m.compareTo(before) < 0)
        .take(limit)
        .toList();
  }

  @override
  Future<List<PartyMessage>> fetchMessagesSince(
    String partyId,
    DateTime since, {
    int maxPages = 5,
    int pageSize = 50,
  }) async {
    gapFillsSince.add(since);
    return _history.where((m) => m.createdAt.isAfter(since)).toList();
  }

  @override
  Future<PartyMessage> sendMessage({
    required String partyId,
    required String body,
  }) async {
    if (sendGate != null) await sendGate!.future;
    if (failSends) throw Exception('42501');
    return PartyMessage(
      id: 'stored-$body',
      partyId: partyId,
      authorId: uid!,
      authorUsername: '',
      body: body,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> markRead(String partyId) async => markReadCalls += 1;

  @override
  Future<List<PartyChatSummary>> fetchPartyChats() async => _chats;

  @override
  Future<void> hideMessage(String messageId, {String? reason}) async {}

  @override
  PartyChatChannel subscribe(String partyId) {
    subscribeCalls += 1;
    return PartyChatChannel(
      messages: messageEvents.stream,
      hiddenMessageIds: hiddenEvents.stream,
      status: statusEvents.stream,
      dispose: () async {},
    );
  }
}

final _epoch = DateTime.utc(2026, 8, 15, 20);

PartyMessage _msg({
  required String id,
  String body = 'γεια',
  String authorId = 'them',
  String authorUsername = 'zoi',
  int minute = 0,
}) {
  return PartyMessage(
    id: id,
    partyId: 'party1',
    authorId: authorId,
    authorUsername: authorUsername,
    body: body,
    createdAt: _epoch.add(Duration(minutes: minute)),
  );
}

Widget _chat(_FakeChatRepository repo) => MaterialApp(
      home: ChatScreen(
        partyId: 'party1',
        partyTitle: 'Ταράτσα στο Κουκάκι',
        isPrivate: true,
        repository: repo,
      ),
    );

void main() {
  testWidgets('the chat renders real history, not the old mock seed', (tester) async {
    final repo = _FakeChatRepository(history: [
      _msg(id: 'm1', body: 'πρώτο', minute: 1),
      _msg(id: 'm2', body: 'δεύτερο', minute: 2),
    ]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    expect(find.text('πρώτο'), findsOneWidget);
    expect(find.text('δεύτερο'), findsOneWidget);
    // The const mpSeedTaratsaChat list is gone for good.
    expect(find.textContaining('Ο κώδικας της πόρτας είναι 4471'), findsNothing);
  });

  testWidgets('an empty chat explains itself instead of rendering nothing', (tester) async {
    final repo = _FakeChatRepository();

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining('Κανείς δεν έχει γράψει ακόμα'), findsOneWidget);
  });

  testWidgets('opening the chat marks it read', (tester) async {
    final repo = _FakeChatRepository(history: [_msg(id: 'm1')]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    expect(repo.markReadCalls, greaterThan(0));
  });

  testWidgets('a sent message renders before the insert round-trips', (tester) async {
    final repo = _FakeChatRepository()..sendGate = Completer<void>();

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'φέρνω παγάκια');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Still in flight — but already on screen. This is the whole point of the
    // optimistic path.
    expect(find.text('φέρνω παγάκια'), findsOneWidget);

    repo.sendGate!.complete();
    await tester.pumpAndSettle();

    // And exactly once after the stored row replaces the pending one.
    expect(find.text('φέρνω παγάκια'), findsOneWidget);
  });

  testWidgets('a rejected send keeps the bubble and admits it failed', (tester) async {
    // The insert is refused for real reasons the user can act on — the rate
    // limit, or having been removed from the party. A message that silently
    // vanishes after you hit send is worse than one that says it did not go.
    final repo = _FakeChatRepository(failSends: true);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'δεν θα φύγει');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('δεν θα φύγει'), findsOneWidget);
    expect(find.text('Δεν στάλθηκε. Δοκίμασε ξανά.'), findsOneWidget);
  });

  testWidgets('the broadcast echo of our own message does not duplicate it', (tester) async {
    // messages grants INSERT on `id` so the client can generate it, which is
    // what makes the echo recognisable. If this regresses, every message a
    // user sends appears twice on their own screen.
    final repo = _FakeChatRepository();

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'μια φορά');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('μια φορά'), findsOneWidget);

    // The trigger broadcasts the row we just inserted, back to us as well.
    repo.messageEvents.add(PartyMessage(
      id: 'stored-μια φορά',
      partyId: 'party1',
      authorId: 'me',
      authorUsername: 'me',
      body: 'μια φορά',
      createdAt: DateTime.now().toUtc(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('μια φορά'), findsOneWidget);
  });

  testWidgets('a live message from someone else appears', (tester) async {
    final repo = _FakeChatRepository(history: [_msg(id: 'm1', body: 'πρώτο')]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    repo.messageEvents.add(_msg(id: 'm2', body: 'ζωντανό', minute: 5));
    await tester.pumpAndSettle();

    expect(find.text('ζωντανό'), findsOneWidget);
  });

  testWidgets('a message_hidden broadcast retracts the message live', (tester) async {
    // Hidden means hidden everywhere. Without the retraction event, a host
    // takes a message down and every phone already in the chat keeps showing
    // it until the screen is reopened.
    final repo = _FakeChatRepository(history: [
      _msg(id: 'm1', body: 'κάτι κακό', minute: 1),
      _msg(id: 'm2', body: 'κάτι αθώο', minute: 2),
    ]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    expect(find.text('κάτι κακό'), findsOneWidget);

    repo.hiddenEvents.add('m1');
    await tester.pumpAndSettle();

    expect(find.text('κάτι κακό'), findsNothing);
    expect(find.text('κάτι αθώο'), findsOneWidget);
  });

  testWidgets('reconnecting fetches the gap instead of assuming it resumed', (tester) async {
    // Broadcast has no replay, so anything sent while the socket was down
    // never arrives on its own. The FIRST subscribe must not gap-fill —
    // history was just loaded — and every one after it must.
    final repo = _FakeChatRepository(history: [_msg(id: 'm1', minute: 1)]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    repo.statusEvents.add(RealtimeSubscribeStatus.subscribed);
    await tester.pumpAndSettle();
    expect(repo.gapFillsSince, isEmpty, reason: 'the initial subscribe has no gap to fill');

    repo.statusEvents.add(RealtimeSubscribeStatus.closed);
    repo.statusEvents.add(RealtimeSubscribeStatus.subscribed);
    await tester.pumpAndSettle();

    expect(repo.gapFillsSince.length, 1);
    // Measured from the newest message held, which is what bounds the refetch.
    expect(repo.gapFillsSince.single, _epoch.add(const Duration(minutes: 1)));
  });

  testWidgets('older messages are paged by keyset cursor, never an offset', (tester) async {
    // A full page makes the screen believe there is more, so scrolling up
    // pages — passing the OLDEST row it holds as the cursor.
    final repo = _FakeChatRepository(history: [
      for (var i = 0; i < 30; i++) _msg(id: 'm$i', body: 'μήνυμα $i', minute: i),
    ]);

    await tester.pumpWidget(_chat(repo));
    await tester.pumpAndSettle();

    expect(repo.cursors, [null]);

    await tester.fling(find.byKey(const ValueKey('chat-list')), const Offset(0, 6000), 4000);
    await tester.pumpAndSettle();

    expect(repo.cursors.length, greaterThan(1));
    expect(repo.cursors[1]?.id, 'm0', reason: 'the cursor is the oldest row held, not a row count');
  });

  testWidgets('the chat list renders real parties with unread badges', (tester) async {
    final repo = _FakeChatRepository(chats: [
      PartyChatSummary(
        partyId: 'party1',
        partyTitle: 'Ταράτσα στο Κουκάκι',
        isPrivate: true,
        startsAt: DateTime.now(),
        goingCount: 12,
        lastMessageBody: 'παίρνω ταξί',
        lastMessageAuthorUsername: 'zoi',
        lastMessageAt: DateTime.now(),
        unreadCount: 7,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: MessagesScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('Ταράτσα στο Κουκάκι'), findsOneWidget);
    expect(find.text('zoi: παίρνω ταξί'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    // The two hardcoded mock rows are gone.
    expect(find.text('Techno Δευτέρα'), findsNothing);
  });

  testWidgets('the unread badge caps at 99+ the way the server caps the count', (tester) async {
    // get_party_chats counts against a `limit 100` subquery so the query stays
    // index-bounded; rendering a bare "100" would be a number the server never
    // promised was exact.
    final repo = _FakeChatRepository(chats: [
      PartyChatSummary(
        partyId: 'party1',
        partyTitle: 'Πολυσύχναστο',
        isPrivate: false,
        startsAt: DateTime.now(),
        goingCount: 200,
        lastMessageBody: 'ναι',
        lastMessageAuthorUsername: 'someone',
        lastMessageAt: DateTime.now(),
        unreadCount: 100,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: MessagesScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('an empty chat list explains itself', (tester) async {
    final repo = _FakeChatRepository();

    await tester.pumpWidget(MaterialApp(home: MessagesScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Καμία συζήτηση ακόμα'), findsOneWidget);
  });
}
