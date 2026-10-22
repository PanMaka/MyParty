import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/profile_repository.dart';
import '../../data/social_repository.dart';
import '../../models/gender.dart';
import '../../models/profile_privacy.dart';
import '../../services/auth_service.dart';
import '../../utils/auth_messages.dart';
import '../../utils/app_info.dart';
import '../theme/app_theme.dart';
import 'account_deletion_screen.dart';
import 'blocked_accounts_screen.dart';
import 'change_email_screen.dart';
import 'change_password_screen.dart';
import 'notification_settings_screen.dart';
import 'profile_edit_screen.dart';

Future<bool> _launchExternally(Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);

/// The owner's controls, behind the gear in the profile header.
///
/// Five sections since Phase 43, in the order someone looks for them: ACCOUNT
/// (who you are signed in as, your data, deletion), PROFILE (what other people
/// see of you), PRIVACY & SAFETY (who may reach you), NOTIFICATIONS and
/// SUPPORT & LEGAL. Sign out sits below all of them.
///
/// The grouping is still not cosmetic. Location consent stays on the
/// notifications screen, under NOTIFICATIONS here, rather than moving to
/// PRIVACY & SAFETY: that screen puts the two consents first and the
/// preferences they gate below them, dimmed while either is off. Moving the
/// location switch here would leave dimmed sliders there with the switch that
/// enables them one screen away, which breaks the consent-before-preferences
/// order the engine reads them in.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.repository,
    this.social,
    this.auth,
    this.appVersion = platformAppVersion,
    this.openUrl = _launchExternally,
  });

  /// Injectable so widget tests can subclass [ProfileRepository] without a
  /// Supabase client ever existing, the same way `ProfileScreen` does.
  final ProfileRepository? repository;

  /// Handed to [BlockedAccountsScreen]; injectable for the same reason.
  final SocialRepository? social;

  /// The email row and sign-out. Injectable for the same reason.
  final AuthService? auth;

  final AppVersion appVersion;

  /// Opens the support mailto. Returns false when nothing on the phone can
  /// handle it, which is common on a handset with no mail app set up.
  final Future<bool> Function(Uri uri) openUrl;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final ProfileRepository _profiles = widget.repository ?? ProfileRepository();
  late final AuthService _auth = widget.auth ?? AuthService();

  /// Read synchronously from the session on every build, because Change
  /// email changes it. Null (no session, or no Supabase under `flutter test`)
  /// shows a dash rather than an error.
  String? _sessionValue(String? Function() read) {
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  String? get _email => _sessionValue(() => _auth.currentEmail);
  String? get _pendingEmail => _sessionValue(() => _auth.pendingNewEmail);

  /// "1.0.0 (1)". Null until the platform answers, or if it never does.
  String? _version;

  ProfilePrivacy? _privacy;
  bool _busy = false;

  /// The user's own gender answer, from `user_genders`. Loaded and failed
  /// separately from the tiers: it is a different table, and a gender read
  /// that failed must not take the privacy rows down with it.
  Gender? _gender;
  bool _genderLoadFailed = false;

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
    _loadVersion();
  }

  /// Self-only by construction: `fetchPrivacy` takes no user id and reads the
  /// caller's own row. This screen is reachable from the owner's profile alone,
  /// which is what keeps that true.
  Future<void> _load() async {
    await Future.wait([_loadPrivacy(), _loadGender()]);
  }

  Future<void> _loadPrivacy() async {
    try {
      final privacy = await _profiles.fetchPrivacy();
      if (mounted) setState(() => _privacy = privacy);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _loadGender() async {
    try {
      final gender = await _profiles.fetchMyGender();
      if (mounted) setState(() => _gender = gender);
    } catch (_) {
      if (mounted) setState(() => _genderLoadFailed = true);
    }
  }

  Future<void> _loadVersion() async {
    try {
      final version = await widget.appVersion();
      if (mounted) setState(() => _version = version);
    } catch (_) {
      // Left as a dash. A version that will not load is not worth an error.
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
      if (mounted) _snack('Something went wrong: $error');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a tier row says while it has no tier: still loading, or it did not
  /// load. Never a tier — a privacy row must not guess, and "Everyone" is the
  /// worst possible guess to render under a heading someone opened to check.
  String get _pending => _loadFailed ? 'Did not load' : '…';

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _changeEmail() async {
    final changedTo = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ChangeEmailScreen(auth: _auth)),
    );
    if (!mounted) return;
    // Rebuilt either way: a change left pending is shown on the row too.
    setState(() {});
    if (changedTo != null) _snack(emailChangedMessage(changedTo));
  }

  /// The snackbar is shown here rather than by the screen, which has already
  /// popped by the time there is anything to say.
  Future<void> _changePassword() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ChangePasswordScreen(auth: _auth)),
    );
    if (changed == true && mounted) _snack(passwordChangedMessage);
  }

  /// A confirmation, because the row sits at the bottom of a scrolling list
  /// where a stray tap is easy, and signing back in means retyping a password.
  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.sheet,
        title: const Text('Sign out?'),
        content: const Text('You can sign back in with your email and password.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _auth.signOut();
    } catch (error) {
      if (mounted) _snack('Could not sign out: $error');
    }
  }

  Future<void> _contactSupport() async {
    bool opened;
    try {
      opened = await widget.openUrl(supportMailUri(appVersion: _version));
    } catch (_) {
      opened = false;
    }
    // No mail app is an ordinary state, not an error: say where to write.
    if (!opened && mounted) _snack('No email app found. Write to us at $supportEmail');
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
          // App Store Review Guideline 5.1.1(v) requires an in-app deletion
          // path wherever an account can be created, and requires it to
          // actually start the deletion rather than link to support.
          _section('ACCOUNT'),
          _card([
            _settingsRow(
              'Email',
              _pendingEmail == null ? (_email ?? '—') : '${_email ?? '—'} → $_pendingEmail (waiting for confirmation)',
              chevron: true,
              onTap: _email == null ? null : _changeEmail,
            ),
            _divider(),
            _settingsRow('Password', 'Change your password', chevron: true, onTap: _changePassword),
            _divider(),
            _settingsRow(
              'Data & deletion',
              'Export your data, delete your account',
              chevron: true,
              onTap: () => _push(const AccountDeletionScreen()),
            ),
          ]),

          const SizedBox(height: 22),
          _section('PROFILE'),
          _card([
            _settingsRow(
              'Edit profile',
              'Photo and bio',
              chevron: true,
              onTap: () => _push(ProfileEditScreen(repository: widget.repository)),
            ),
            _divider(),
            _settingsRow(
              'Gender',
              _gender?.label ?? (_genderLoadFailed ? 'Did not load' : '…'),
              chevron: true,
              onTap: _gender == null ? null : _pickGender,
            ),
          ]),
          // Directly under the card, whose last row is the one it is about.
          _note(genderVisibilityNote),

          const SizedBox(height: 22),
          _section('PRIVACY & SAFETY'),
          _card([
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
            _divider(),
            _settingsRow(
              'Who can message me',
              _privacy?.dmPolicy.label ?? _pending,
              chevron: true,
              onTap: _privacy == null ? null : _pickDmPolicy,
            ),
            _divider(),
            // Enforced in get_follow_suggestions, which reads this owner-only
            // column for every candidate. Says what it does and no more: it
            // takes you out of People you may know, not out of search.
            _switchRow(
              'Suggest my account to others',
              'Shows you in People you may know. People can still find you by searching.',
              value: _privacy?.suggestAccount,
              onChanged: (v) => _mutate(() => _profiles.updatePrivacy(suggestAccount: v)),
            ),
            _divider(),
            _settingsRow(
              'Blocked accounts',
              'People you have blocked',
              chevron: true,
              onTap: () => _push(BlockedAccountsScreen(social: widget.social)),
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
              onTap: () => _push(const NotificationSettingsScreen()),
            ),
          ]),

          const SizedBox(height: 22),
          // No privacy policy or terms rows yet: there is no document to link
          // to (docs/backlog.md 1.30), and a row that leads nowhere is the
          // "Coming soon" this phase removed.
          _section('SUPPORT & LEGAL'),
          _card([
            _settingsRow('Contact support', supportEmail, chevron: true, onTap: _contactSupport),
            _divider(),
            _settingsRow(
              'Open-source licences',
              'The software MyParty is built with',
              chevron: true,
              onTap: () => showLicensePage(context: context, applicationName: 'MyParty', applicationVersion: _version),
            ),
            _divider(),
            _settingsRow('App version', _version ?? '—'),
          ]),

          const SizedBox(height: 22),
          InkWell(
            onTap: _confirmSignOut,
            borderRadius: BorderRadius.circular(15),
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

  /// A row with a switch. A null [value] is the loading or failed state: the
  /// switch is shown off and disabled rather than guessing, the same rule as
  /// [_pending] for the tier rows.
  Widget _switchRow(String title, String sub, {required bool? value, required ValueChanged<bool> onChanged}) {
    return Padding(
      padding: const EdgeInsets.all(13),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  value == null ? _pending : sub,
                  style: TextStyle(fontSize: 11, height: 1.4, color: AppColors.textAlpha(0.45)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(
            value: value ?? false,
            onChanged: value == null || _busy ? null : onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.purpleDeep,
          ),
        ],
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

  Future<void> _pickDmPolicy() async {
    final chosen = await _pickTier<DmPolicy>(
      title: 'Who can message me',
      options: DmPolicy.values,
      current: _privacy!.dmPolicy,
      labelOf: (v) => v.label,
      explanationOf: (v) => v.explanation,
      // The two things the tiers do NOT do, stated where the choice is made.
      footnote:
          'Conversations the other person has already replied in stay open. '
          'Blocking someone always stops them, whatever this is set to.',
    );
    if (chosen == null || chosen == _privacy!.dmPolicy) return;
    await _mutate(() => _profiles.updatePrivacy(dmPolicy: chosen));
  }

  /// "Prefer not to say" is an answer here, not a missing one: it clears the
  /// stored row, and takes the user out of every host's counts.
  Future<void> _pickGender() async {
    final chosen = await _pickTier<Gender>(
      title: 'Gender',
      options: Gender.values,
      current: _gender!,
      labelOf: (g) => g.label,
      footnote: genderVisibilityNote,
    );
    if (chosen == null || chosen == _gender) return;
    await _mutate(() => _profiles.setGender(chosen));
  }

  Future<T?> _pickTier<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) labelOf,
    String Function(T)? explanationOf,
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
                              if (explanationOf != null) ...[
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
