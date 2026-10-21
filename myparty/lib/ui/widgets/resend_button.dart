import 'dart:async';

import 'package:flutter/material.dart';

/// "Send a new code", unavailable for [cooldown] after each send, counting
/// down on the button itself. Starts cooled down: the screens that show it
/// have just sent a code.
///
/// The cooldown is a courtesy, not a limit. GoTrue enforces its own (and a
/// sign-up resend replaces the code, so a tap too many only costs the user the
/// code they were about to type).
class ResendButton extends StatefulWidget {
  const ResendButton({
    super.key,
    required this.onResend,
    this.label = 'Send a new code',
    this.cooldown = const Duration(seconds: 60),
    this.color,
  });

  /// Throwing leaves the button available again at once: nothing was sent.
  final Future<void> Function() onResend;
  final String label;
  final Duration cooldown;
  final Color? color;

  @override
  State<ResendButton> createState() => _ResendButtonState();
}

class _ResendButtonState extends State<ResendButton> {
  Timer? _timer;
  late int _left = widget.cooldown.inSeconds;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _left = widget.cooldown.inSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() => _sending = true);
    try {
      await widget.onResend();
      if (mounted) setState(_start);
    } catch (_) {
      // The caller has already said why; the button is simply available again.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _left > 0;
    return TextButton(
      onPressed: waiting || _sending ? null : _resend,
      child: Text(
        waiting ? '${widget.label} (${_left}s)' : widget.label,
        style: TextStyle(color: waiting || _sending ? null : widget.color),
      ),
    );
  }
}
