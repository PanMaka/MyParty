import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/ui/screens/host_wizard_screen.dart';

class _FakePartyRepository extends PartyRepository {
  _FakePartyRepository({this.failCover = false});

  final bool failCover;
  final created = <Map<String, dynamic>>[];
  final covers = <(String, Uint8List)>[];

  @override
  Future<String> createPartyWithInvites({
    required Map<String, dynamic> party,
    List<String> inviteeIds = const [],
  }) async {
    created.add(party);
    return 'party-1';
  }

  @override
  Future<String> uploadCover(String partyId, Uint8List bytes) async {
    covers.add((partyId, bytes));
    if (failCover) throw StateError('upload failed');
    return '$partyId/cover';
  }
}

class _FakeSocialRepository extends SocialRepository {
  @override
  Future<List<Profile>> fetchFollowing({String? userId}) async => const [];
}

class _FakeProfileRepository extends ProfileRepository {
  @override
  Future<Profile?> fetchProfile({String? userId}) async =>
      const Profile(id: 'me', username: 'zoi', followerCount: 0, followingCount: 0);
}

class _FakePicker extends ImagePicker {
  _FakePicker(this.bytes);

  final Uint8List bytes;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async =>
      XFile.fromData(bytes, name: 'cover');
}

/// A real 1x1 PNG — the preview is an Image.memory, so it has to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// The first bytes of a GIF: an image, and one the bucket refuses.
final _gif = Uint8List.fromList(utf8.encode('GIF89a') + List.filled(16, 0));

const _picked = LatLng(37.96420, 23.72710);

/// What the done screen handed to the share sheet, per test.
final _shared = <String>[];

