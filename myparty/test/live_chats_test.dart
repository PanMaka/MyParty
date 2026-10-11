import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import 'package:myparty/data/chat_repository.dart';
import 'package:myparty/data/chat_source.dart';
import 'package:myparty/data/direct_chat_repository.dart';
import 'package:myparty/models/chat_message.dart';
import 'package:myparty/state/data_changes.dart';
import 'package:myparty/state/live_refresh.dart';
import 'package:myparty/ui/screens/messages_screen.dart';
import 'package:myparty/ui/widgets/mp_bottom_nav.dart';

/// The chat lists' live behaviour: a read, a send or someone else's line
/// reaching the Messages tab with nobody pulling to refresh.
///
/// Both fakes keep the server's state, so a write through them changes what
/// the next fetch returns — otherwise "the refetch agrees with the patch"
/// would not be an assertion — and hand out one controllable stream per
/// broadcast topic.

/// One topic's worth of broadcast traffic.
class _Topic {
  final messages = StreamController<ChatMessage>.broadcast();
  final hidden = StreamController<String>.broadcast();
  final status = StreamController<RealtimeSubscribeStatus>.broadcast();
  int holders = 0;

  ChatChannel open() {
    holders += 1;
    return ChatChannel(
      messages: messages.stream,
      hiddenMessageIds: hidden.stream,
      status: status.stream,
      dispose: () async => holders -= 1,
    );
  }
}

ChatMessage _line(String conversationId, String body) => ChatMessage(
      id: 'line-$body',
      conversationId: conversationId,
      authorId: 'zoi',
      authorUsername: 'zoi',
      body: body,
      createdAt: DateTime.now().toUtc(),
    );

PartyChatSummary _chat({required String id, String body = 'see you there', int unread = 0}) => PartyChatSummary(
      partyId: id,
      partyTitle: 'Rooftop $id',
      isPrivate: true,
      startsAt: DateTime.now(),
      goingCount: 3,
      lastMessageBody: body,
      lastMessageAuthorUsername: 'zoi',
      lastMessageAt: DateTime.now(),
      unreadCount: unread,
    );

class _PartyChats extends ChatRepository {
  _PartyChats(this.chats);

  List<PartyChatSummary> chats;
  int fetches = 0;
  final topics = <String, _Topic>{};

  @override
  String? get currentUserId => 'me';

  @override
  Future<List<PartyChatSummary>> fetchPartyChats() async {
    fetches += 1;
    return chats;
  }

  @override
  Future<void> writeReadMarker(String partyId) async {
    chats = [for (final c in chats) c.partyId == partyId ? c.read() : c];
  }

  @override
  Future<ChatMessage> insertMessage({required String partyId, required String body}) async {
    chats = [
      for (final c in chats)
        c.partyId == partyId
            ? PartyChatSummary(
                partyId: c.partyId,
                partyTitle: c.partyTitle,
                isPrivate: c.isPrivate,
                startsAt: c.startsAt,
                goingCount: c.goingCount,
                lastMessageBody: body,
                lastMessageAuthorUsername: 'me',
                lastMessageAt: DateTime.now(),
                unreadCount: 0,
              )
            : c,
    ];
    return ChatMessage(
      id: 'mine',
      conversationId: partyId,
      authorId: 'me',
      authorUsername: '',
      body: body,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  ChatChannel subscribe(String partyId) => topics.putIfAbsent(partyId, _Topic.new).open();
}

class _DirectChats extends DirectChatRepository {
  _DirectChats(this.threads);

  List<DirectChatSummary> threads;
  int fetches = 0;
  final topics = <String, _Topic>{};

  /// The viewer's inbox:{uuid}, and how many holders it has right now.
  final inboxActivity = StreamController<String>.broadcast();
  final inboxStatus = StreamController<RealtimeSubscribeStatus>.broadcast();
  int inboxHolders = 0;

  @override
  InboxChannel? subscribeInbox() {
    inboxHolders += 1;
    return InboxChannel(
      activity: inboxActivity.stream,
      status: inboxStatus.stream,
      dispose: () async => inboxHolders -= 1,
    );
  }

  @override
  String? get currentUserId => 'me';

  @override
  Future<List<DirectChatSummary>> fetchDirectChats({DirectChatSummary? after, int limit = 30}) async {
    fetches += 1;
    return after == null ? threads : const [];
  }

  @override
  Future<void> writeReadMarker(String threadId) async {
    threads = [for (final t in threads) t.threadId == threadId ? t.read() : t];
  }

  @override
  ChatChannel subscribe(String threadId) => topics.putIfAbsent(threadId, _Topic.new).open();

  @override
  String? avatarUrl(String? path) => null;
}

DirectChatSummary _thread({required String id, String body = 'hey', int unread = 0}) => DirectChatSummary(
      threadId: id,
      peerId: 'peer-$id',
      peerUsername: 'peer_$id',
      peerAvatarPath: null,
      lastMessageBody: body,
      lastMessageAuthorId: 'peer-$id',
      lastMessageAt: DateTime.now(),
      activityAt: DateTime.now().toUtc(),
      unreadCount: unread,
    );

/// Longer than the list's refetch debounce.
const _settled = Duration(seconds: 1);

/// Two frames with the clock standing still: the bus delivers on a microtask,
/// so the event lands during the first and its setState paints on the second
/// — and no time passes, so nothing the debounce gates has run yet.
Future<void> _nextFrame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, _PartyChats parties, {_DirectChats? direct}) async {
  await tester.pumpWidget(MaterialApp(
    home: MessagesScreen(repository: parties, directRepository: direct ?? _DirectChats(const [])),
  ));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => visibleTab.value = null);

