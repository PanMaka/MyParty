import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The image-in-a-circle and caption at the top of the auth screens. Defaults
/// to the logo and login/register caption; onboarding steps pass their own.
class AuthHeader extends StatelessWidget {
  final double logoSize;
  final String asset;
  final double imageScale;
  final String semanticLabel;
  final String caption;

  const AuthHeader({
    super.key,
    this.logoSize = 112,
    this.asset = 'assets/images/content.png',
    // The logo asset is a full square with the M in its middle ~45%, so it
    // is scaled up to let the M fill the circle rather than float in it.
    this.imageScale = 1.4,
    this.semanticLabel = 'MyParty',
    this.caption = 'Are you ready to party?',
  });

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
            child: Transform.scale(
              scale: imageScale,
              child: Image.asset(
                asset,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                semanticLabel: semanticLabel,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          caption,
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

/// Date-of-birth input for registration: tap to open a calendar. When
/// [errorText] is set, the outline, label and icon turn red and the message is
/// shown under the field.
class AuthDateOfBirthField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final String? errorText;

  const AuthDateOfBirthField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: value ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'Date of birth',
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final accent = hasError ? AppColors.formError : Colors.white70;
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: color),
        );
    final v = value;

    return Semantics(
      button: true,
      label: 'Date of birth',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _pick(context),
        child: InputDecorator(
          isEmpty: v == null,
          decoration: InputDecoration(
            labelText: 'Date of birth',
            labelStyle: TextStyle(color: accent),
            floatingLabelStyle: TextStyle(color: accent),
            suffixIcon: Icon(Icons.calendar_today_outlined, color: accent),
            enabledBorder: outline(Colors.white38),
            errorText: errorText,
            errorMaxLines: 3,
            errorStyle: const TextStyle(color: AppColors.formError, fontSize: 12),
            errorBorder: outline(AppColors.formError),
          ),
          child: Text(
            v == null
                ? ''
                : '${v.day.toString().padLeft(2, '0')}/${v.month.toString().padLeft(2, '0')}/${v.year}',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
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
