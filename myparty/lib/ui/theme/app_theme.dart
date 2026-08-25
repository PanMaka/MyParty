import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colors ported from the Athens nightlife design (MyPartyApp.dc.html).
class AppColors {
  AppColors._();

  static const canvas = Color(0xFF07060B);
  static const bg = Color(0xFF0B0A10);
  static const sheet = Color(0xFF12101A);
  static const text = Color(0xFFF4F1F8);

  static const purpleDeep = Color(0xFF534AB7);
  static const purple = Color(0xFF7F77DD);
  static const purpleLight = Color(0xFFB7B1F2);
  static const pink = Color(0xFFD4537E);
  static const pinkDeep = Color(0xFFB7436B);
  static const pinkLight = Color(0xFFEDA8C0);

  /// PRIVATE. One colour for the concept, everywhere it appears — the map
  /// bubble, the PRIVATE badge on seven surfaces, and the card borders — so
  /// a pin and the badge in the sheet it opens cannot disagree about what
  /// private looks like.
  ///
  /// Deliberately NOT [destructive], which is a different red for a different
  /// idea. A private party is exclusive, not dangerous, and the two must stay
  /// tellable apart if they ever share a screen.
  ///
  /// Red replaces pink as the private accent but does NOT replace the dashed
  /// outline it is drawn with — see [MpDropPainter]. Colour is the fast
  /// channel and the dash is the reliable one: red-vs-purple is exactly the
  /// pair red-green colour blindness collapses, so the shape has to carry the
  /// distinction on its own for those readers.
  static const private = Color(0xFFF23557);
  static const privateDeep = Color(0xFFC4213C);
  static const privateLight = Color(0xFFFF9AAC);

  /// Destructive actions only: account deletion, and anything else that
  /// permanently removes data. Was an unnamed literal repeated four times in
  /// account_deletion_screen.dart.
  static const destructive = Color(0xFFE5484D);

  static const purpleGradient = LinearGradient(
    colors: [purpleDeep, purple],
  );
  static const brandGradient = LinearGradient(
    colors: [purpleDeep, purple, pink],
    stops: [0, 0.55, 1],
  );
  static const pinkGradient = LinearGradient(
    colors: [pinkDeep, pink],
  );
  /// The private-party CTA fill, mirroring [purpleGradient] for public.
  static const privateGradient = LinearGradient(
    colors: [privateDeep, private],
  );
  static const likeGradient = LinearGradient(
    colors: [pink, purpleDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static Color textAlpha(double opacity) => text.withValues(alpha: opacity);
  static Color hairline = Colors.white.withValues(alpha: 0.09);
  static Color glassFill = Colors.white.withValues(alpha: 0.05);
  static Color chipFill = const Color(0xFF14121C).withValues(alpha: 0.82);
}

class AppTextStyles {
  AppTextStyles._();

  /// Roboto Mono, used for labels, badges, timestamps and countdowns.
  static TextStyle mono({
    double size = 11,
    FontWeight weight = FontWeight.w600,
    Color color = AppColors.text,
    double? letterSpacing,
  }) {
    return GoogleFonts.robotoMono(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing ?? size * 0.08,
    );
  }
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.purple,
      secondary: AppColors.pink,
      surface: AppColors.sheet,
    ),
  );

  final textTheme = GoogleFonts.commissionerTextTheme(base.textTheme).apply(
    bodyColor: AppColors.text,
    displayColor: AppColors.text,
  );

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
  );
}
