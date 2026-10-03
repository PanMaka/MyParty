import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The logo-in-a-circle and caption shared by the login and register screens.
class AuthHeader extends StatelessWidget {
  final double logoSize;

  const AuthHeader({super.key, this.logoSize = 112});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.purple.withValues(alpha: 0.6), width: 2),
            boxShadow: [
              BoxShadow(color: AppColors.purple.withValues(alpha: 0.35), blurRadius: 24),
            ],
          ),
          child: ClipOval(
            // The asset is a full square with the M in its middle ~45%, so it
            // is scaled up to let the M fill the circle rather than float in it.
            child: Transform.scale(
              scale: 1.4,
              child: Image.asset(
                'assets/images/content.png',
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                semanticLabel: 'MyParty',
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Are you ready to party?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}

/// Password input with an eye toggle to show/hide what was typed.
class AuthPasswordField extends StatefulWidget {
  final TextEditingController controller;

  const AuthPasswordField({super.key, required this.controller});

  @override
  State<AuthPasswordField> createState() => _AuthPasswordFieldState();
}

class _AuthPasswordFieldState extends State<AuthPasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      style: const TextStyle(color: Colors.white),
      cursorColor: Colors.white,
      obscureText: _obscured,
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle: const TextStyle(color: Colors.white70),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.white),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: Colors.white70,
          ),
          tooltip: _obscured ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}

/// The bordered box the email and password inputs sit in.
class AuthFieldsBox extends StatelessWidget {
  final List<Widget> children;

  const AuthFieldsBox({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      decoration: BoxDecoration(
        color: AppColors.glassFill,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(children: children),
    );
  }
}
