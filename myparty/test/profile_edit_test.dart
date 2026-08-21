import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:myparty/data/profile_repository.dart';
import 'package:myparty/models/profile.dart';
import 'package:myparty/ui/screens/profile_edit_screen.dart';
import 'package:myparty/ui/theme/app_theme.dart';

/// Records the three primitives [ProfileRepository.replaceAvatar] sequences,
/// and lets each of them be made to fail.
///
/// Subclasses rather than reimplements, so the REAL `replaceAvatar` runs its
/// real ordering against these. That is the whole point of the suite below: the
/// three failure paths are claims about what is left in the bucket, and a fake
/// that overrode `replaceAvatar` itself would assert nothing about any of them.
class _FakeProfileRepository extends ProfileRepository {
  _FakeProfileRepository({
    this.profile = _defaultProfile,
    this.failLoad = false,
    this.failUpload = false,
    this.failCommit = false,
    this.failRemove = false,
    this.failBio = false,
  });

  static const _defaultProfile = Profile(
    id: 'me',
    username: 'nikos',
    followerCount: 42,
    followingCount: 9,
    bio: 'Κουκάκι · ταράτσες και techno',
    avatarPath: 'me/old.jpg',
  );

  final Profile? profile;
  final bool failLoad;
  final bool failUpload;
  final bool failCommit;
  final bool failRemove;
  final bool failBio;

  /// Every primitive call in order, as `verb:argument`. Asserting on the whole
  /// list rather than on individual flags is deliberate — the ordering is the
  /// invariant, so the test has to be able to fail when only the order changes.
  final List<String> calls = [];

  /// Every value sent to the `bio` column, null included. Nullable entries are
  /// the point: clearing a bio must send an explicit null.
  final List<String?> bioWrites = [];

  /// When set, [uploadAvatarObject] parks on it.
  ///
  /// The three failure paths are all about WHEN something happens relative to
  /// the upload, and an upload that resolves in a microtask cannot be
  /// interrupted by anything — a test without this gate would tear the screen
  /// down after the save had already finished and pass for the wrong reason.
  Completer<void>? uploadGate;

  @override
  String? get currentUserId => 'me';

  @override
  Future<Profile?> fetchProfile({String? userId}) async {
    if (failLoad) throw Exception('offline');
    return profile;
  }

  @override
  String? avatarUrl(String? path) => path == null ? null : 'https://stub.invalid/$path';

  @override
  Future<void> updateBio(String? bio) async {
    bioWrites.add(bio);
    if (failBio) throw Exception('23514 check constraint');
  }

  @override
  Future<void> uploadAvatarObject(String path, Uint8List bytes, String contentType) async {
    calls.add('upload:$path');
    if (uploadGate != null) await uploadGate!.future;
    if (failUpload) throw Exception('network');
  }

  @override
  Future<void> writeAvatarPath(String path) async {
    calls.add('write:$path');
    if (failCommit) throw Exception('42501');
  }

  @override
  Future<bool> removeAvatarObject(String path) async {
    calls.add('remove:$path');
    return !failRemove;
  }
}

/// null bytes means the user backed out of the camera roll.
class _FakePicker extends ImagePicker {
  _FakePicker({this.bytes});

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
    return XFile.fromData(bytes!, name: 'avatar.jpg', mimeType: 'image/jpeg');
  }
}

