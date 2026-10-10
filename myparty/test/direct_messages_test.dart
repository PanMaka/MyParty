import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeSubscribeStatus;

import 'package:myparty/data/chat_repository.dart';
import 'package:myparty/data/chat_source.dart';
import 'package:myparty/data/direct_chat_repository.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/chat_message.dart';
import 'package:myparty/models/party_summary.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/models/profile_stats.dart';
import 'package:myparty/ui/screens/blocked_accounts_screen.dart';
import 'package:myparty/ui/screens/chat_screen.dart';
import 'package:myparty/ui/screens/messages_screen.dart';
import 'package:myparty/ui/screens/profile_screen.dart';
import 'package:myparty/ui/widgets/privacy_badge.dart';

// Phase 33: direct messages, the Direct tab, and Block / Unblock.
//
// The server decides everything these screens show — who may open a thread,
// who may send, what a block hides. So the fakes below stand in for the RPCs'
// ANSWERS, and the tests assert what the screens do with them: which id they
// hand to which call, what they render, and that every refusal reads the same.

/// Same pair, same id, from either side — what `get_or_create_direct_thread`
/// guarantees with its ordered-pair unique key. The fake reproduces the
/// guarantee so a test can show the client adds nothing of its own on top
/// (no local cache, no client-side id).
String _pairId(String a, String b) {
  final pair = [a, b]..sort();
  return 'thread-${pair.join('-')}';
}

class _FakeDirectChats extends DirectChatRepository {
  _FakeDirectChats({
    this.threads = const [],
    this.history = const [],
    this.refuse = false,
  });

  final List<DirectChatSummary> threads;
  final List<ChatMessage> history;

  /// Every refusal — blocked, policy, deleted — is the same 42501 from the
  /// server, so the fake has one switch for all of them.
  final bool refuse;

  final List<String> openedWith = [];
  final List<String> openedIds = [];
  final List<DirectChatSummary?> listCursors = [];
  final List<String> historyFor = [];
  final List<String> sentTo = [];
  final List<String> markedRead = [];
  final List<String> subscribedTo = [];

  final messageEvents = StreamController<ChatMessage>.broadcast();
  final hiddenEvents = StreamController<String>.broadcast();
  final statusEvents = StreamController<RealtimeSubscribeStatus>.broadcast();

  @override
  String? get currentUserId => 'me';

  @override
  Future<String> openThread(String otherUserId) async {
    openedWith.add(otherUserId);
    if (refuse) throw Exception('42501 cannot message this user');
    final id = _pairId('me', otherUserId);
    openedIds.add(id);
    return id;
  }

  @override
  Future<List<DirectChatSummary>> fetchDirectChats({DirectChatSummary? after, int limit = 30}) async {
    listCursors.add(after);
    final start = after == null ? 0 : threads.indexWhere((t) => t.threadId == after.threadId) + 1;
    return threads.skip(start).take(limit).toList();
  }

  @override
  Future<List<ChatMessage>> fetchMessages(String threadId, {ChatMessage? before, int limit = 30}) async {
    historyFor.add(threadId);
    return before == null ? history.reversed.take(limit).toList() : const [];
  }

  @override
  Future<List<ChatMessage>> fetchMessagesSince(String threadId, DateTime since) async => const [];

