import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/password.dart';
import '../theme/app_theme.dart';

const wrongCurrentPasswordMessage = "That isn't your current password";
const samePasswordMessage = 'The new password must be different from your current one';
const passwordsDontMatchMessage = "The passwords don't match";
const passwordChangeRateLimitedMessage = 'Too many attempts. Wait a few minutes and try again.';
const passwordChangeFailedMessage = "Couldn't change your password. Check your connection and try again.";
const passwordChangedMessage = 'Password changed. Your other devices have been signed out.';

const changePasswordSubmitKey = Key('change-password-submit');

/// Settings → Account → Password.
///
/// The current password, then the new one twice. The new one is held to the
/// register form's rules ([passwordError]) before anything is sent, so the
/// server's refusals that remain are the ones only it can know: the current
/// password is wrong, or the new one is the old one. Each lands under the field
/// it is about. Pops with `true` on success; the caller shows the snackbar,
/// because this route is gone by then.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key, this.auth});

  /// Injectable so widget tests can override the two network halves of
  /// [AuthService.changePassword] without a Supabase client.
  final AuthService? auth;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  late final AuthService _auth = widget.auth ?? AuthService();

  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  String? _currentError;
  String? _nextError;
  String? _confirmError;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _filled => _current.text.isNotEmpty && _next.text.isNotEmpty && _confirm.text.isNotEmpty;

  void _clearErrors() => setState(() {
        _currentError = null;
        _nextError = null;
        _confirmError = null;
        _error = null;
      });

  Future<void> _save() async {
    // Not trimmed, unlike the login form: a password is exactly what was
    // typed, and the register form stores it untrimmed.
    final current = _current.text;
    final next = _next.text;

    final nextError = passwordError(next) ?? (next == current ? samePasswordMessage : null);
    final confirmError = _confirm.text == next ? null : passwordsDontMatchMessage;
    if (nextError != null || confirmError != null) {
      setState(() {
        _nextError = nextError;
        _confirmError = confirmError;
      });
      return;
    }

    setState(() => _saving = true);
    try {
      await _auth.changePassword(currentPassword: current, newPassword: next);
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on PasswordChangeException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.failure) {
          case PasswordChangeFailure.wrongCurrentPassword:
            _currentError = wrongCurrentPasswordMessage;
          case PasswordChangeFailure.samePassword:
            _nextError = samePasswordMessage;
          case PasswordChangeFailure.weakPassword:
            // The server's minimum_password_length, should it ever outrun ours.
            _nextError = passwordTooShortMessage;
          case PasswordChangeFailure.rateLimited:
            _error = passwordChangeRateLimitedMessage;
          case PasswordChangeFailure.notSignedIn:
            _error = passwordChangeFailedMessage;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = passwordChangeFailedMessage);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Change password',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _sectionLabel('CURRENT PASSWORD'),
          SettingsPasswordInput(
            controller: _current,
            hint: 'Current password',
            enabled: !_saving,
            error: _currentError,
            onChanged: (_) => _clearErrors(),
          ),
          if (_currentError != null) _caption(_currentError!, color: AppColors.pinkLight),
          const SizedBox(height: 22),
          _sectionLabel('NEW PASSWORD'),
          SettingsPasswordInput(
            controller: _next,
            hint: 'New password',
            enabled: !_saving,
            error: _nextError,
            onChanged: (_) => _clearErrors(),
          ),
          if (_nextError != null) _caption(_nextError!, color: AppColors.pinkLight),
          _caption(
            'At least $minimumPasswordLength characters: letters, numbers and punctuation, '
            'no spaces, and no runs like "123".',
          ),
          const SizedBox(height: 12),
          SettingsPasswordInput(
            controller: _confirm,
            hint: 'Confirm new password',
            enabled: !_saving,
            error: _confirmError,
            onChanged: (_) => _clearErrors(),
          ),
          if (_confirmError != null) _caption(_confirmError!, color: AppColors.pinkLight),
          const SizedBox(height: 22),
          _caption("You'll stay signed in here. Your other devices will be signed out."),
          const SizedBox(height: 14),
          _saveButton(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.pinkLight),
              ),
            ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    final enabled = _filled && !_saving;
    return GestureDetector(
      // The label is also the app bar's title, so tests find the button by key.
      key: changePasswordSubmitKey,
      onTap: enabled ? _save : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: enabled ? AppColors.purpleGradient : null,
          color: enabled ? null : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(13),
        ),
        child: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(
                'Change password',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: enabled ? AppColors.text : AppColors.textAlpha(0.3),
                ),
              ),
      ),
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
}

/// A password field in the Settings style (Edit profile's outlined input),
/// with its own show/hide toggle. [AuthPasswordField] is the auth screens'
/// white-on-gradient version and labels itself "Password", so it cannot say
/// which of the three this is.
class SettingsPasswordInput extends StatefulWidget {
  const SettingsPasswordInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.enabled,
    required this.onChanged,
    this.error,
  });

  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  State<SettingsPasswordInput> createState() => _SettingsPasswordInputState();
}

class _SettingsPasswordInputState extends State<SettingsPasswordInput> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final error = widget.error != null;
    final idle = error ? AppColors.pink : AppColors.hairline;
    final focused = error ? AppColors.pink : AppColors.purple;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      maxLines: 1,
      onChanged: widget.onChanged,
      style: const TextStyle(fontSize: 14.5),
      decoration: InputDecoration(
        hintText: widget.hint,
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
          borderSide: BorderSide(color: idle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: focused),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: AppColors.textAlpha(0.5),
          ),
          tooltip: _obscured ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}