/// A real 1x1 PNG, not filler bytes.
///
/// The preview is an `Image.memory`, so undecodable input exercises the
/// errorBuilder rather than the thing under test — and "the photo I picked
/// appears" is a property worth actually having.
final _bytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<void> _pumpEditor(
  WidgetTester tester,
  _FakeProfileRepository repo, {
  ImagePicker? picker,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: ProfileEditScreen(repository: repo, picker: picker ?? _FakePicker(bytes: _bytes)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------------
  // The mirror of profiles_bio_one_short_line. One group per SQL condition,
  // because a single "validates the bio" test passing tells you nothing about
  // which of the four conditions is actually implemented.
  // ---------------------------------------------------------------------
  group('BioConstraint', () {
    test('null is valid — it is how "no bio" is spelled', () {
      expect(BioConstraint.validate(null), isNull);
    });

    test('normalize collapses empty and whitespace-only to null, never to ""', () {
      // The constraint's `btrim(bio) <> ''` exists so that "unset" has exactly
      // one representation. A form that stored '' would produce a row that is
      // neither "has a bio" nor "has none", and every renderer downstream would
      // need its own emptiness check.
      expect(BioConstraint.normalize(''), isNull);
      expect(BioConstraint.normalize('   '), isNull);
      expect(BioConstraint.normalize('\t'), isNull);
    });

    test('normalize trims the value it keeps', () {
      expect(BioConstraint.normalize('  Κουκάκι  '), 'Κουκάκι');
    });

    test('rejects a newline or a carriage return — the column is one line', () {
      expect(BioConstraint.validate('δύο\nγραμμές'), isNotNull);
      expect(BioConstraint.validate('δύο\rγραμμές'), isNotNull);
    });

    test('accepts exactly 160 characters and refuses 161', () {
      expect(BioConstraint.validate('α' * 160), isNull);
      expect(BioConstraint.validate('α' * 161), isNotNull);
    });

    test('counts characters the way char_length does, not UTF-16 code units', () {
      // An emoji outside the BMP is 1 to Postgres `char_length` and 2 to Dart's
      // `String.length`. Measuring with `.length` would refuse bios the column
      // accepts, and would do it only to people who use emoji — the same shape
      // of bug as a byte cap applied to Greek, which is why the migration chose
      // char_length in the first place.
      final emoji = '🎉' * 100; // 100 characters, 200 UTF-16 code units.
      expect(emoji.length, 200);
      expect(BioConstraint.length(emoji), 100);
      expect(BioConstraint.validate(emoji), isNull);
    });

    test('a Greek bio is measured in characters, not bytes', () {
      // 160 Greek characters is 320 bytes in UTF-8. A byte cap would give Greek
      // users half the field.
      expect(BioConstraint.validate('Κ' * 160), isNull);
    });
  });

  // ---------------------------------------------------------------------
  // The ordering, run for real against recorded primitives.
  // ---------------------------------------------------------------------
  group('replaceAvatar ordering', () {
    test('uploads, commits, and only then deletes the object it replaced', () async {
      final repo = _FakeProfileRepository();

      final path = await repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg');

      expect(path, isNotNull);
      expect(repo.calls, [
        'upload:$path',
        'write:$path',
        'remove:me/old.jpg',
      ]);
    });

    test('never deletes the old object before the commit', () async {
      // Stated separately from the happy-path order because this is the one
      // that costs a user something: deleting first would destroy the avatar
      // they still have in exchange for one they might not get.
      final repo = _FakeProfileRepository(failCommit: true);

      await expectLater(
        repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg'),
        throwsA(isA<AvatarCommitFailure>()),
      );

      expect(repo.calls.any((c) => c == 'remove:me/old.jpg'), isFalse);
    });

    test('a first avatar deletes nothing', () async {
      final repo = _FakeProfileRepository();

      final path = await repo.replaceAvatar(bytes: _bytes, previousPath: null);

      expect(repo.calls, ['upload:$path', 'write:$path']);
    });

    test('keys the object inside the user folder the CHECK constrains it to', () async {
      final repo = _FakeProfileRepository();

      final path = (await repo.replaceAvatar(bytes: _bytes, previousPath: null))!;

      // profiles_avatar_path_own_folder, condition by condition. The bucket
      // policy governs where bytes may be WRITTEN; this constraint governs
      // where the column may POINT, and only the second stops someone wearing
      // another user's face.
      expect(path.startsWith('me/'), isTrue);
      expect(path.contains('..'), isFalse);
      expect(path.length, lessThanOrEqualTo(512));
    });

    test('a second upload does not reuse the first key', () async {
      // A fresh uuid per upload rather than overwriting a fixed key: the bucket
      // is public, so its URLs are cacheable and an overwritten key keeps
      // serving the previous photo.
      final repo = _FakeProfileRepository();

      final first = await repo.replaceAvatar(bytes: _bytes, previousPath: null);
      final second = await repo.replaceAvatar(bytes: _bytes, previousPath: first);

      expect(second, isNot(first));
    });
  });

  group('replaceAvatar failure paths', () {
    test('cancelling removes what it uploaded and writes no column', () async {
      final repo = _FakeProfileRepository();

      final path = await repo.replaceAvatar(
        bytes: _bytes,
        previousPath: 'me/old.jpg',
        isCancelled: () => true,
      );

      // Null is the cancellation, and the bucket is back where it started.
      expect(path, isNull);

      // The upload still happened — the storage client has no cancellation
      // token, so "cancel" cannot mean the bytes were never sent. It means they
      // were removed again, which is the difference between cancelling and
      // orphaning.
      expect(repo.calls.length, 2);
      expect(repo.calls.first, startsWith('upload:'));
      expect(repo.calls.last, startsWith('remove:'));
      expect(repo.calls.any((c) => c.startsWith('write:')), isFalse);

      // And the object removed is the one just uploaded, not the live one.
      expect(repo.calls.last, isNot('remove:me/old.jpg'));
    });

    test('cancelling after the commit is ignored, because it is no longer true', () async {
      // The flag is asked once, between the upload and the commit. A cancel
      // that arrives after the column write must not roll anything back: the
      // profile has changed, and reporting otherwise would be the lie.
      var cancelled = false;
      final repo = _FakeProfileRepository();

      final path = await repo.replaceAvatar(
        bytes: _bytes,
        previousPath: 'me/old.jpg',
        isCancelled: () => cancelled,
      );
      cancelled = true;

      expect(path, isNotNull);
      expect(repo.calls, ['upload:$path', 'write:$path', 'remove:me/old.jpg']);
    });

    test('a failed commit rolls the upload back and reports no orphan', () async {
      final repo = _FakeProfileRepository(failCommit: true);

      await expectLater(
        repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg'),
        throwsA(
          isA<AvatarCommitFailure>().having((f) => f.leftAnOrphan, 'leftAnOrphan', isFalse),
        ),
      );

      expect(repo.calls.length, 3);
      expect(repo.calls[1], startsWith('write:'));
      // The cleanup targets the new object; the old one is untouched, because
      // it is still the one the column points at.
      expect(repo.calls[2], startsWith('remove:'));
      expect(repo.calls[2], isNot('remove:me/old.jpg'));
    });

    test('a failed commit whose cleanup also fails names the orphan', () async {
      // The one state where a file really is left behind with nothing pointing
      // at it. Reported rather than swallowed: a screen that showed this as a
      // plain retry would be claiming a rollback that did not happen.
      final repo = _FakeProfileRepository(failCommit: true, failRemove: true);

      await expectLater(
        repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg'),
        throwsA(
          isA<AvatarCommitFailure>()
              .having((f) => f.leftAnOrphan, 'leftAnOrphan', isTrue)
              .having((f) => f.orphanedPath, 'orphanedPath', startsWith('me/')),
        ),
      );
    });

    test('a failed upload writes nothing and removes nothing', () async {
      final repo = _FakeProfileRepository(failUpload: true);

      await expectLater(
        repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg'),
        throwsA(isA<Exception>()),
      );

      // One call and one only: nothing to commit and nothing to clean up,
      // because nothing reached the bucket.
      expect(repo.calls.length, 1);
      expect(repo.calls.single, startsWith('upload:'));
    });

    test('failing to delete the OLD object still counts as success', () async {
      // The user asked to change their photo and their photo has changed.
      // Failing the operation here would report a success as a failure. The
      // leftover is bounded — it sits in this user's own folder, which
      // complete_account_erasure deletes by prefix.
      final repo = _FakeProfileRepository(failRemove: true);

      final path = await repo.replaceAvatar(bytes: _bytes, previousPath: 'me/old.jpg');

      expect(path, isNotNull);
      expect(repo.calls.last, 'remove:me/old.jpg');
    });
  });

  // ---------------------------------------------------------------------
  // The screen.
  // ---------------------------------------------------------------------
  group('the form', () {
    testWidgets('offers a bio and a photo, and nothing else', (tester) async {
      await _pumpEditor(tester, _FakeProfileRepository());

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('BIO'), findsOneWidget);
      expect(find.text('Άλλαξε φωτογραφία'), findsOneWidget);

      // There is no display_name, school or department column, and a form is
      // exactly where that decision would quietly be reversed.
      expect(find.textContaining('Όνομα'), findsNothing);
      expect(find.textContaining('Σχολή'), findsNothing);
      expect(find.textContaining('Τμήμα'), findsNothing);
      expect(find.textContaining('Πανεπιστήμιο'), findsNothing);
    });

    testWidgets('seeds the field from the stored bio', (tester) async {
      await _pumpEditor(tester, _FakeProfileRepository());

      expect(find.text('Κουκάκι · ταράτσες και techno'), findsOneWidget);
    });

    testWidgets('an account with neither starts empty rather than prefilled', (tester) async {
      // What every account looks like the day it is created. Nothing may be
      // substituted into the bio field: a suggested sentence sitting in an
      // editable box is one Save away from becoming the user's own words.
      await _pumpEditor(
        tester,
        _FakeProfileRepository(
          profile: const Profile(id: 'me', username: 'nikos', followerCount: 0, followingCount: 0),
        ),
      );

      expect(find.text('Μία γραμμή για σένα.'), findsOneWidget);
      expect(find.text('0/160'), findsOneWidget);

      // Nothing to save yet, so the button is inert rather than writing a
      // no-op PATCH.
      expect(find.text('Άλλαξε φωτογραφία'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry rather than an empty form', (tester) async {
      // An empty form over a failed load is the dangerous shape: it looks like
      // an account with no bio, and saving it would clear a bio that loaded
      // fine five seconds ago.
      final repo = _FakeProfileRepository(failLoad: true);
      await _pumpEditor(tester, repo);

      expect(find.text('Δεν φόρτωσε το προφίλ'), findsOneWidget);
      expect(find.text('Δοκίμασε ξανά'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(repo.bioWrites, isEmpty);
    });

    testWidgets('saves the trimmed bio', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo);

      await tester.enterText(find.byType(TextField), '  Ψυρρή, κάθε Πέμπτη  ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(repo.bioWrites, ['Ψυρρή, κάθε Πέμπτη']);
    });

    testWidgets('clearing the bio sends an explicit null, not an empty string', (tester) async {
      // The column's CHECK refuses '', so a form that sent one would fail with
      // a 23514 instead of clearing the bio. Null is the only spelling of
      // "no bio" — and ProfileRepository.updateBio has to send it rather than
      // omitting the key, which is the opposite of what updatePrivacy does.
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(repo.bioWrites, [null]);
    });

    testWidgets('a bio that only changed by whitespace writes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo);

      await tester.enterText(find.byType(TextField), '  Κουκάκι · ταράτσες και techno ');
      await tester.pumpAndSettle();

      // Normalizes to what is already stored, so the form is not dirty and the
      // save button does not arm — a PATCH storing an identical value is a
      // write that can fail for nothing.
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(repo.bioWrites, isEmpty);
    });

    testWidgets('refuses an over-long bio before the round trip', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo);

      await tester.enterText(find.byType(TextField), 'α' * 161);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(find.text('Μέχρι 160 χαρακτήρες.'), findsOneWidget);
      expect(repo.bioWrites, isEmpty);
    });

    testWidgets('counts what the constraint counts', (tester) async {
      await _pumpEditor(tester, _FakeProfileRepository());

      await tester.enterText(find.byType(TextField), '🎉🎉🎉');
      await tester.pumpAndSettle();

      // 3, not 6. The counter reads BioConstraint.length for the same reason
      // the validator does.
      expect(find.text('3/160'), findsOneWidget);
    });
  });

  group('the avatar', () {
    testWidgets('backing out of the camera roll changes nothing', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo, picker: _FakePicker());

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();

      // Not an error and not a state. Nothing happened, so nothing is said.
      expect(repo.calls, isEmpty);
      expect(find.text('Θα ανέβει όταν αποθηκεύσεις.'), findsNothing);
    });

    testWidgets('a picked photo is held until save, not uploaded on pick', (tester) async {
      final repo = _FakeProfileRepository();
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();

      expect(repo.calls, isEmpty);
      expect(find.text('Θα ανέβει όταν αποθηκεύσεις.'), findsOneWidget);

      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(repo.calls.first, startsWith('upload:'));
      expect(repo.calls.last, 'remove:me/old.jpg');
    });

    testWidgets('a failed commit says so and leaves the screen open', (tester) async {
      final repo = _FakeProfileRepository(failCommit: true);
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(find.text('Η φωτογραφία δεν αποθηκεύτηκε. Δοκίμασε ξανά.'), findsOneWidget);
      expect(find.text('Αποθήκευση'), findsOneWidget);
    });

    testWidgets('an orphaned object is reported as one, not as a plain retry', (tester) async {
      final repo = _FakeProfileRepository(failCommit: true, failRemove: true);
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      expect(
        find.text('Η φωτογραφία δεν αποθηκεύτηκε και δεν καθαρίστηκε πλήρως. Δοκίμασε ξανά.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed upload is distinguished from a failed commit', (tester) async {
      final repo = _FakeProfileRepository(failUpload: true);
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      // Nothing reached the bucket in this one, which is a different sentence.
      expect(find.text('Η φωτογραφία δεν ανέβηκε. Δοκίμασε ξανά.'), findsOneWidget);
    });

    testWidgets('a failed bio save stops before anything is uploaded', (tester) async {
      final repo = _FakeProfileRepository(failBio: true);
      await _pumpEditor(tester, repo);

      await tester.enterText(find.byType(TextField), 'Νέο bio');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Αποθήκευση'));
      await tester.pumpAndSettle();

      // Bio first is what makes this possible: the cheap atomic write goes
      // first, so its failure leaves the bucket untouched rather than stranding
      // a committed avatar next to an unsaved bio.
      expect(repo.calls, isEmpty);
      expect(find.text('Το bio δεν έγινε δεκτό.'), findsOneWidget);
    });

    testWidgets('the cancel button removes the uploaded object and commits nothing', (tester) async {
      final repo = _FakeProfileRepository();
      final gate = Completer<void>();
      repo.uploadGate = gate;
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Αποθήκευση'));
      await tester.pump();

      // The upload is genuinely in flight, which is the only state in which
      // cancelling means anything.
      expect(find.text('Άκυρο'), findsOneWidget);
      await tester.tap(find.text('Άκυρο'));
      await tester.pump();

      gate.complete();
      await tester.pumpAndSettle();

      expect(repo.calls.first, startsWith('upload:'));
      expect(repo.calls.any((c) => c.startsWith('write:')), isFalse);
      expect(repo.calls.last, startsWith('remove:'));
      // The object removed is the one just uploaded. The live avatar is still
      // the live avatar, because nothing committed over it.
      expect(repo.calls.last, isNot('remove:me/old.jpg'));
    });

    testWidgets('leaving the screen mid-upload cancels rather than orphans', (tester) async {
      // dispose() sets the same flag the button does, and replaceAvatar re-asks
      // it after the upload — so bytes already in flight when someone navigates
      // away are removed instead of being left with nothing pointing at them.
      // This is why the flag is a plain field and not derived from `mounted`:
      // the sequence has to keep running after the State is gone.
      final repo = _FakeProfileRepository();
      final gate = Completer<void>();
      repo.uploadGate = gate;
      await _pumpEditor(tester, repo);

      await tester.tap(find.text('Άλλαξε φωτογραφία'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Αποθήκευση'));
      await tester.pump();

      // Tear the screen down while the upload is still parked.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      gate.complete();
      await tester.pumpAndSettle();

      expect(repo.calls.first, startsWith('upload:'));
      expect(repo.calls.any((c) => c.startsWith('write:')), isFalse);
      expect(repo.calls.last, startsWith('remove:'));
      expect(repo.calls.last, isNot('remove:me/old.jpg'));
    });
  });
}