  @override
  Future<ChatMessage> sendMessage({required String threadId, required String body}) async {
    sentTo.add(threadId);
    return ChatMessage(
      id: 'stored-$body',
      conversationId: threadId,
      authorId: 'me',
      authorUsername: '',
      body: body,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> markRead(String threadId) async => markedRead.add(threadId);

  @override
  Future<void> hideMessage(String messageId, {String? reason}) async {}

  @override
  ChatChannel subscribe(String threadId) {
    subscribedTo.add(threadId);
    return ChatChannel(
      messages: messageEvents.stream,
      hiddenMessageIds: hiddenEvents.stream,
      status: statusEvents.stream,
      dispose: () async {},
    );
  }

  @override
  String? avatarUrl(String? path) => null;
}

class _FakePartyChats extends ChatRepository {
  @override
  String? get currentUserId => 'me';

  @override
  Future<List<PartyChatSummary>> fetchPartyChats() async => const [];
}

/// The block lives here, and the profile fake reads it: once the viewer blocks
/// someone, the `profiles` SELECT policy hides that account from them, so
/// `fetchProfile` starts returning null — exactly as the server behaves.
class _FakeSocial extends SocialRepository {
  _FakeSocial({List<Profile> blocked = const []}) : blocked = List.of(blocked);

  final List<Profile> blocked;
  final List<String> calls = [];

  bool blocks(String id) => blocked.any((p) => p.id == id);

  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => const [];

  @override
  Future<bool> isFollowing(String targetUserId) async => false;

  @override
  Future<void> block(String targetUserId) async {
    calls.add('block:$targetUserId');
    blocked.add(Profile(id: targetUserId, username: 'zoi', followerCount: 0, followingCount: 0));
  }

  @override
  Future<void> unblock(String targetUserId) async {
    calls.add('unblock:$targetUserId');
    blocked.removeWhere((p) => p.id == targetUserId);
  }

  @override
  Future<bool> isBlocking(String targetUserId) async {
    calls.add('isBlocking:$targetUserId');
    return blocks(targetUserId);
  }

  @override
  Future<List<Profile>> fetchBlocked() async => List.of(blocked);
}

class _FakeProfiles extends ProfileRepository {
  _FakeProfiles(this.social, {this.exists = true});

  final _FakeSocial social;

  /// False models a profile hidden for a reason that is NOT the viewer's own
  /// block — the other person blocked the viewer, or the row is not there.
  final bool exists;

  static const them = Profile(id: 'them', username: 'zoi', followerCount: 4, followingCount: 2);

  @override
  String? get currentUserId => 'me';

  @override
  Future<Profile?> fetchProfile({String? userId}) async =>
      exists && !social.blocks(them.id) ? them : null;

  @override
  Future<ProfileStats> fetchStats({String? userId}) async => ProfileStats.empty;

  @override
  String? avatarUrl(String? path) => null;
}

class _FakeParties extends PartyRepository {
  @override
  Future<List<PartySummary>> fetchHostedParties({
    String? hostId,
    required PartyWindow window,
    bool publicOnly = false,
    int limit = 12,
  }) async => const [];
}

DirectChatSummary _thread(
  String id, {
  String peer = 'zoi',
  String? body = 'see you there',
  String? author = 'them',
  int unread = 0,
  int minute = 0,
}) {
  final at = DateTime.utc(2026, 10, 9, 20).subtract(Duration(minutes: minute));
  return DirectChatSummary(
    threadId: id,
    peerId: 'peer-$id',
    peerUsername: peer,
    peerAvatarPath: null,
    lastMessageBody: body,
    lastMessageAuthorId: author,
    lastMessageAt: at.toLocal(),
    activityAt: at,
    unreadCount: unread,
  );
}

ChatMessage _msg(String id, String body, {String author = 'them', int minute = 0}) => ChatMessage(
      id: id,
      conversationId: 't1',
      authorId: author,
      authorUsername: author == 'me' ? '' : 'zoi',
      body: body,
      createdAt: DateTime.utc(2026, 10, 9, 20, minute),
    );

Future<_FakeSocial> _pumpOtherProfile(
  WidgetTester tester,
  _FakeDirectChats chats, {
  _FakeSocial? social,
  bool exists = true,
}) async {
  final s = social ?? _FakeSocial();
  await tester.pumpWidget(MaterialApp(
    home: ProfileScreen(
      target: const OtherProfile('them'),
      repository: _FakeProfiles(s, exists: exists),
      social: s,
      parties: _FakeParties(),
      directChats: chats,
    ),
  ));
  await tester.pumpAndSettle();
  return s;
}

void main() {
  group('the DM chat screen', () {
    testWidgets('is the shared chat screen, pointed at the thread', (tester) async {
      final chats = _FakeDirectChats(history: [
        _msg('m1', 'are you coming saturday?'),
        _msg('m2', 'yes!', author: 'me', minute: 1),
      ]);

      await tester.pumpWidget(MaterialApp(
        home: ChatScreen.direct(threadId: 't1', peerUsername: 'zoi', repository: chats),
      ));
      await tester.pumpAndSettle();

      expect(find.text('@zoi'), findsOneWidget);
      expect(find.text('are you coming saturday?'), findsOneWidget);
      expect(find.text('yes!'), findsOneWidget);

      // Every call went to the THREAD — history, read state and the dm topic.
      expect(chats.historyFor, ['t1']);
      expect(chats.markedRead, contains('t1'));
      expect(chats.subscribedTo, ['t1']);

      // A DM is always two people; there is no privacy tier to badge.
      expect(find.byType(PrivacyBadge), findsNothing);
      expect(find.widgetWithText(TextField, 'Message…'), findsOneWidget);
    });

    testWidgets('sends into the thread and renders live lines', (tester) async {
      final chats = _FakeDirectChats();
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen.direct(threadId: 't1', peerUsername: 'zoi', repository: chats),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'on my way');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(chats.sentTo, ['t1']);
      expect(find.text('on my way'), findsOneWidget);

      chats.messageEvents.add(_msg('live1', 'great, see you'));
      await tester.pumpAndSettle();
      expect(find.text('great, see you'), findsOneWidget);
    });

    testWidgets('offers no "hide" on the other person\'s line -- hiding a DM is author-only', (tester) async {
      final chats = _FakeDirectChats(history: [_msg('m1', 'hello')]);
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen.direct(threadId: 't1', peerUsername: 'zoi', repository: chats),
      ));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('hello'));
      await tester.pumpAndSettle();

      expect(find.text('Hide message'), findsNothing);
    });
  });

  group('the Direct tab', () {
    Future<void> pumpMessages(WidgetTester tester, _FakeDirectChats chats) async {
      await tester.pumpWidget(MaterialApp(
        home: MessagesScreen(repository: _FakePartyChats(), directRepository: chats),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct'));
      await tester.pumpAndSettle();
    }

    testWidgets('the chat list has a Parties tab and a Direct tab', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MessagesScreen(repository: _FakePartyChats(), directRepository: _FakeDirectChats()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Parties'), findsOneWidget);
      expect(find.text('Direct'), findsOneWidget);
      // Parties is the default, as it was before the tabs existed.
      expect(find.textContaining('No chats yet'), findsOneWidget);
    });

    testWidgets('lists threads with the peer, a preview and the unread badge', (tester) async {
      final chats = _FakeDirectChats(threads: [
        _thread('t1', peer: 'zoi', body: 'see you there', author: 'them', unread: 3),
        _thread('t2', peer: 'nikos', body: 'ok!', author: 'me', minute: 5),
      ]);
      await pumpMessages(tester, chats);

      expect(find.text('@zoi'), findsOneWidget);
      expect(find.text('see you there'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // Your own last line is labelled as yours.
      expect(find.text('You: ok!'), findsOneWidget);
    });

    testWidgets('a row opens its thread', (tester) async {
      final chats = _FakeDirectChats(threads: [_thread('t1')]);
      await pumpMessages(tester, chats);

      await tester.tap(find.text('@zoi'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatScreen), findsOneWidget);
      expect(chats.historyFor, ['t1']);
    });

    testWidgets('pages by keyset cursor, never by offset', (tester) async {
      final chats = _FakeDirectChats(
        threads: [for (var i = 0; i < 45; i++) _thread('t$i', peer: 'user$i', minute: i)],
      );
      await pumpMessages(tester, chats);

      await tester.fling(find.byKey(const ValueKey('direct-chat-list')), const Offset(0, -8000), 4000);
      await tester.pumpAndSettle();

      expect(chats.listCursors.length, greaterThan(1));
      expect(chats.listCursors.first, isNull);
      expect(chats.listCursors[1]?.threadId, 't29', reason: 'the cursor is the last row drawn');
    });

    testWidgets('an empty Direct tab says how to start one', (tester) async {
      await pumpMessages(tester, _FakeDirectChats());

      expect(find.textContaining('No direct messages yet'), findsOneWidget);
    });
  });

  group('the Message button', () {
    testWidgets('opens the thread with that user', (tester) async {
      final chats = _FakeDirectChats();
      await _pumpOtherProfile(tester, chats);

      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();

      expect(chats.openedWith, ['them']);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('@zoi'), findsWidgets);
      expect(chats.historyFor, [_pairId('me', 'them')]);
      expect(find.text('Coming soon'), findsNothing);
    });

    testWidgets('opening it again reuses the same conversation', (tester) async {
      final chats = _FakeDirectChats();
      await _pumpOtherProfile(tester, chats);

      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();

      // The screen asks the server every time and opens whatever it answers --
      // it creates nothing itself, so it cannot create a duplicate.
      expect(chats.openedIds, [_pairId('me', 'them'), _pairId('me', 'them')]);
      expect(chats.historyFor, [_pairId('me', 'them'), _pairId('me', 'them')]);
    });

    testWidgets('every refusal reads the same, and opens nothing', (tester) async {
      final chats = _FakeDirectChats(refuse: true);
      await _pumpOtherProfile(tester, chats);

      await tester.tap(find.text('Message'));
      await tester.pumpAndSettle();

      expect(find.text('You can’t message this user'), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
    });
  });

  group('Block / Unblock', () {
    testWidgets('block is in the profile menu, confirms, then shows the undo', (tester) async {
      final social = await _pumpOtherProfile(tester, _FakeDirectChats());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Report'), findsOneWidget);
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();

      // A confirmation that says what blocking does.
      expect(find.text('Block @zoi?'), findsOneWidget);
      expect(find.textContaining('neither of you can message the other'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Block'));
      await tester.pumpAndSettle();

      expect(social.calls, contains('block:them'));
      expect(find.text('You blocked this account'), findsOneWidget);
      expect(find.text('Message'), findsNothing);

      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();

      expect(social.calls, contains('unblock:them'));
      expect(find.text('@zoi'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('cancelling the confirmation blocks nobody', (tester) async {
      final social = await _pumpOtherProfile(tester, _FakeDirectChats());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(social.calls.where((c) => c.startsWith('block:')), isEmpty);
      expect(find.text('Message'), findsOneWidget);
    });

    testWidgets('a profile hidden by THEIR block still just reads "not available"', (tester) async {
      // The viewer blocked nobody; the profile is hidden anyway (the other
      // person blocked the viewer, or the row is gone). The screen must not
      // offer an Unblock -- that would tell the viewer which case it is.
      await _pumpOtherProfile(tester, _FakeDirectChats(), exists: false);

      expect(find.text('This profile is not available'), findsOneWidget);
      expect(find.text('You blocked this account'), findsNothing);
      expect(find.text('Unblock'), findsNothing);
    });

    testWidgets('Blocked accounts lists your blocks and unblocks them', (tester) async {
      final social = _FakeSocial(blocked: [
        const Profile(id: 'them', username: 'zoi', followerCount: 0, followingCount: 0),
      ]);
      await tester.pumpWidget(MaterialApp(home: BlockedAccountsScreen(social: social)));
      await tester.pumpAndSettle();

      expect(find.text('@zoi'), findsOneWidget);
      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();

      expect(social.calls, ['unblock:them']);
      expect(find.text('@zoi'), findsNothing);
    });
  });
}
