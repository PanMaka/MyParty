import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/story_repository.dart';
import '../../models/story.dart';
import '../screens/story_viewer_screen.dart';
import '../../models/mp_party.dart' show MpPartyType;
import '../../utils/greek_date.dart';
import '../theme/app_theme.dart';
import 'diagonal_placeholder.dart';
import 'privacy_badge.dart';

/// Opens the "Σε ποιο πάρτι ανεβάζεις;" sheet. Returns true if a story was
/// actually uploaded, so the caller can refresh its rail.
Future<bool?> showStoryPickerSheet(
  BuildContext context, {
  StoryRepository? repository,
  ImagePicker? picker,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => StoryPickerSheet(repository: repository, picker: picker),
  );
}

/// Pick a party, pick a photo, upload it.
///
/// The upload is the four-step handshake in [StoryRepository.createStory] —
/// insert the row, get a one-shot signed URL, PUT the bytes, confirm. The
/// client never writes to the `story-media` bucket directly, and this sheet
/// deliberately has no idea what the bucket is called.
class StoryPickerSheet extends StatefulWidget {
  const StoryPickerSheet({super.key, this.repository, this.picker});

  final StoryRepository? repository;

  /// Injectable so a widget test can supply a photo without a camera roll.
  final ImagePicker? picker;

  @override
  State<StoryPickerSheet> createState() => _StoryPickerSheetState();
}

class _StoryPickerSheetState extends State<StoryPickerSheet> {
  late final StoryRepository _repo = widget.repository ?? StoryRepository();
  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  List<StoryTarget> _targets = [];
  bool _loading = true;
  bool _failed = false;
  String? _uploadingPartyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final targets = await _repo.fetchStoryTargets();
      if (!mounted) return;
      setState(() {
        _targets = targets;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _upload(StoryTarget target) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      // Resized on the way out rather than after upload: the bytes that never
      // leave the phone are the cheapest ones to store, and a story is watched
      // full-bleed on a phone screen.
      maxWidth: 1440,
      imageQuality: 82,
    );
    if (picked == null) return;

    setState(() {
      _uploadingPartyId = target.partyId;
      _error = null;
    });

    try {
      final bytes = await picked.readAsBytes();
      await _repo.createStory(
        partyId: target.partyId,
        bytes: bytes,
        contentType: 'image/jpeg',
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploadingPartyId = null;
        // Both "you cannot post here" and "you are posting too fast" arrive as
        // 42501 from the policy and the rate-limit trigger respectively. The
        // second is the one worth naming, because it is the only one a user can
        // do something about.
        _error = error.toString().contains('rate limit')
            ? 'Πολλά stories σε λίγη ώρα. Δοκίμασε αργότερα.'
            : 'Δεν ανέβηκε. Δοκίμασε ξανά.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 34),
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const Text('Σε ποιο πάρτι ανεβάζεις;',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(height: 4),
            Text(
              'Το story σου μπαίνει στο κοινό story του πάρτι, μαζί με όλων των άλλων. Σβήνει μόνο του σε 24 ώρες.',
              style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.textAlpha(0.5)),
            ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppColors.pink)),
              const SizedBox(height: 10),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 26),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_failed)
              _note('Κάτι πήγε στραβά.', onTap: _load)
            else if (_targets.isEmpty)
              // The honest empty state: the INSERT policy needs you to be able
              // to see the party, and the natural way to get there is to host
              // one or say you are going.
              _note('Δεν είσαι σε κανένα πάρτι ακόμα. Δήλωσε συμμετοχή ή φτιάξε το δικό σου.')
            else
              for (final target in _targets) _row(target),
          ],
        ),
      ),
    );
  }

  Widget _note(String text, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.textAlpha(0.6)),
          ),
        ),
      ),
    );
  }

  Widget _row(StoryTarget target) {
    final uploading = _uploadingPartyId == target.partyId;
    final accent = target.isPrivate ? AppColors.pink : AppColors.purple;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: _uploadingPartyId == null ? () => _upload(target) : null,
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: target.isPrivate ? 0.1 : 0.09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: uploading
                    ? const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: const DiagonalStripePlaceholder(
                          colors: [Color(0xFF1C1622), Color(0xFF151020)],
                        ),
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(target.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                    Text(
                      uploading ? 'Ανεβαίνει…' : formatPartyStart(target.startsAt),
                      style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.5)),
                    ),
                  ],
                ),
              ),
              PrivacyBadge(
                type: target.isPrivate ? MpPartyType.private : MpPartyType.public,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens a party's reel. Kept here because both entry points into the viewer —
/// the feed rail and this sheet's success path — want the same call shape.
void openStoryReel(
  BuildContext context, {
  required String partyId,
  String? partyTitle,
  bool isPrivate = false,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => StoryViewerScreen(
        partyId: partyId,
        partyTitle: partyTitle,
        isPrivate: isPrivate,
      ),
    ),
  );
}
