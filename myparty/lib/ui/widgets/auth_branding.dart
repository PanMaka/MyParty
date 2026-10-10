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
        AuthCaption(caption),
      ],
    );
  }
}

/// The large centred line the auth screens speak in: [AuthHeader]'s caption,
/// and any caption between two [AuthFieldsBox]es, so they always match.
class AuthCaption extends StatelessWidget {
  final String text;

  const AuthCaption(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
          ),
    );
  }
}

/// Red message and underline the auth text fields show when refused.
const authErrorStyle = TextStyle(color: AppColors.formError, fontSize: 12);
const authErrorUnderline = UnderlineInputBorder(
  borderSide: BorderSide(color: AppColors.formError),
);

/// A first- or last-name input: capitalises words, and when [errorText] is set
/// the underline turns red and the message is shown under the field.
class AuthNameField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String autofillHint;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const AuthNameField({
    super.key,
    required this.controller,
    required this.label,
    required this.autofillHint,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      cursorColor: Colors.white,
      textCapitalization: TextCapitalization.words,
      autofillHints: [autofillHint],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
        errorText: errorText,
        errorStyle: authErrorStyle,
        errorBorder: authErrorUnderline,
        focusedErrorBorder: authErrorUnderline,
      ),
    );
  }
}

/// Password input with an eye toggle to show/hide what was typed. When
/// [errorText] is set, the underline turns red and the message is shown under
/// the field.
class AuthPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const AuthPasswordField({super.key, required this.controller, this.errorText, this.onChanged});

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
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: 'Password',
        labelStyle: const TextStyle(color: Colors.white70),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.white),
        ),
        errorText: widget.errorText,
        errorMaxLines: 3,
        errorStyle: authErrorStyle,
        errorBorder: authErrorUnderline,
        focusedErrorBorder: authErrorUnderline,
        suffixIcon: IconButton(
          icon: Icon(
            _obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.white70,
          ),
          tooltip: _obscured ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}

/// Date-of-birth input for registration: three dropdowns (day, month, year)
/// rather than a calendar, so picking a year is one scroll and one tap with a
/// finger or a mouse alike. [onChanged] fires once all three are chosen, and
/// again on every change after that. When [errorText] is set, the outline,
/// label and arrows turn red and the message is shown under the field.
class AuthDateOfBirthField extends StatefulWidget {
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final String? errorText;

  /// Defaults to now; injectable so tests can pin the year list.
  final DateTime? today;

  const AuthDateOfBirthField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.today,
  });

  static const monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  State<AuthDateOfBirthField> createState() => _AuthDateOfBirthFieldState();
}

class _AuthDateOfBirthFieldState extends State<AuthDateOfBirthField> {
  int? _day;
  int? _month;
  int? _year;

  @override
  void initState() {
    super.initState();
    _adopt(widget.value);
  }

  @override
  void didUpdateWidget(AuthDateOfBirthField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _adopt(widget.value);
  }

  void _adopt(DateTime? v) {
    if (v == null) return;
    _day = v.day;
    _month = v.month;
    _year = v.year;
  }

  static int _daysIn(int? year, int? month) =>
      month == null ? 31 : DateTime(year ?? 2000, month + 1, 0).day; // 2000: leap

  void _set({int? day, int? month, int? year}) {
    setState(() {
      _day = day ?? _day;
      _month = month ?? _month;
      _year = year ?? _year;
      // 31 March -> February keeps the dropdowns consistent instead of
      // silently rolling over to 3 March.
      final max = _daysIn(_year, _month);
      if (_day != null && _day! > max) _day = max;
    });
    if (_day != null && _month != null && _year != null) {
      widget.onChanged(DateTime(_year!, _month!, _day!));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null;
    final accent = hasError ? AppColors.formError : Colors.white70;
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color),
    );
    final thisYear = (widget.today ?? DateTime.now()).year;

    Widget dropdown<T>({
      required String hint,
      required T? value,
      required List<T> items,
      required String Function(T) label,
      required ValueChanged<T> onPicked,
    }) {
      return DropdownButton<T>(
        value: value,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        dropdownColor: AppColors.sheet,
        menuMaxHeight: 320,
        iconEnabledColor: accent,
        hint: Text(hint, style: const TextStyle(color: Colors.white54, fontSize: 15)),
        style: const TextStyle(color: Colors.white, fontSize: 15),
        items: [
          for (final item in items)
            DropdownMenuItem<T>(
              value: item,
              child: Text(label(item), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) onPicked(v);
        },
      );
    }

    return InputDecorator(
      isEmpty: false,
      decoration: InputDecoration(
        labelText: 'Date of birth',
        labelStyle: TextStyle(color: accent),
        floatingLabelStyle: TextStyle(color: accent),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.fromLTRB(12, 16, 8, 12),
        enabledBorder: outline(Colors.white38),
        errorText: widget.errorText,
        errorMaxLines: 3,
        errorStyle: const TextStyle(color: AppColors.formError, fontSize: 12),
        errorBorder: outline(AppColors.formError),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: dropdown<int>(
              hint: 'Day',
              value: _day,
              items: [for (var d = 1; d <= _daysIn(_year, _month); d++) d],
              label: (d) => '$d',
              onPicked: (d) => _set(day: d),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: dropdown<int>(
              hint: 'Month',
              value: _month,
              items: [for (var m = 1; m <= 12; m++) m],
              label: (m) => AuthDateOfBirthField.monthNames[m - 1],
              onPicked: (m) => _set(month: m),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: dropdown<int>(
              hint: 'Year',
              value: _year,
              // Newest first: the years people actually pick are at the top.
              items: [for (var y = thisYear; y >= 1900; y--) y],
              label: (y) => '$y',
              onPicked: (y) => _set(year: y),
            ),
          ),
        ],
      ),
    );
  }
}

/// Gender choice on the register form. [Gender.value] is what is sent to the
/// server; [Gender.label] is what the dropdown shows.
enum Gender {
  male('male', 'Male'),
  female('female', 'Female'),
  nonBinary('non_binary', 'Non-binary'),
  preferNotToSay('prefer_not_to_say', 'Prefer not to say');

  const Gender(this.value, this.label);
  final String value;
  final String label;
}

/// Dropdown for [Gender], styled like [AuthDateOfBirthField].
class AuthGenderField extends StatelessWidget {
  final Gender? value;
  final ValueChanged<Gender> onChanged;
  final String? errorText;

  const AuthGenderField({super.key, required this.value, required this.onChanged, this.errorText});

  @override
  Widget build(BuildContext context) {
    final accent = errorText != null ? AppColors.formError : Colors.white70;
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color),
    );

    return DropdownButtonFormField<Gender>(
      initialValue: value,
      isExpanded: true,
      dropdownColor: AppColors.sheet,
      iconEnabledColor: accent,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        labelText: 'Gender',
        labelStyle: TextStyle(color: accent),
        floatingLabelStyle: TextStyle(color: accent),
        enabledBorder: outline(Colors.white38),
        focusedBorder: outline(Colors.white),
        errorText: errorText,
        errorStyle: const TextStyle(color: AppColors.formError, fontSize: 12),
        errorBorder: outline(AppColors.formError),
        focusedErrorBorder: outline(AppColors.formError),
      ),
      items: [for (final g in Gender.values) DropdownMenuItem(value: g, child: Text(g.label))],
      onChanged: (g) {
        if (g != null) onChanged(g);
      },
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
