import 'package:flutter/material.dart';

import '../../data/feed_repository.dart';
import '../../models/feed_post.dart';
import '../theme/app_theme.dart';

/// The one report action, shared by every UGC surface — posts, comments,
/// parties and profiles all open this rather than each growing their own
/// dialog. `reports.target_type` is the only thing that differs, so that is
/// the only parameter.
Future<void> showReportSheet(
  BuildContext context, {
  required ReportTarget target,
  required String targetId,
  FeedRepository? repository,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _ReportSheet(
      target: target,
      targetId: targetId,
      repository: repository ?? FeedRepository(),
    ),
  );
}

const _reasons = <String, String>{
  'spam': 'Spam ή διαφήμιση',
  'harassment': 'Παρενόχληση ή μίσος',
  'inappropriate': 'Ακατάλληλο περιεχόμενο',
  'false_info': 'Ψευδείς πληροφορίες',
  'other': 'Κάτι άλλο',
};

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.target,
    required this.targetId,
    required this.repository,
  });

  final ReportTarget target;
  final String targetId;
  final FeedRepository repository;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  bool _sending = false;

  Future<void> _send(String reason) async {
    if (_sending) return;
    setState(() => _sending = true);

    String message;
    try {
      await widget.repository.report(
        target: widget.target,
        targetId: widget.targetId,
        reason: reason,
      );
      message = 'Ευχαριστούμε, το είδαμε.';
    } on AlreadyReportedException {
      // The unique index did its job — a second report is not an error worth
      // alarming anyone about, it just means the first one already landed.
      message = 'Το έχεις ήδη αναφέρει.';
    } catch (_) {
      message = 'Δεν στάλθηκε. Δοκίμασε ξανά.';
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        // Scrollable: five reasons plus the header do not fit above the
        // keyboard-less fold on a short device, and a bottom sheet that
        // overflows renders the last option untappable.
        child: SingleChildScrollView(
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
            const Text('Αναφορά',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text('Τι δεν πάει καλά;',
                  style: TextStyle(fontSize: 12.5, color: AppColors.textAlpha(0.55))),
            ),
            for (final entry in _reasons.entries)
              Opacity(
                opacity: _sending ? 0.5 : 1,
                child: InkWell(
                  onTap: () => _send(entry.key),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.hairline),
                    ),
                    child: Text(entry.value,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
