import 'package:flutter/material.dart';

import '../../data/profile_repository.dart';
import '../../models/profile_privacy.dart';
import '../../services/auth_service.dart';
import '../theme/app_theme.dart';
import 'account_deletion_screen.dart';
import 'notification_settings_screen.dart';

/// Everything that used to hang off the bottom of the profile tab.
///
/// The profile screen was three screens stacked: an identity header, the
/// owner's party list, and — below the fold, reachable only by scrolling past
/// content that belongs to a visitor's reading of the page — privacy,
/// notifications, account deletion and sign out. Those four are the owner's
/// controls, they are never part of what a visitor sees, and burying them under
/// the party list meant the two most consequential rows in the app (location
/// consent and account deletion) were the two hardest to reach. They live
/// behind the gear in the profile header now.
///
/// The sections keep the grouping they had, and the grouping is still not
/// cosmetic: NOTIFICATIONS is separate from PRIVACY because two of its rows
/// are consent — a legal state with a deletion consequence — rather than
/// preferences, and ACCOUNT is separate from both because everything above
/// it is reversible and it is not.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.repository});

  /// Injectable so widget tests can subclass [ProfileRepository] without a
  /// Supabase client ever existing, the same way `ProfileScreen` does.
  final ProfileRepository? repository;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();

  ProfilePrivacy? _privacy;
  bool _busy = false;

  /// Separate from `_privacy == null`, which is also the loading state. Both
  /// leave the rows untappable — opening a tier sheet with no current tier to
  /// check is what `_privacy!` would blow up on — but only one of them should
  /// keep saying "…", because a row that loads forever reads as a broken app
  /// rather than a failed request.
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Self-only by construction: `fetchPrivacy` takes no user id and reads the
  /// caller's own row. This screen is reachable from the owner's profile alone,
  /// which is what keeps that true.
  Future<void> _load() async {
    try {
      final privacy = await _profiles.fetchPrivacy();
      if (mounted) setState(() => _privacy = privacy);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Wraps every privacy write, exactly as [NotificationSettingsScreen] does:
  /// two taps cannot race each other into the database, and a rejected write
  /// reloads rather than leaving a row showing a state the server never
  /// accepted. That last part matters more here than on a notification
  /// preference — a privacy control that displays a setting the server did not
  /// store is worse than one that fails loudly, because the user would believe
  /// they were hidden.
  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Something went wrong: $error'), behavior: SnackBarBehavior.floating),
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a tier row says while it has no tier: still loading, or it did not
  /// load. Never a tier — a privacy row must not guess, and "Everyone" is the
  /// worst possible guess to render under a heading someone opened to check.
  String get _pending => _loadFailed ? 'Did not load' : '…';

  void _comingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Coming soon'), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _section('PRIVACY'),
          _card([
            // Still unwired, and deliberately so: there is no column behind it
            // yet. It is also the reason the profile header has no "parties
            // this year" tile — until this setting exists, the rsvps policy IS the
            // answer to "who sees where I go", and get_profile_stats does not
            // invent a different one.
            _settingsRow(
              'Who sees which parties I go to',
              'Coming soon',
              chevron: true,
              onTap: _comingSoon,
            ),
            _divider(),
            // Was a two-state switch on MpStore.mapVisible, which no server
            // ever read. Now three tiers on profiles.map_visibility, enforced
            // inside get_parties_near_user.
            _settingsRow(
              'Who sees my parties on the map',
              _privacy?.mapVisibility.label ?? _pending,
              chevron: true,
              onTap: _privacy == null ? null : _pickMapVisibility,
            ),
            _divider(),
            _settingsRow(
              'Who can invite me',
              _privacy?.invitePolicy.label ?? _pending,
              chevron: true,
              onTap: _privacy == null ? null : _pickInvitePolicy,
            ),
          ]),
          _note(
            'Private parties you go to are never visible to people who are not '
            'invited — not even on your profile.',
          ),

          const SizedBox(height: 22),
          _section('NOTIFICATIONS'),
          _card([
            _settingsRow(
              'Notifications & location',
              'Parties near you, quiet hours, distance',
              chevron: true,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const NotificationSettingsScreen())),
            ),
          ]),

          const SizedBox(height: 22),
          // App Store Review Guideline 5.1.1(v) requires an in-app deletion
          // path wherever an account can be created, and requires it to
          // actually start the deletion rather than link to support. Kept
          // directly above sign-out, which is where a user looks for it.
          _section('ACCOUNT'),
          _card([
            _settingsRow(
              'Data & deletion',
              'Export your data, delete your account',
              chevron: true,
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const AccountDeletionScreen())),
            ),
          ]),

          const SizedBox(height: 22),
          GestureDetector(
            onTap: () => AuthService().signOut(),
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                color: Colors.white.withValues(alpha: 0.035),
                border: Border.all(color: AppColors.hairline),
              ),
              child: Center(
                child: Text(
                  'Sign out',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textAlpha(0.6)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 9),
    child: Text(label, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
  );

  Widget _card(List<Widget> children) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(15),
      color: Colors.white.withValues(alpha: 0.035),
      border: Border.all(color: AppColors.hairline),
    ),
    child: Column(children: children),
  );

  Widget _divider() => Container(height: 1, color: AppColors.hairline);

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
    ),
  );

  Widget _settingsRow(String title, String sub, {bool chevron = false, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 11, color: AppColors.textAlpha(0.45))),
                ],
              ),
            ),
            if (chevron) Icon(Icons.chevron_right, size: 18, color: AppColors.textAlpha(0.35)),
          ],
        ),
      ),
    );
  }

  /// A switch cannot express three tiers, and squeezing map_visibility into one
  /// would have to drop a tier or overload it. A sheet also gives each option
  /// room for the sentence that says what it actually does — which is the
  /// difference between a control someone sets correctly and one they guess at.
  Future<void> _pickMapVisibility() async {
    final chosen = await _pickTier<MapVisibility>(
      title: 'Who sees my parties on the map',
      options: MapVisibility.values,
      current: _privacy!.mapVisibility,
      labelOf: (v) => v.label,
      explanationOf: (v) => v.explanation,
      // The one thing the tiers do NOT do, stated where the choice is made:
      // people already tied to a specific party keep seeing it at every tier.
      footnote:
          'People holding an invitation, and people who have already RSVPd, '
          'keep seeing that particular party.',
    );
    if (chosen == null || chosen == _privacy!.mapVisibility) return;
    await _mutate(() => _profiles.updatePrivacy(mapVisibility: chosen));
  }

  Future<void> _pickInvitePolicy() async {
    final chosen = await _pickTier<InvitePolicy>(
      title: 'Who can invite me',
      options: InvitePolicy.values,
      current: _privacy!.invitePolicy,
      labelOf: (v) => v.label,
      explanationOf: (v) => v.explanation,
    );
    if (chosen == null || chosen == _privacy!.invitePolicy) return;
    await _mutate(() => _profiles.updatePrivacy(invitePolicy: chosen));
  }

  Future<T?> _pickTier<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) labelOf,
    required String Function(T) explanationOf,
    String? footnote,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.sheet,
      // Both are needed, and neither is cosmetic. A default modal sheet is
      // capped at 9/16 of the screen, which three tiers plus their explanations
      // and the footnote overflow on a short handset — and an overflowing sheet
      // clips the last option rather than scrolling to it, so a tier would
      // simply be unreachable. isScrollControlled lifts the cap;
      // SingleChildScrollView covers the rest (large text scale, small screen).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              for (final option in options)
                InkWell(
                  onTap: () => Navigator.of(sheetContext).pop(option),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                labelOf(option),
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                explanationOf(option),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: AppColors.textAlpha(0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (option == current)
                          const Padding(
                            padding: EdgeInsets.only(left: 10, top: 2),
                            child: Icon(Icons.check, size: 18, color: AppColors.pinkLight),
                          ),
                      ],
                    ),
                  ),
                ),
              if (footnote != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    footnote,
                    style: TextStyle(fontSize: 11, height: 1.5, color: AppColors.textAlpha(0.38)),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
