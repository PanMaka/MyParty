import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/auth_messages.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_branding.dart';
import '../widgets/resend_button.dart';

/// Sign-up confirmation (Phase 47): the 8-digit code from the sign-up email.
///
/// Reached from Register right after `signUp` (which, with confirmation on,
/// answers with no session), and from Login when the password was right but the
/// address was never confirmed ([sendOnOpen]: that path had no fresh email).
/// A correct code signs in: `AuthGate`, underneath, swaps Login for the
/// signed-in flow, and this route pops back down to it.
class ConfirmEmailScreen extends StatefulWidget {
  const ConfirmEmailScreen({super.key, required this.email, this.authService, this.sendOnOpen = false});

  final String email;
  final AuthService? authService;

  /// Send a fresh code as the screen opens. Login's path: the earlier code may
  /// be long gone, and a resend replaces it anyway (measured).
  final bool sendOnOpen;

  @override
  State<ConfirmEmailScreen> createState() => _ConfirmEmailScreenState();
}

class _ConfirmEmailScreenState extends State<ConfirmEmailScreen> {
  late final AuthService _auth = widget.authService ?? AuthService();
  final _code = TextEditingController();
  String? _codeError;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The message is already on screen when it fails; the rethrow is only for
    // ResendButton.
    if (widget.sendOnOpen) _resend().catchError((Object _) {});
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.length != 8) {
      setState(() => _codeError = codeLengthMessage);
      return;
    }
    setState(() {
      _busy = true;
      _codeError = null;
      _error = null;
    });
    try {
      await _auth.confirmSignUp(email: widget.email, code: code);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    } on CodeException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.failure == CodeFailure.wrongOrExpired) {
          _codeError = codeWrongOrExpiredMessage;
        } else {
          _error = tooManyAttemptsMessage;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Rethrows so [ResendButton] does not start its cooldown for a send that
  /// failed.
  Future<void> _resend() async {
    try {
      await _auth.resendSignUpCode(widget.email);
      if (mounted) {
        setState(() {
          _error = null;
          _codeError = null;
        });
      }
    } on CodeException {
      if (mounted) setState(() => _error = tooManyAttemptsMessage);
      rethrow;
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(confirmEmailTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
        child: Column(
          children: [
            const AuthHeader(caption: confirmEmailTitle),
            const SizedBox(height: 32),
            AuthFieldsBox(
              children: [
                const SizedBox(height: 12),
                Text(
                  codeSentTo(widget.email),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textAlpha(0.75), height: 1.4),
                ),
                const SizedBox(height: 8),
                AuthCodeField(
                  controller: _code,
                  errorText: _codeError,
                  onChanged: (_) {
                    if (_codeError != null || _error != null) {
                      setState(() {
                        _codeError = null;
                        _error = null;
                      });
                    }
                  },
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(_error!, textAlign: TextAlign.center, style: authErrorStyle),
              ),
            const SizedBox(height: 24),
            _busy
                ? const CircularProgressIndicator()
                : ElevatedButton(onPressed: _confirm, child: const Text('Confirm')),
            ResendButton(onResend: _resend),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Wrong email? Go back'),
            ),
          ],
        ),
      ),
    );
  }
}
