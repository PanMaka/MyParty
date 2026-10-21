import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/auth_service.dart';
import '../../utils/auth_messages.dart';
import '../theme/app_theme.dart';
import '../widgets/resend_button.dart';
import 'change_password_screen.dart' show SettingsPasswordInput, wrongCurrentPasswordMessage;

/// Settings → Account → Email (Phase 47).
///
/// Two states. The FORM takes the new address and the current password, and
/// sends a code (and a link) to each address. The PENDING view takes the two
/// codes; nothing changes until both are in. That double confirmation is what
/// stops a stolen session taking the account, and GoTrue enforces it only
/// because sign-up confirmation is on (measured).
///
/// Opened while a change is already pending (`AuthService.pendingNewEmail`), it
/// starts in the pending view. Which address is already confirmed is not
/// something GoTrue tells the client, so that is remembered only while this
/// screen is open. Pops with the new address once the change is complete.
class ChangeEmailScreen extends StatefulWidget {
  const ChangeEmailScreen({super.key, this.auth});

  final AuthService? auth;

  @override
  State<ChangeEmailScreen> createState() => _ChangeEmailScreenState();
}

class _ChangeEmailScreenState extends State<ChangeEmailScreen> {
  late final AuthService _auth = widget.auth ?? AuthService();

  late final String _current = _auth.currentEmail ?? '';
  late String? _pending = _auth.pendingNewEmail;

  final _newEmail = TextEditingController();
  final _password = TextEditingController();
  final _oldCode = TextEditingController();
  final _newCode = TextEditingController();

  String? _emailError;
  String? _passwordError;
  String? _oldCodeError;
  String? _newCodeError;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _oldConfirmed = false;
  bool _newConfirmed = false;

  @override
  void dispose() {
    _newEmail.dispose();
    _password.dispose();
    _oldCode.dispose();
    _newCode.dispose();
    super.dispose();
  }