Future<_FakePartyRepository> _pump(
  WidgetTester tester, {
  _FakePartyRepository? repository,
  Uint8List? pickerBytes,
}) async {
  final repo = repository ?? _FakePartyRepository();
  _shared.clear();
  await tester.pumpWidget(MaterialApp(
    home: HostWizardScreen(
      repository: repo,
      social: _FakeSocialRepository(),
      profiles: _FakeProfileRepository(),
      picker: _FakePicker(pickerBytes ?? _png),
      // The picker opens on this fix; the tests confirm without moving, so
      // whatever it returns is exactly this point.
      locate: () async => _picked,
      share: (text) async => _shared.add(text),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _pickOnMap(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('wizard-pick-on-map')));
  await _tap(tester, find.byKey(const Key('location-picker-confirm')));
}

void main() {
  group('where is the party', () {
    testWidgets('neither an address nor a spot: stays on step 1 and says so', (tester) async {
      await _pump(tester);

      await _tap(tester, find.text('Continue'));

      expect(find.text('STEP 1 OF 4'), findsOneWidget);
      expect(find.text('This field is necessary'), findsOneWidget);
    });

    testWidgets('an address alone is enough', (tester) async {
      await _pump(tester);

      await tester.enterText(find.byType(TextField).at(1), '12 Example Street');
      await _tap(tester, find.text('Continue'));

      expect(find.text('STEP 2 OF 4'), findsOneWidget);
    });

    testWidgets('a spot on the map alone is enough, and clears the error', (tester) async {
      await _pump(tester);
      await _tap(tester, find.text('Continue'));
      expect(find.text('This field is necessary'), findsOneWidget);

      await _pickOnMap(tester);

      expect(find.text('This field is necessary'), findsNothing);
      expect(find.text('📍 Pinned on the map'), findsOneWidget);
      expect(find.text('37.96420, 23.72710'), findsOneWidget);

      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
    });

    testWidgets('clearing the spot brings the requirement back', (tester) async {
      await _pump(tester);
      await _pickOnMap(tester);

      await _tap(tester, find.byKey(const Key('wizard-pick-clear')));
      expect(find.text('📍 Pick point on map'), findsOneWidget);

      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 1 OF 4'), findsOneWidget);
      expect(find.text('This field is necessary'), findsOneWidget);
    });

    testWidgets('without a spot the host is told where the pin will go', (tester) async {
      await _pump(tester);
      expect(find.textContaining('The pin goes where you are'), findsOneWidget);

      await _pickOnMap(tester);
      expect(find.textContaining('The pin goes where you are'), findsNothing);
    });
  });

  group('creating the party', () {
    Future<void> walkToCreate(WidgetTester tester) async {
      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));
      await _tap(tester, find.text('See what they’ll see'));
      await _tap(tester, find.text('Create the party'));
    }

    testWidgets('the picked spot is the party’s location', (tester) async {
      final repo = await _pump(tester);
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.created, hasLength(1));
      expect(repo.created.single['lat'], closeTo(_picked.latitude, 1e-9));
      expect(repo.created.single['lon'], closeTo(_picked.longitude, 1e-9));
      expect(find.text('Your party is live'), findsOneWidget);
    });

    testWidgets('a spot with no address reads "See map for location" on the review card', (tester) async {
      await _pump(tester);
      await _pickOnMap(tester);

      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));
      await _tap(tester, find.text('See what they’ll see'));

      expect(find.textContaining('· See map for location'), findsOneWidget);
    });

    testWidgets('a typed address is shown as-is on the review card', (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField).at(1), '12 Example Street');

      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));
      await _tap(tester, find.text('See what they’ll see'));

      expect(find.textContaining('· 12 Example Street'), findsOneWidget);
      expect(find.textContaining('See map for location'), findsNothing);
    });

    testWidgets('step 3 explains the link instead of offering a fake one', (tester) async {
      await _pump(tester);
      await _pickOnMap(tester);
      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));

      expect(find.textContaining('Only people you invite can open it'), findsOneWidget);
      expect(find.textContaining('myparty.gr'), findsNothing);
      expect(find.textContaining('joins the guest list'), findsNothing);
      expect(find.text('Copy'), findsNothing);
    });

    testWidgets('the done screen shares the real link of the party just created', (tester) async {
      await _pump(tester);
      await _pickOnMap(tester);
      await walkToCreate(tester);

      await _tap(tester, find.byKey(const Key('host-done-share')));

      // Private by default, so the link alone -- no title.
      expect(_shared, ['https://mypartycorp.com/p/party-1']);
    });

    testWidgets('the name defaults to the host’s party', (tester) async {
      final repo = await _pump(tester);
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.created.single['title'], "zoi's party");
    });

    testWidgets('a cover is uploaded after the party exists, to that party', (tester) async {
      final repo = await _pump(tester);
      await _tap(tester, find.byKey(const Key('wizard-cover')));
      expect(find.text('Change cover'), findsOneWidget);
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.covers, hasLength(1));
      expect(repo.covers.single.$1, 'party-1');
      expect(repo.covers.single.$2, _png);
      expect(find.textContaining('cover didn’t upload'), findsNothing);
    });

    testWidgets('no cover picked, no upload attempted', (tester) async {
      final repo = await _pump(tester);
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.covers, isEmpty);
    });

    testWidgets('a removed cover is not uploaded', (tester) async {
      final repo = await _pump(tester);
      await _tap(tester, find.byKey(const Key('wizard-cover')));
      await _tap(tester, find.byKey(const Key('wizard-cover-remove')));
      expect(find.text('Change cover'), findsNothing);
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.covers, isEmpty);
    });

    testWidgets('a failed cover does not fail the party, and the host is told', (tester) async {
      final repo = await _pump(tester, repository: _FakePartyRepository(failCover: true));
      await _tap(tester, find.byKey(const Key('wizard-cover')));
      await _pickOnMap(tester);

      await walkToCreate(tester);

      expect(repo.created, hasLength(1));
      expect(find.text('Your party is live'), findsOneWidget);
      expect(find.textContaining('cover didn’t upload'), findsOneWidget);
    });
  });

  testWidgets('an image the bucket would refuse is turned away at pick time', (tester) async {
    await _pump(tester, pickerBytes: _gif);

    await _tap(tester, find.byKey(const Key('wizard-cover')));

    expect(find.textContaining('can’t be used as a cover'), findsOneWidget);
    expect(find.text('Change cover'), findsNothing);
  });

  group('PartyRepository.coverContentType', () {
    test('reads JPEG and PNG from their signatures', () {
      expect(PartyRepository.coverContentType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])), 'image/jpeg');
      expect(PartyRepository.coverContentType(_png), 'image/png');
    });

    test('refuses everything else, including too few bytes to tell', () {
      expect(PartyRepository.coverContentType(_gif), isNull);
      expect(PartyRepository.coverContentType(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(PartyRepository.coverContentType(Uint8List(0)), isNull);
    });
  });
}
