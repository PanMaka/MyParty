import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// "Invited by @host" — shown to a guest on a party they hold an invitation
/// to, public or private (Phase 40). On a public party it is the whole of
/// what an invitation does in the app today, beside putting the party in
/// MY PARTIES; nobody is notified (docs/backlog.md 1.25).
///
/// [isInvited] comes from the read RPCs (`is_invited`), a property of the
/// caller like `my_rsvp_status`, so the badge cannot claim an invitation the
/// server does not have.
class InvitedBadge extends StatelessWidget {
  const InvitedBadge({super.key, required this.hostUsername});

  final String? hostUsername;

  @override
  Widget build(BuildContext context) {
    final who = hostUsername == null ? '' : ' by @$hostUsername';
    return Container(
      key: const Key('invited-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.purple.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.purple.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mail_outline, size: 12, color: AppColors.purpleLight),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              'Invited$who',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.purpleLight),
            ),
          ),
        ],
      ),
    );
  }
}