  void _clearErrors() => setState(() {
        _emailError = null;
        _passwordError = null;
        _oldCodeError = null;
        _newCodeError = null;
        _error = null;
      });

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final next = _newEmail.text.trim();
    try {
      await _auth.requestEmailChange(newEmail: next, currentPassword: _password.text);
      if (!mounted) return;
      setState(() {
        _pending = next;
        _oldConfirmed = false;
        _newConfirmed = false;
        _notice = emailChangeCodesSent(_current, next);
        _password.clear();
      });
    } on EmailChangeException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.failure) {
          case EmailChangeFailure.wrongCurrentPassword:
            _passwordError = wrongCurrentPasswordMessage;
          case EmailChangeFailure.sameEmail:
            _emailError = sameEmailMessage;
          case EmailChangeFailure.invalidEmail:
            _emailError = invalidEmailMessage;
          case EmailChangeFailure.emailTaken:
            _emailError = emailTakenByOtherMessage;
          case EmailChangeFailure.rateLimited:
            _error = tooManyAttemptsMessage;
          case EmailChangeFailure.notSignedIn:
            _error = somethingWentWrongMessage;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// New codes to both addresses; the old ones stop working, and with them
  /// any confirmation already given, so both rows open again.
  Future<void> _resend() async {
    final pending = _pending;
    if (pending == null) return;
    try {
      await _auth.resendEmailChange(pending);
      if (!mounted) return;
      setState(() {
        _oldConfirmed = false;
        _newConfirmed = false;
        _oldCode.clear();
        _newCode.clear();
        _oldCodeError = null;
        _newCodeError = null;
        _error = null;
        _notice = emailChangeCodesSent(_current, pending);
      });
    } on EmailChangeException {
      if (mounted) setState(() => _error = tooManyAttemptsMessage);
      rethrow;
    } catch (_) {
      if (mounted) setState(() => _error = somethingWentWrongMessage);
      rethrow;
    }
  }

  Future<void> _confirm({required bool oldAddress}) async {
    final controller = oldAddress ? _oldCode : _newCode;
    final address = oldAddress ? _current : _pending!;
    final code = controller.text.trim();
    void setCodeError(String? message) => oldAddress ? _oldCodeError = message : _newCodeError = message;

    if (code.length != 8) {
      setState(() => setCodeError(codeLengthMessage));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final progress = await _auth.confirmEmailChange(address: address, code: code);
      if (!mounted) return;
      if (progress == EmailChangeProgress.completed) {
        Navigator.of(context).pop(_pending);
        return;
      }
      setState(() {
        if (oldAddress) {
          _oldConfirmed = true;
        } else {
          _newConfirmed = true;
        }
        _notice = emailChangeWaitingMessage;
      });
    } on CodeException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.failure == CodeFailure.wrongOrExpired) {
          setCodeError('$codeWrongOrExpiredMessage $emailChangeConfirmedHint');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Change email',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          _sectionLabel('CURRENT EMAIL'),
          Text(_current, style: const TextStyle(fontSize: 14.5)),
          const SizedBox(height: 22),
          if (_pending == null) ..._form() else ..._pendingView(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.pinkLight)),
            ),
        ],
      ),
    );
  }

  List<Widget> _form() => [
        _sectionLabel('NEW EMAIL'),
        TextField(
          key: changeEmailAddressKey,
          controller: _newEmail,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => _clearErrors(),
          style: const TextStyle(fontSize: 14.5),
          decoration: _decoration(hint: 'New email', error: _emailError != null),
        ),
        if (_emailError != null) _caption(_emailError!, color: AppColors.pinkLight),
        const SizedBox(height: 22),
        _sectionLabel('CURRENT PASSWORD'),
        SettingsPasswordInput(
          key: changeEmailPasswordKey,
          controller: _password,
          hint: 'Current password',
          enabled: !_busy,
          error: _passwordError,
          onChanged: (_) => _clearErrors(),
        ),
        if (_passwordError != null) _caption(_passwordError!, color: AppColors.pinkLight),
        const SizedBox(height: 22),
        _caption('We send a code to your current address and to the new one. '
            'The change happens only once both are confirmed.'),
        const SizedBox(height: 14),
        _primaryButton(
          'Send codes',
          _newEmail.text.trim().isNotEmpty && _password.text.isNotEmpty && !_busy ? _send : null,
          key: changeEmailSendKey,
        ),
      ];

  List<Widget> _pendingView() => [
        _sectionLabel('CHANGING TO'),
        Text(_pending!, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
        if (_notice != null) _caption(_notice!),
        const SizedBox(height: 22),
        _codeRow(oldAddress: true),
        const SizedBox(height: 18),
        _codeRow(oldAddress: false),
        const SizedBox(height: 14),
        Row(
          children: [
            ResendButton(onResend: _resend, label: 'Send new codes', color: AppColors.purpleLight),
            const Spacer(),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        // A new request replaces this one (measured): nothing
                        // needs cancelling first.
                        _pending = null;
                        _notice = null;
                        _oldCode.clear();
                        _newCode.clear();
                        _clearErrors();
                      }),
              child: Text('Use a different address', style: TextStyle(color: AppColors.textAlpha(0.6))),
            ),
          ],
        ),
      ];

  Widget _codeRow({required bool oldAddress}) {
    final confirmed = oldAddress ? _oldConfirmed : _newConfirmed;
    final address = oldAddress ? _current : _pending!;
    final error = oldAddress ? _oldCodeError : _newCodeError;
    final controller = oldAddress ? _oldCode : _newCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(oldAddress ? 'CODE SENT TO YOUR CURRENT EMAIL' : 'CODE SENT TO THE NEW EMAIL'),
        _caption(address),
        const SizedBox(height: 8),
        if (confirmed)
          Row(
            children: [
              const Icon(Icons.check_circle, size: 18, color: AppColors.purpleLight),
              const SizedBox(width: 8),
              Text('Confirmed', style: TextStyle(fontSize: 13.5, color: AppColors.textAlpha(0.8))),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: oldAddress ? oldEmailCodeKey : newEmailCodeKey,
                  controller: controller,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
                  onChanged: (_) => _clearErrors(),
                  style: const TextStyle(fontSize: 17, letterSpacing: 4, fontWeight: FontWeight.w700),
                  decoration: _decoration(hint: '8-digit code', error: error != null),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: _primaryButton(
                  'Confirm',
                  _busy ? null : () => _confirm(oldAddress: oldAddress),
                  key: oldAddress ? confirmOldEmailKey : confirmNewEmailKey,
                ),
              ),
            ],
          ),
        if (error != null) _caption(error, color: AppColors.pinkLight),
      ],
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap, {Key? key}) {
    final enabled = onTap != null;
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: enabled ? AppColors.purpleGradient : null,
          color: enabled ? null : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(13),
        ),
        child: _busy && enabled
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: enabled ? AppColors.text : AppColors.textAlpha(0.3),
                ),
              ),
      ),
    );
  }

  InputDecoration _decoration({required String hint, required bool error}) {
    final idle = error ? AppColors.pink : AppColors.hairline;
    final focused = error ? AppColors.pink : AppColors.purple;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14.5, letterSpacing: 0, fontWeight: FontWeight.w400, color: AppColors.textAlpha(0.3)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: AppColors.hairline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: idle)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: focused)),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(text, style: AppTextStyles.mono(size: 10.5, color: AppColors.textAlpha(0.45))),
      );

  Widget _caption(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 7, 4, 0),
        child: Text(text, style: TextStyle(fontSize: 11.5, height: 1.4, color: color ?? AppColors.textAlpha(0.38))),
      );
}

const changeEmailSendKey = Key('change-email-send');
const changeEmailAddressKey = Key('change-email-address');
const changeEmailPasswordKey = Key('change-email-password');
const oldEmailCodeKey = Key('change-email-old-code');
const newEmailCodeKey = Key('change-email-new-code');
const confirmOldEmailKey = Key('change-email-confirm-old');
const confirmNewEmailKey = Key('change-email-confirm-new');
