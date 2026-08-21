import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/profile_repository.dart';
import '../../models/profile.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';

/// The two things a profile actually has: a bio and a photo.
///
/// There is no display name field, no school and no department, and their
/// absence is the same decision three times over — `20260820095801` did not add
/// the columns, and said why: "a schema that offers three text fields gets a
/// header with three text fields, whatever the design said". A form is where
/// that decision would quietly be reversed, so it is worth restating here: this
/// screen is not missing fields, it is the whole of what a profile is.
///
/// The avatar is picked into memory and uploaded on save rather than on pick.
/// That is what makes "Άκυρο" mean something during the upload — see
/// [ProfileRepository.replaceAvatar], which owns the ordering and the three
/// ways it can fail. The screen's job is to say which one happened.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, this.repository, this.picker});

  /// Injectable for the same reason every other screen takes one: a test
  /// double subclasses it and no Supabase client is ever constructed.
  final ProfileRepository? repository;

  /// Injectable so a widget test can supply a photo without a camera roll,
  /// exactly as [StoryPickerSheet] does.
  final ImagePicker? picker;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  final _bio = TextEditingController();

  Profile? _profile;
  bool _loading = true;
  Object? _loadError;

  /// The picked photo, held in memory until save. Null means "not changing the
  /// avatar", which is a different thing from "no avatar" — this screen offers
  /// no way to express the second, deliberately.
  Uint8List? _pendingAvatar;

  bool _saving = false;

  /// Set by "Άκυρο" and by [dispose], and read by [ProfileRepository.replaceAvatar]
  /// through a closure.
  ///
  /// A plain field rather than anything derived from `mounted`, because the
  /// save deliberately outlives this widget: an upload cannot be aborted
  /// mid-flight, so navigating away has to leave something behind that still
  /// answers "yes, cancelled" when the bytes land, or the object is orphaned.
  bool _cancelled = false;

  /// Shown under the buttons rather than in a snackbar. A snackbar outlives the
  /// screen and disappears on its own, which is wrong for a message the user
  /// may need to act on ("the photo did not save, your bio did").
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // Navigating away IS a cancellation. Without this, an upload in flight
    // would land after the screen is gone and commit a change nobody is
    // watching for — or fail and have nowhere to report it.
    _cancelled = true;
    _bio.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await _profiles.fetchProfile();
      if (!mounted) return;
      setState(() {
        _profile = profile;
        // Seeded once. The controller is the edit buffer from here on, so a
        // reload must not stamp over what the user is typing.
        _bio.text = profile?.bio ?? '';
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _pick() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      // Resized on the way out, like a story: an avatar renders at 74 logical
      // pixels and the bytes that never leave the phone are the cheapest ones
      // to store. 512 leaves room for a larger rendering later without making
      // this a full-resolution photo upload.
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );

    // The user backed out of the camera roll. Not an error and not a state —
    // nothing has happened, so nothing is reported.
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pendingAvatar = bytes;
      _error = null;
    });
  }

  /// Whether the bio in the field differs from the stored one, comparing
  /// normalized values rather than raw text.
  ///
  /// Typing a space after a bio and deleting it again must not count as a
  /// change, and neither must clearing a field that was already empty — both
  /// normalize to the same thing the column holds, and a PATCH that stores an
  /// identical value is a write that can fail for nothing.
  bool get _bioChanged => BioConstraint.normalize(_bio.text) != _profile?.bio;

  bool get _dirty => _bioChanged || _pendingAvatar != null;

  Future<void> _save() async {
    if (_saving) return;

    final bio = BioConstraint.normalize(_bio.text);
    // The form's copy of the CHECK. It refuses the same four things, before
    // the round trip rather than after — the constraint still runs, and is
    // still what decides.
    final invalid = BioConstraint.validate(bio);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }

    setState(() {
      _saving = true;
      _cancelled = false;
      _error = null;
    });

    // Bio first, on purpose. It is one cheap atomic PATCH, so if it fails
    // nothing has been uploaded and the screen is exactly where it was. Doing
    // it second would mean a bio failure after an avatar had already committed,
    // which is a partial save with no good thing to say about it.
    if (_bioChanged) {
      try {
        await _profiles.updateBio(bio);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          // 23514 is the CHECK refusing something [BioConstraint] let through,
          // which means the mirror has drifted from the constraint. Named
          // separately because it is a bug in this app rather than something
          // the user did.
          _error = error.toString().contains('23514')
              ? 'Το bio δεν έγινε δεκτό.'
              : 'Το bio δεν αποθηκεύτηκε. Δοκίμασε ξανά.';
        });
        return;
      }
    }

    final pending = _pendingAvatar;
    if (pending != null) {
      try {
        final newPath = await _profiles.replaceAvatar(
          bytes: pending,
          previousPath: _profile?.avatarPath,
          isCancelled: () => _cancelled,
        );

        // Null is the cancellation, and it is a real outcome rather than a
        // failure: the object has already been removed by the repository, so
        // there is nothing to clean up and nothing to apologise for. The bio
        // above it may well have saved, which is why this pops with true.
        if (newPath == null) {
          if (!mounted) return;
          Navigator.of(context).pop(_bioChanged);
          return;
        }
      } on AvatarCommitFailure catch (failure) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = failure.leftAnOrphan
              // Said out loud rather than hidden. The profile is unchanged
              // either way, but in this branch a file was left in the bucket,
              // and a screen that reported it as a plain retry would be
              // claiming a rollback that did not happen.
              ? 'Η φωτογραφία δεν αποθηκεύτηκε και δεν καθαρίστηκε πλήρως. Δοκίμασε ξανά.'
              : 'Η φωτογραφία δεν αποθηκεύτηκε. Δοκίμασε ξανά.';
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          // The upload itself failed, so nothing reached the bucket and
          // nothing was written. Distinct from the branch above, where bytes
          // did land.
          _error = 'Η φωτογραφία δεν ανέβηκε. Δοκίμασε ξανά.';
        });
        return;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// Requests cancellation of an in-flight save.
  ///
  /// Does not pop and does not stop the spinner: the upload is still running
  /// and the repository still has to delete what it uploaded. Claiming the
  /// screen was done before that finished would be the orphan this whole path
  /// exists to prevent.
  void _cancel() {
    setState(() {
      _cancelled = true;
      _error = 'Ακυρώνεται…';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Επεξεργασία προφίλ',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_loadError != null || _profile == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Δεν φόρτωσε το προφίλ',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.7)),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                setState(() {
                  _loading = true;
                  _loadError = null;
                });
                _load();
              },
              child: const Text(
                'Δοκίμασε ξανά',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.pinkLight),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Center(child: _avatarPicker()),
        const SizedBox(height: 26),
        Text('BIO', style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
        const SizedBox(height: 9),
        _bioField(),
        const SizedBox(height: 22),
        _saveRow(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.pinkLight),
            ),
          ),
      ],
    );
  }

  Widget _avatarPicker() {
    final profile = _profile;
    final pending = _pendingAvatar;
    final url = _profiles.avatarUrl(profile?.avatarPath);

    final placeholder = DiagonalStripePlaceholder(
      colors: profile?.placeholderColors ?? const [Color(0xFF241E3C), Color(0xFF1B1630)],
    );

    // Memory beats the bucket: once something is picked, the preview must show
    // what will be uploaded rather than what is still stored, or the user
    // cannot tell whether their tap registered.
    final Widget image = pending != null
        ? Image.memory(
            pending,
            width: 96,
            height: 96,
            fit: BoxFit.cover,
            // A picked file is not guaranteed to decode — the camera roll can
            // hand back something truncated. Same reason the network case has
            // one: without it the preview is a broken-image glyph, and the user
            // cannot tell that from "the upload will fail".
            errorBuilder: (_, _, _) => placeholder,
          )
        : url == null
            ? placeholder
            : Image.network(
                url,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
              );

    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.purple.withValues(alpha: 0.5), width: 2),
          ),
          child: image,
        ),
        const SizedBox(height: 12),
        GestureDetector(
          // Disabled during a save: picking a second photo mid-upload would
          // mean the bytes in flight and the bytes on screen are different
          // pictures, and whichever committed would be a coin toss.
          onTap: _saving ? null : _pick,
          child: Text(
            pending == null ? 'Άλλαξε φωτογραφία' : 'Διάλεξε άλλη',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _saving ? AppColors.textAlpha(0.3) : AppColors.purpleLight,
            ),
          ),
        ),
        if (pending != null)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              'Θα ανέβει όταν αποθηκεύσεις.',
              style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.4)),
            ),
          ),
      ],
    );
  }

  Widget _bioField() {
    final count = BioConstraint.length(_bio.text.trim());
    final over = count > BioConstraint.maxCharacters;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _bio,
          enabled: !_saving,
          // One line, because the column is one line. maxLines rather than an
          // input formatter that strips newlines: BioConstraint.validate is the
          // thing that refuses them, and a formatter quietly deleting pasted
          // text would make the rule invisible instead of enforcing it.
          maxLines: 1,
          // Deliberately NO maxLength. Flutter's limiter counts grapheme
          // clusters and the CHECK counts characters, so the two disagree on
          // exactly the input where it matters — a field that stops accepting
          // keystrokes at a boundary the database does not share is worse than
          // one that says why. BioConstraint is the single authority, and the
          // counter below reads from it.
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _dirty && !_saving ? _save() : null,
          style: const TextStyle(fontSize: 14.5),
          decoration: InputDecoration(
            hintText: 'Μία γραμμή για σένα.',
            hintStyle: TextStyle(fontSize: 14.5, color: AppColors.textAlpha(0.3)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.04),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: AppColors.hairline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: over ? AppColors.pink : AppColors.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: over ? AppColors.pink : AppColors.purple),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Άδειο σημαίνει «χωρίς bio».',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textAlpha(0.38)),
                ),
              ),
              Text(
                '$count/${BioConstraint.maxCharacters}',
                style: AppTextStyles.mono(
                  size: 10.5,
                  color: over ? AppColors.pinkLight : AppColors.textAlpha(0.38),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _saveRow() {
    if (_saving) {
      return Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(13),
              ),
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: _cancelled ? null : _cancel,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  border: Border.all(color: AppColors.hairline),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text(
                  'Άκυρο',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: _cancelled ? AppColors.textAlpha(0.35) : AppColors.text,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final enabled = _dirty;
    return GestureDetector(
      onTap: enabled ? _save : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: enabled ? AppColors.purpleGradient : null,
          color: enabled ? null : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Text(
          'Αποθήκευση',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: enabled ? AppColors.text : AppColors.textAlpha(0.3),
          ),
        ),
      ),
    );
  }
}