  group('the Parties list', () {
    testWidgets('a chat read anywhere clears its badge at once, and the refetch agrees', (tester) async {
      final repo = _PartyChats([_chat(id: 'p1', unread: 7)]);
      await _pump(tester, repo);
      expect(find.text('7'), findsOneWidget);
      final before = repo.fetches;

      // ChatScreen opened from the map, a party sheet or the host wizard —
      // none of which come back through this list — marks the chat read.
      await repo.markRead('p1');
      await _nextFrame(tester);

      expect(repo.fetches, before, reason: 'no round trip yet');
      expect(find.text('7'), findsNothing, reason: 'patched before any round trip');

      await tester.pump(_settled);
      await tester.pumpAndSettle();
      expect(repo.fetches, before + 1);
      expect(find.text('7'), findsNothing);
    });

    testWidgets('a message sent from an open chat moves the preview', (tester) async {
      final repo = _PartyChats([_chat(id: 'p1', body: 'see you there')]);
      await _pump(tester, repo);

      await repo.sendMessage(partyId: 'p1', body: 'running late');
      await tester.pump(_settled);
      await tester.pumpAndSettle();

      expect(find.text('me: running late'), findsOneWidget);
      expect(find.text('zoi: see you there'), findsNothing);
    });

    testWidgets("someone else's line on a listed chat's topic refetches the list", (tester) async {
      final repo = _PartyChats([_chat(id: 'p1', body: 'see you there')]);
      await _pump(tester, repo);
      expect(repo.topics['p1']?.holders, 1, reason: 'the list holds the topic of each chat it shows');
      final before = repo.fetches;

      // The server has the new line and the new unread count...
      repo.chats = [_chat(id: 'p1', body: 'doors at 10', unread: 1)];
      // ...and the topic says something happened.
      repo.topics['p1']!.messages.add(_line('p1', 'doors at 10'));
      await tester.pump(_settled);
      await tester.pumpAndSettle();

      expect(repo.fetches, before + 1);
      expect(find.text('zoi: doors at 10'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a burst of lines is one refetch, not one per line', (tester) async {
      final repo = _PartyChats([_chat(id: 'p1')]);
      await _pump(tester, repo);
      final before = repo.fetches;

      for (var i = 0; i < 5; i++) {
        repo.topics['p1']!.messages.add(_line('p1', 'line $i'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(_settled);
      await tester.pumpAndSettle();

      expect(repo.fetches, before + 1);
    });

    testWidgets('a reconnect refetches, since broadcast has no replay', (tester) async {
      final repo = _PartyChats([_chat(id: 'p1')]);
      await _pump(tester, repo);
      final topic = repo.topics['p1']!;
      final before = repo.fetches;

      topic.status.add(RealtimeSubscribeStatus.subscribed);
      await tester.pump(_settled);
      expect(repo.fetches, before, reason: 'the first subscribe is the join, not a gap');

      topic.status.add(RealtimeSubscribeStatus.subscribed);
      await tester.pump(_settled);
      await tester.pumpAndSettle();
      expect(repo.fetches, before + 1);
    });

    testWidgets('topics are held only while the Messages tab is on screen', (tester) async {
      visibleTab.value = MpTab.messages;
      final repo = _PartyChats([_chat(id: 'p1')]);
      await _pump(tester, repo);
      expect(repo.topics['p1']!.holders, 1);

      visibleTab.value = MpTab.map;
      await tester.pump();
      expect(repo.topics['p1']!.holders, 0);

      visibleTab.value = MpTab.messages;
      await tester.pumpAndSettle();
      expect(repo.topics['p1']!.holders, 1);
    });

    testWidgets('while hidden, a read waits for the tab to be shown', (tester) async {
      visibleTab.value = MpTab.map;
      final repo = _PartyChats([_chat(id: 'p1', unread: 4)]);
      await _pump(tester, repo);
      final before = repo.fetches;

      await repo.markRead('p1');
      await tester.pump(_settled);
      expect(repo.fetches, before);

      visibleTab.value = MpTab.messages;
      await tester.pumpAndSettle();
      expect(repo.fetches, before + 1);
      expect(find.text('4'), findsNothing);
    });
  });

  testWidgets("a block refetches both lists, so the blocked peer's thread leaves", (tester) async {
    final parties = _PartyChats([_chat(id: 'p1')]);
    final direct = _DirectChats([_thread(id: 't1', body: 'hey')]);
    await _pump(tester, parties, direct: direct);
    await tester.tap(find.text('Direct'));
    await tester.pumpAndSettle();
    expect(find.text('hey'), findsOneWidget);
    final partyFetches = parties.fetches;

    // get_direct_chats drops a thread with a blocked peer.
    direct.threads = const [];
    dataChanges.publish(const BlockChanged(userId: 'peer-t1', blocked: true));
    await tester.pump(_settled);
    await tester.pumpAndSettle();

    expect(find.text('hey'), findsNothing);
    expect(parties.fetches, partyFetches + 1);
  });

  group('the Direct list', () {
    Future<void> openDirect(WidgetTester tester, _DirectChats direct) async {
      await _pump(tester, _PartyChats(const []), direct: direct);
      await tester.tap(find.text('Direct'));
      await tester.pumpAndSettle();
    }

    testWidgets('a thread read anywhere clears its badge without a refresh', (tester) async {
      final direct = _DirectChats([_thread(id: 't1', unread: 3)]);
      await openDirect(tester, direct);
      expect(find.text('3'), findsOneWidget);

      final before = direct.fetches;
      await direct.markRead('t1');
      await _nextFrame(tester);
      expect(direct.fetches, before, reason: 'no round trip yet');
      expect(find.text('3'), findsNothing);

      await tester.pump(_settled);
      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);
    });

    testWidgets("the peer's line arrives over the inbox and refetches the list", (tester) async {
      final direct = _DirectChats([_thread(id: 't1', body: 'hey')]);
      await openDirect(tester, direct);
      expect(direct.inboxHolders, 1);
      expect(direct.topics, isEmpty, reason: 'one inbox, not a topic per thread');

      direct.threads = [_thread(id: 't1', body: 'are you coming?', unread: 1)];
      direct.inboxActivity.add('t1');
      await tester.pump(_settled);
      await tester.pumpAndSettle();

      expect(find.text('are you coming?'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('a thread somebody opens with you after the list loaded appears without a refresh', (tester) async {
      // The case per-thread topics could never cover: there was no topic for
      // this thread to hold when the list loaded.
      final direct = _DirectChats(const []);
      await openDirect(tester, direct);
      expect(find.textContaining('No direct messages yet'), findsOneWidget);

      direct.threads = [_thread(id: 'brand-new', body: 'hi, saw your party', unread: 1)];
      direct.inboxActivity.add('brand-new');
      await tester.pump(_settled);
      await tester.pumpAndSettle();

      expect(find.text('hi, saw your party'), findsOneWidget);
    });

    testWidgets('a reconnect of the inbox refetches, since broadcast has no replay', (tester) async {
      final direct = _DirectChats([_thread(id: 't1')]);
      await openDirect(tester, direct);
      final before = direct.fetches;

      direct.inboxStatus.add(RealtimeSubscribeStatus.subscribed);
      await tester.pump(_settled);
      expect(direct.fetches, before, reason: 'the first subscribe is the join');

      direct.inboxStatus.add(RealtimeSubscribeStatus.subscribed);
      await tester.pump(_settled);
      await tester.pumpAndSettle();
      expect(direct.fetches, before + 1);
    });

    testWidgets('the inbox is held only while the Messages tab is on screen', (tester) async {
      visibleTab.value = MpTab.messages;
      final direct = _DirectChats([_thread(id: 't1')]);
      await openDirect(tester, direct);
      expect(direct.inboxHolders, 1);

      visibleTab.value = MpTab.profile;
      await tester.pump();
      expect(direct.inboxHolders, 0);

      visibleTab.value = MpTab.messages;
      await tester.pumpAndSettle();
      expect(direct.inboxHolders, 1);
    });
  });
}
