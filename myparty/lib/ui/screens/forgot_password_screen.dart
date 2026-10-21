import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/auth_messages.dart';
import '../../utils/password.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_branding.dart';
import '../widgets/resend_button.dart';
import 'change_password_screen.dart' show passwordChangedMessage, passwordsDontMatchMessage, samePasswordMessage;

enum _Step { email, code, newPassword }

/// Login → "Forgot password?" (Phase 47). Three steps on one screen:
///
///  1. the email. The answer is the same sentence whether or not it has an
///     account, as GoTrue's is;
///  2. the 8-digit code, the main path, which works on any phone and after a
///     mail scanner has spent the link. A correct code signs in with a
///     recovery session;
///  3. the new password, under the register form's rules.
///
/// A reset LINK skips to step 3: `AuthLinkHandler` exchanges it (only on the
/// phone that asked) and opens this screen with [startAtNewPassword].
///
/// Leaving step 3 any way but by setting the password signs out: the recovery
/// session is a real one, and nobody asked to be signed in by it.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.authService, this.initialEmail = '', this.startAtNewPassword = false});

  final AuthService? authService;
  final String initialEmail;
  final bool startAtNewPassword;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final AuthService _auth = widget.authService ?? AuthService();
  late _Step _step = widget.startAtNewPassword ? _Step.newPassword : _Step.email;

  late final _email = TextEditingController(text: widget.initialEmail);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  String? _emailError;
  String? _codeError;
  String? _passwordError;
  String? _confirmError;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _clearErrors() {
    if (_emailError == null && _codeError == null && _passwordError == null && _confirmError == null && _error == null) {
      return;
    }
    setState(() {
      _emailError = null;
      _codeError = null;
      _passwordError = null;
      _confirmError = null;
      _error = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on CodeException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.failure == CodeFailure.wrongOrExpired) {
          _codeError = codeWrongOrExpiredMessage;
        } else {
          _error = tooManyAttemptsMessage;
        }
      });
    } on PasswordChangeException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.failure) {
          case PasswordChangeFailure.samePassword:
            _passwordError = samePasswordMessage;
          case PasswordChangeFailure.weakPassword:
            _passwordError = passwordTooShortMessage;
          case PasswordChangeFailure.rateLimited:
            _error = tooManyAttemptsMessage;
          case PasswordChangeFailure.wrongCurrentPassword || PasswordChangeFailure.notSignedIn:
            _error = somethingWentWrongMessage;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!looksLikeEmail(email)) {
      setState(() => _emailError = invalidEmailMessage);
      return;
    }
    await _run(() async {
      await _auth.requestPasswordReset(email);
      if (mounted) setState(() => _step = _Step.code);
    });
  }

  Future<void> _resend() async {
    try {
      await _auth.requestPasswordReset(_email.text.trim());
      if (mounted) setState(() => _codeError = null);
    } on CodeException {
      if (mounted) setState(() => _error = tooManyAttemptsMessage);
      rethrow;
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
      rethrow;
    }
  }

  Future<void> _verifyCode() async {
    final code = _code.text.trim();
    if (code.length != 8) {
      setState(() => _codeError = codeLengthMessage);
      return;
    }
    await _run(() async {
      await _auth.verifyResetCode(email: _email.text.trim(), code: code);
      if (mounted) setState(() => _step = _Step.newPassword);
    });
  }

  Future<void> _setPassword() async {
    final password = _password.text;
    final passwordProblem = passwordError(password);
    final confirmProblem = _confirm.text == password ? null : passwordsDontMatchMessage;
    if (passwordProblem != null || confirmProblem != null) {
      setState(() {
        _passwordError = passwordProblem;
        _confirmError = confirmProblem;
      });
      return;
    }
    await _run(() async {
      await _auth.setNewPassword(password);
      if (!mounted) return;
      // The root messenger outlives this route, so the snackbar survives the pop.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).popUntil((route) => route.isFirst);
      messenger.showSnackBar(const SnackBar(content: Text(passwordChangedMessage)));
    });
  }

  /// Back from step 3 ends the recovery session. AuthGate pops every route on
  /// sign-out, this one included; the pop here covers a host without it.
  Future<void> _abandon() async {
    try {
      await _auth.abandonPasswordReset();
    } catch (_) {
      // Signed out locally regardless: AuthService.signOut clears the session
      // even when the server call fails.
    }
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step != _Step.newPassword,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _abandon();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_step == _Step.newPassword ? newPasswordTitle : forgotPasswordTitle)),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
          child: Column(
            children: [
              AuthHeader(caption: _step == _Step.newPassword ? newPasswordTitle : forgotPasswordTitle),
              const SizedBox(height: 32),
              ...switch (_step) {
                _Step.email => _emailStep(),
                _Step.code => _codeStep(),
                _Step.newPassword => _passwordStep(),
              },
            ],
          ),
        ),
      ),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: AppColors.textAlpha(0.75), height: 1.4)),
      );

  Widget _errorLine() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(_error!, textAlign: TextAlign.center, style: authErrorStyle),
        );

  Widget _button(String label, VoidCallback onPressed) =>
      _busy ? const CircularProgressIndicator() : ElevatedButton(onPressed: onPressed, child: Text(label));

  List<Widget> _emailStep() => [
        AuthFieldsBox(
          children: [
            TextField(
              controller: _email,
              style: const TextStyle(color: Colors.white),
              cursorColor: Colors.white,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              onChanged: (_) => _clearErrors(),
              decoration: InputDecoration(
                labelText: 'Email',
                labelStyle: const TextStyle(color: Colors.white70),
                focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
                errorText: _emailError,
                errorStyle: authErrorStyle,
                errorBorder: authErrorUnderline,
                focusedErrorBorder: authErrorUnderline,
              ),
            ),
          ],
        ),
        _errorLine(),
        const SizedBox(height: 24),
        _button('Send code', _sendCode),
      ];

  List<Widget> _codeStep() => [
        AuthFieldsBox(
          children: [
            _note(resetCodeSentTo(_email.text.trim())),
            const SizedBox(height: 4),
            AuthCodeField(controller: _code, errorText: _codeError, onChanged: (_) => _clearErrors()),
          ],
        ),
        _note(resetLinkHint),
        _errorLine(),
        const SizedBox(height: 24),
        _button('Continue', _verifyCode),
        ResendButton(onResend: _resend),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _step = _Step.email;
                    _code.clear();
                    _clearErrors();
                  }),
          child: const Text('Use a different email'),
        ),
      ];

  List<Widget> _passwordStep() => [
        AuthFieldsBox(
          children: [
            AuthPasswordField(
              controller: _password,
              label: 'New password',
              errorText: _passwordError,
              onChanged: (_) => _clearErrors(),
            ),
            const SizedBox(height: 16),
            AuthPasswordField(
              controller: _confirm,
              label: 'Confirm new password',
              errorText: _confirmError,
              onChanged: (_) => _clearErrors(),
            ),
          ],
        ),
        _note('At least $minimumPasswordLength characters: letters, numbers and punctuation, no spaces, '
            'and no runs like "123". Your other devices will be signed out.'),
        _errorLine(),
        const SizedBox(height: 24),
        _button('Set password', _setPassword),
        TextButton(onPressed: _busy ? null : _abandon, child: const Text('Cancel')),
      ];
}
