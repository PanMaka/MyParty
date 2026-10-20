import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:myparty/data/party_repository.dart';
import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/data/social_repository.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/services/geocoding_service.dart';
import 'package:myparty/ui/screens/host_wizard_screen.dart';
import 'package:myparty/ui/screens/location_picker_screen.dart';

import 'support/fake_geocoder.dart';

class _FakePartyRepository extends PartyRepository {
  /// A viewer who hosts none of the fixtures, so every party opens its sheet
  /// rather than the host dashboard.
  @override
  String? get currentUserId => 'viewer';

  _FakePartyRepository({this.failCover = false});

  final bool failCover;
  final created = <Map<String, dynamic>>[];
  final covers = <(String, Uint8List)>[];

  @override
  Future<String> insertPartyWithInvites({
    required Map<String, dynamic> party,
    List<String> inviteeIds = const [],
  }) async {
    created.add(party);
    return 'party-1';
  }

  @override
  Future<String> putCover(String partyId, Uint8List bytes) async {
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

const _aischylou = GeocodedPlace(
  label: 'Αισχύλου 12, 105 54 Αθήνα',
  point: LatLng(37.97874, 23.72517),
  area: 'Ψυρρή',
);

const _atThePin = GeocodedPlace(
  label: 'Χριστοκοπίδου 14, 105 55 Αθήνα',
  point: _picked,
  area: 'Ψυρρή',
);

Future<_FakePartyRepository> _pump(
  WidgetTester tester, {
  _FakePartyRepository? repository,
  Uint8List? pickerBytes,
  FakeGeocoder? geocoder,
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
      geocoder: geocoder ?? FakeGeocoder(),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

Finder get _address => find.byKey(const Key('wizard-address'));
Finder get _area => find.byKey(const Key('wizard-area'));

String _fieldText(WidgetTester tester, Finder field) => tester.widget<TextField>(field).controller!.text;

/// Types into the address field and lets the 400ms debounce run out.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.ensureVisible(_address);
  await tester.enterText(_address, text);
  await tester.pump(const Duration(milliseconds: 401));
  await tester.pump();
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
    const missing = 'Choose an address or place the pin on the map';

    testWidgets('no pin: stays on step 1 and says so', (tester) async {
      await _pump(tester);

      await _tap(tester, find.text('Continue'));

      expect(find.text('STEP 1 OF 4'), findsOneWidget);
      expect(find.text(missing), findsOneWidget);
    });

    testWidgets('a typed address alone is NOT enough -- the pin is the location', (tester) async {
      await _pump(tester);

      await tester.enterText(_address, '12 Example Street');
      await _tap(tester, find.text('Continue'));

      expect(find.text('STEP 1 OF 4'), findsOneWidget,
          reason: 'an address used to be enough, and the party landed where the phone was');
      expect(find.text(missing), findsOneWidget);
    });

    testWidgets('a spot on the map is enough, and clears the error', (tester) async {
      await _pump(tester);
      await _tap(tester, find.text('Continue'));
      expect(find.text(missing), findsOneWidget);

      await _pickOnMap(tester);

      expect(find.text(missing), findsNothing);
      expect(find.text('Adjust pin'), findsOneWidget);
      expect(find.text('37.96420, 23.72710'), findsOneWidget);
      expect(find.byType(FlutterMap), findsOneWidget, reason: 'a preview of the pin');

      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
    });

    testWidgets('clearing the spot brings the requirement back', (tester) async {
      await _pump(tester);
      await _pickOnMap(tester);

      await _tap(tester, find.byKey(const Key('wizard-pick-clear')));
      expect(find.text('📍 Place the pin on the map'), findsOneWidget);

      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 1 OF 4'), findsOneWidget);
      expect(find.text(missing), findsOneWidget);
    });

    testWidgets('there is no "wherever you are" fallback any more', (tester) async {
      await _pump(tester);
      expect(find.textContaining('The pin goes where you are'), findsNothing);
      expect(find.textContaining('The pin is the party’s location'), findsOneWidget);
    });

    testWidgets('the attribution is under the field', (tester) async {
      await _pump(tester);
      expect(find.text(geocodeAttribution), findsOneWidget);
    });
  });

  group('address search', () {
    testWidgets('choosing a suggestion places the pin and fills address and area', (tester) async {
      final geocoder = FakeGeocoder(places: [_aischylou]);
      await _pump(tester, geocoder: geocoder);

      await _search(tester, 'Αισχύλου 12');
      expect(geocoder.searches, ['Αισχύλου 12']);

      await _tap(tester, find.byKey(const Key('address-suggestion-0')));

      expect(_fieldText(tester, _address), 'Αισχύλου 12, 105 54 Αθήνα');
      expect(_fieldText(tester, _area), 'Ψυρρή');
      expect(find.text(formatPickedPoint(_aischylou.point)), findsOneWidget);
      expect(find.byKey(const Key('address-suggestions')), findsNothing, reason: 'the list closes');
      expect(geocoder.reverses, isEmpty, reason: 'the suggestion already IS the address');

      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
    });

    testWidgets('under 3 characters nothing is searched', (tester) async {
      final geocoder = FakeGeocoder(places: [_aischylou]);
      await _pump(tester, geocoder: geocoder);

      await _search(tester, 'Αι');

      expect(geocoder.searches, isEmpty);
      expect(find.byKey(const Key('address-suggestions')), findsNothing);
    });

    testWidgets('no matches says so, and the pin can still be placed by hand', (tester) async {
      await _pump(tester, geocoder: FakeGeocoder());

      await _search(tester, 'zzzqqq');
      expect(find.text(geocodeNoResultsMessage), findsOneWidget);

      await _pickOnMap(tester);
      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
    });

    for (final failure in GeocodeFailure.values) {
      testWidgets('a ${failure.name} failure is named, with the manual way out', (tester) async {
        await _pump(tester, geocoder: FakeGeocoder(searchFailure: failure));

        await _search(tester, 'Ερμού 10');

        expect(find.text(geocodeFailureMessage(failure)), findsOneWidget);
        expect(geocodeFailureMessage(failure), contains('pin'));
      });
    }

    testWidgets('placing the pin by hand fills an empty address and area from the pin', (tester) async {
      final geocoder = FakeGeocoder(reversePlace: _atThePin);
      await _pump(tester, geocoder: geocoder);

      await _pickOnMap(tester);

      expect(geocoder.reverses, [_picked]);
      expect(_fieldText(tester, _address), 'Χριστοκοπίδου 14, 105 55 Αθήνα');
      expect(_fieldText(tester, _area), 'Ψυρρή');
    });

    testWidgets('the host’s own address is never overwritten by a pin move; it is offered instead', (tester) async {
      final geocoder = FakeGeocoder(reversePlace: _atThePin);
      await _pump(tester, geocoder: geocoder);

      await tester.enterText(_address, 'The old factory, rooftop');
      await _pickOnMap(tester);

      expect(_fieldText(tester, _address), 'The old factory, rooftop');
      expect(find.byKey(const Key('wizard-address-offer')), findsOneWidget);

      await _tap(tester, find.byKey(const Key('wizard-address-offer')));
      expect(_fieldText(tester, _address), 'Χριστοκοπίδου 14, 105 55 Αθήνα');
      expect(find.byKey(const Key('wizard-address-offer')), findsNothing);
    });

    testWidgets('an address from the pin can be edited, e.g. "rooftop, 3rd floor"', (tester) async {
      final repo = await _pump(tester, geocoder: FakeGeocoder(places: [_aischylou]));

      await _search(tester, 'Αισχύλου 12');
      await _tap(tester, find.byKey(const Key('address-suggestion-0')));
      await tester.enterText(_address, 'Αισχύλου 12, rooftop, 3rd floor');
      await tester.pump(const Duration(milliseconds: 401));

      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));
      await _tap(tester, find.text('See what they’ll see'));
      await _tap(tester, find.text('Create the party'));

      expect(repo.created.single['address'], 'Αισχύλου 12, rooftop, 3rd floor');
      expect(repo.created.single['lat'], closeTo(_aischylou.point.latitude, 1e-9),
          reason: 'editing the text never moves the pin');
    });

    testWidgets('a failed reverse lookup says so and leaves the field to the host', (tester) async {
      await _pump(tester, geocoder: FakeGeocoder(reverseFailure: GeocodeFailure.network));

      await _pickOnMap(tester);

      expect(find.textContaining('Couldn’t look up an address for this spot'), findsOneWidget);
      expect(_fieldText(tester, _address), isEmpty);
      await _tap(tester, find.text('Continue'));
      expect(find.text('STEP 2 OF 4'), findsOneWidget, reason: 'the pin is enough');
    });

    testWidgets('moving the pin by dragging the map: the saved point is the dragged one', (tester) async {
      final geocoder = FakeGeocoder(reversePlace: _atThePin);
      final repo = await _pump(tester, geocoder: geocoder);
      await _pickOnMap(tester);

      // Reopen ("Adjust pin") and drag the map under the fixed pin.
      await _tap(tester, find.byKey(const Key('wizard-pick-on-map')));
      await tester.drag(find.byType(FlutterMap), const Offset(-120, -160));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _tap(tester, find.byKey(const Key('location-picker-confirm')));

      expect(geocoder.reverses, hasLength(2), reason: 'the moved pin is looked up again');
      final moved = geocoder.reverses.last;
      expect(moved.latitude, lessThan(_picked.latitude));
      expect(moved.longitude, greaterThan(_picked.longitude));

      await _tap(tester, find.text('Continue'));
      await _tap(tester, find.text('Private, continue'));
      await _tap(tester, find.text('See what they’ll see'));
      await _tap(tester, find.text('Create the party'));

      expect(repo.created.single['lat'], closeTo(moved.latitude, 1e-9));
      expect(repo.created.single['lon'], closeTo(moved.longitude, 1e-9));
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

    testWidgets('address, area and description go to the server apart, and nothing server-owned', (tester) async {
      final repo = await _pump(tester, geocoder: FakeGeocoder(places: [_aischylou]));
      await _search(tester, 'Αισχύλου 12');
      await _tap(tester, find.byKey(const Key('address-suggestion-0')));
      await tester.enterText(find.widgetWithText(TextField, 'e.g. This is going to be fun!'), 'Bring snacks.');

      await walkToCreate(tester);

      final party = repo.created.single;
      expect(party['address'], 'Αισχύλου 12, 105 54 Αθήνα');
      expect(party['area'], 'Ψυρρή');
      expect(party['description'], 'Bring snacks.', reason: 'the address is no longer folded in');
      expect(party['lat'], closeTo(_aischylou.point.latitude, 1e-9));
      expect(party['lon'], closeTo(_aischylou.point.longitude, 1e-9));
      for (final key in ['is_sponsored', 'party_tier', 'status']) {
        expect(party.containsKey(key), isFalse, reason: '$key is refused by the server (42501)');
      }
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
      await tester.enterText(_address, '12 Example Street');
      await _pickOnMap(tester);

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
