import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/profile_repository.dart';
import '../../models/profile.dart';
import '../../utils/english_date.dart';
import '../theme/app_theme.dart';
import '../widgets/diagonal_placeholder.dart';

/// What a profile has: a username, a bio and a photo — plus an optional first
/// and last name, shown under the username since Phase 49.
///
/// There is no display name field, no school and no department, and their
/// absence is the same decision three times over — `20260820095801` did not add
/// the columns, and said why: "a schema that offers three text fields gets a
/// header with three text fields, whatever the design said". The first and
/// last name are not that field reversed: they live in `user_names`, are
/// optional (both or neither), and the header shows them as one muted line
/// under the username (Phase 49).
///
/// The avatar is picked into memory and uploaded on save rather than on pick.
/// That is what makes "Cancel" mean something during the upload — see
/// [ProfileRepository.replaceAvatar], which owns the ordering and the three
/// ways it can fail. The screen's job is to say which one happened.
///
/// A username change goes through `change_username`, which allows one per 30
/// days and reserves the old name for 14. Both numbers are the server's; the
/// screen asks [ProfileRepository.fetchUsernameNextChangeAt] whether a change
/// is open, and confirms before spending it.
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
  final _username = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();

  Profile? _profile;
  bool _loading = true;
  Object? _loadError;

  /// The username as the server last confirmed it. Separate from [_profile]
  /// because a save can succeed on the username and fail later on the photo;
  /// the retry must not send the username again, or it would hit the cooldown
  /// it just started.
  String _savedUsername = '';

  /// When a username change is next allowed; null when it is allowed now.
  DateTime? _nextUsernameChange;

  /// The stored names, or null for an account with none.
  ({String firstName, String lastName})? _savedNames;

  /// The picked photo, held in memory until save. Null means "not changing
  /// the photo" unless [_removeAvatar] is set.
  Uint8List? _pendingAvatar;

  /// "Remove photo" was tapped: on save, the avatar is cleared and its object
  /// deleted. Mutually exclusive with [_pendingAvatar] — picking a photo
  /// clears it, and removing clears the pick.
  bool _removeAvatar = false;

  bool _saving = false;

  /// Set by "Cancel" and by [dispose], and read by [ProfileRepository.replaceAvatar]
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

  /// Per-field messages, shown under their own field.
  String? _usernameError;
  String? _firstNameError;
  String? _lastNameError;

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
    _username.dispose();
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final (profile, names, nextChange) = await (
        _profiles.fetchProfile(),
        _profiles.fetchMyNames(),
        _profiles.fetchUsernameNextChangeAt(),
      ).wait;
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _savedNames = names == null ? null : (firstName: names.firstName, lastName: names.lastName);
        _savedUsername = profile?.username ?? '';
        _nextUsernameChange = nextChange;
        // Seeded once. The controllers are the edit buffers from here on, so a
        // reload must not stamp over what the user is typing.
        _bio.text = profile?.bio ?? '';
        _username.text = _savedUsername;
        _firstName.text = names?.firstName ?? '';
        _lastName.text = names?.lastName ?? '';
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
      _removeAvatar = false;
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

  bool get _usernameChanged => _username.text.trim() != _savedUsername;

  bool get _namesChanged =>
      _firstName.text.trim() != (_savedNames?.firstName ?? '') ||
      _lastName.text.trim() != (_savedNames?.lastName ?? '');

  bool get _dirty =>
      _bioChanged || _usernameChanged || _namesChanged || _pendingAvatar != null || _removeAvatar;

  /// The stored username predates the rule. Said once, under the field, and
  /// never forced: the rule binds the next name chosen, not this one.
  bool get _usernameBelowRule => _savedUsername.isNotEmpty && !UsernameConstraint.isValid(_savedUsername);

  Future<void> _save() async {
    if (_saving) return;

    final bio = BioConstraint.normalize(_bio.text);
    final username = _username.text.trim();
    final first = _firstName.text.trim();
    final last = _lastName.text.trim();

    // Every form-side check first, so nothing is written while another field
    // is still wrong. The server runs the real ones regardless.
    final usernameError = _usernameChanged ? UsernameConstraint.validate(username) : null;
    // Both or neither: two empty fields remove the name.
    final nameErrors = _namesChanged ? PersonNameConstraint.validatePair(first, last) : null;
    final firstError = nameErrors?.first;
    final lastError = nameErrors?.last;
    // The form's copy of the CHECK. It refuses the same four things, before
    // the round trip rather than after — the constraint still runs, and is
    // still what decides.
    final bioError = BioConstraint.validate(bio);
    setState(() {
      _usernameError = usernameError;
      _firstNameError = firstError;
      _lastNameError = lastError;
      _error = bioError;
    });
    if (usernameError != null || firstError != null || lastError != null || bioError != null) return;

    // The one change that costs something, so it is asked about before
    // anything at all is written.
    if (_usernameChanged && !await _confirmUsernameChange(username)) return;
    if (!mounted) return;

    setState(() {
      _saving = true;
      _cancelled = false;
      _error = null;
    });

    // Username first: it is the write most likely to be refused (taken,
    // reserved), and refusing it before anything else is written leaves the
    // screen exactly where it was.
    if (_usernameChanged) {
      try {
        final next = await _profiles.changeUsername(username);
        if (!mounted) return;
        setState(() {
          _savedUsername = username;
          _nextUsernameChange = next;
        });
      } on UsernameRefused catch (refused) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          if (refused.reason == UsernameRefusal.cooldown) _nextUsernameChange = refused.nextChangeAt;
          _usernameError = _refusalText(refused);
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'Your username was not changed. Try again.';
        });
        return;
      }
    }

    if (_namesChanged) {
      try {
        final removing = first.isEmpty && last.isEmpty;
        if (removing) {
          await _profiles.clearNames();
        } else {
          await _profiles.setNames(firstName: first, lastName: last);
        }
        if (!mounted) return;
        setState(() => _savedNames = removing ? null : (firstName: first, lastName: last));
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'Your name was not saved. Try again.';
        });
        return;
      }
    }

    // Bio before the photo, on purpose. It is one cheap atomic PATCH, so if it
    // fails nothing has been uploaded. Doing it second would mean a bio
    // failure after an avatar had already committed, which is a partial save
    // with no good thing to say about it.
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
              ? 'Your bio was not accepted.'
              : 'Your bio was not saved. Try again.';
        });
        return;
      }
    }

    final current = _profile?.avatarPath;
    if (_removeAvatar && current != null) {
      try {
        // A false return means the object outlived the column write. The
        // photo is gone from the profile either way, and avatar-sweep deletes
        // the object within the hour, so it is not reported as a failure.
        await _profiles.removeAvatar(previousPath: current);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'Your photo was not removed. Try again.';
        });
        return;
      }
    }

    final pending = _pendingAvatar;
    if (pending != null) {
      try {
        final newPath = await _profiles.replaceAvatar(
          bytes: pending,
          previousPath: current,
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
              ? 'Your photo was not saved and was not fully cleaned up. Try again.'
              : 'Your photo was not saved. Try again.';
        });
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          // The upload itself failed, so nothing reached the bucket and
          // nothing was written. Distinct from the branch above, where bytes
          // did land.
          _error = 'Your photo did not upload. Try again.';
        });
        return;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String _refusalText(UsernameRefused refused) => switch (refused.reason) {
        UsernameRefusal.taken => 'That username is already taken.',
        UsernameRefusal.invalid => UsernameConstraint.rules,
        UsernameRefusal.unchanged => 'That is already your username.',
        UsernameRefusal.cooldown => refused.nextChangeAt == null
            ? 'You changed your username recently. Try again later.'
            : 'You can change your username again on ${formatCalendarDateEn(refused.nextChangeAt!)}.',
      };

  Future<bool> _confirmUsernameChange(String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Change your username to @$username?'),
        content: Text(
          "You won't be able to change it again for 30 days. "
          '@$_savedUsername stays reserved for you for 14 days, so nobody else can take it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Change')),
        ],
      ),
    );
    return confirmed ?? false;
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
      _error = 'Cancelling…';
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
          'Edit profile',
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
              'Could not load your profile',
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
                'Try again',
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
        _sectionLabel('USERNAME'),
        _usernameField(),
        const SizedBox(height: 22),
        _sectionLabel('YOUR NAME'),
        _nameFields(),
        const SizedBox(height: 22),
        _sectionLabel('BIO'),
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

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(text, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
      );

  Widget _caption(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
        child: Text(
          text,
          style: TextStyle(fontSize: 11.5, height: 1.4, color: color ?? AppColors.textAlpha(0.38)),
        ),
      );

  InputDecoration _decoration({String? hint, String? prefix, bool error = false}) {
    final idle = error ? AppColors.pink : AppColors.hairline;
    final focused = error ? AppColors.pink : AppColors.purple;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14.5, color: AppColors.textAlpha(0.3)),
      prefixText: prefix,
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: idle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: focused),
      ),
    );
  }

  Widget _usernameField() {
    final next = _nextUsernameChange;
    final locked = next != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _username,
          // Read-only during the cooldown rather than editable-then-refused:
          // the answer is already known, so offering the field would only
          // set up a refusal.
          enabled: !_saving && !locked,
          maxLines: 1,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() => _usernameError = null),
          style: const TextStyle(fontSize: 14.5),
          decoration: _decoration(prefix: '@', error: _usernameError != null),
        ),
        if (_usernameError != null) _caption(_usernameError!, color: AppColors.pinkLight),
        if (locked)
          _caption('You can change your username again on ${formatCalendarDateEn(next)}.')
        else ...[
          _caption(UsernameConstraint.rules),
          _caption('You can change it once every 30 days. Your old username stays reserved for 14 days.'),
        ],
        if (_usernameBelowRule && !_usernameChanged)
          _caption(
            "Your current username doesn't meet these rules. You can keep it; "
            'a new one has to follow them.',
            color: AppColors.purpleLight,
          ),
      ],
    );
  }

  Widget _nameFields() {
    Widget field(TextEditingController controller, String hint, String? error) {
      return TextField(
        controller: controller,
        enabled: !_saving,
        maxLines: 1,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        onChanged: (_) => setState(() {
          _firstNameError = null;
          _lastNameError = null;
        }),
        style: const TextStyle(fontSize: 14.5),
        decoration: _decoration(hint: hint, error: error != null),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(_firstName, 'First name', _firstNameError),
        if (_firstNameError != null) _caption(_firstNameError!, color: AppColors.pinkLight),
        const SizedBox(height: 10),
        field(_lastName, 'Last name', _lastNameError),
        if (_lastNameError != null) _caption(_lastNameError!, color: AppColors.pinkLight),
        _caption(nameVisibilityNote),
        // Staged like Remove photo: it empties the fields, and Save removes
        // the name. Hidden once both are empty, when there is nothing to remove.
        if (_firstName.text.isNotEmpty || _lastName.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: GestureDetector(
              onTap: _saving
                  ? null
                  : () => setState(() {
                        _firstName.clear();
                        _lastName.clear();
                        _firstNameError = null;
                        _lastNameError = null;
                      }),
              child: Text(
                'Remove name',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _saving ? AppColors.textAlpha(0.3) : AppColors.purpleLight,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _avatarPicker() {
    final profile = _profile;
    final pending = _pendingAvatar;
    final url = _removeAvatar ? null : _profiles.avatarUrl(profile?.avatarPath);
    final hasStoredAvatar = profile?.avatarPath != null;

    final placeholder = DiagonalStripePlaceholder(
      colors: profile?.placeholderColors ?? const [Color(0xFF241E3C), Color(0xFF1B1630)],
    );

    // Memory beats the bucket: once something is picked, the preview must show
    // what will be uploaded rather than what is still stored, or the user
    // cannot tell whether their tap registered. A pending removal shows the
    // placeholder for the same reason.
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

    Widget action(String label, VoidCallback onTap) => GestureDetector(
          // Disabled during a save: picking a second photo mid-upload would
          // mean the bytes in flight and the bytes on screen are different
          // pictures, and whichever committed would be a coin toss.
          onTap: _saving ? null : onTap,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _saving ? AppColors.textAlpha(0.3) : AppColors.purpleLight,
            ),
          ),
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
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            action(pending == null ? 'Change photo' : 'Choose another', _pick),
            // The third state, offered only where there is something to
            // remove and nothing picked in its place.
            if (hasStoredAvatar && pending == null && !_removeAvatar) ...[
              const SizedBox(width: 18),
              action('Remove photo', () => setState(() {
                    _removeAvatar = true;
                    _error = null;
                  })),
            ],
            if (_removeAvatar) ...[
              const SizedBox(width: 18),
              action('Keep photo', () => setState(() => _removeAvatar = false)),
            ],
          ],
        ),
        if (pending != null || _removeAvatar)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              pending != null ? 'It will upload when you save.' : 'It will be removed when you save.',
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
          decoration: _decoration(hint: 'One line about you.', error: over),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Leave it empty for no bio.',
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
                  'Cancel',
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
          'Save',
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
