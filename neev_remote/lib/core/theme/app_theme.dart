import 'package:flutter/material.dart';

/// "Coral" design system (v2) — minimal, enterprise, Windows-11 native
/// (AnyDesk workflow + Fluent 2 + Linear). One accent, no gradients.
class AppColors {
  // Brand — coral
  static const Color primary = Color(0xFFFF5A4E);
  static const Color primaryHover = Color(0xFFFF6B60);
  static const Color primaryDark = Color(0xFFE94D42); // pressed
  static const Color primarySoft = Color(0xFFFFF1EF); // coral tint
  static const Color accent = Color(0xFFFF5A4E);
  static const Color accentDark = Color(0xFFC0442F); // readable coral on white
  static const Color accentSoft = Color(0xFFFFF4F2);

  static const Color secondary = Color(0xFF6B7280);

  // Surfaces
  static const Color background = Color(0xFFF8F8F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLight = Color(0xFFF2F2F2);
  static const Color surfaceAlt = Color(0xFFFAFAFA);

  // Text
  static const Color textPrimary = Color(0xFF1D1D1F);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textTertiary = Color(0xFFA8A8A8);

  // Status
  static const Color success = Color(0xFF30C56A);
  static const Color warning = Color(0xFFF5A623);
  static const Color error = Color(0xFFF44336);

  // Lines
  static const Color border = Color(0xFFECECEC);
  static const Color borderStrong = Color(0xFFDADADA);
}

/// Very light, consistent shadows — "expensive" but restrained.
class AppShadows {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x0F1F1F2E), blurRadius: 18, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x08000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x0A1F1F2E), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> float = [
    BoxShadow(color: Color(0x1F1F1F2E), blurRadius: 28, offset: Offset(0, 12)),
  ];
}

/// Native Windows font stack (Segoe UI Variable), medium weight by default.
const String _fontFamily = 'Segoe UI Variable Text';
const List<String> _fontFallback = <String>[
  'Segoe UI Variable Display',
  'Segoe UI',
  'Roboto',
  'sans-serif',
];

/// Typography — Segoe UI Variable, medium weight, no heavy bold.
/// (Getters, so they compose with the theme's default font.)
class AppTypography {
  static TextStyle get display => const TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: AppColors.textPrimary);

  static TextStyle get heading1 => const TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: AppColors.textPrimary);

  static TextStyle get heading2 => const TextStyle(
      fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  static TextStyle get title => const TextStyle(
      fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  static TextStyle get body => const TextStyle(
      fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.textPrimary);

  static TextStyle get bodyStrong => const TextStyle(
      fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary);

  static TextStyle get caption => const TextStyle(
      fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary);

  static TextStyle get label => const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: AppColors.textSecondary);
}

/// Spacing — 8px grid (with 4px half-steps).
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Border radius. v2: inputs 10, buttons 12, cards 18.
class AppRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double input = 10;
  static const double md = 12; // buttons
  static const double lg = 16;
  static const double card = 18;
  static const double xl = 20;
  static const double pill = 999;
}

/// Light theme.
ThemeData lightTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  final textTheme = base.textTheme
      .apply(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fontFallback,
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      )
      .copyWith(
        headlineLarge: AppTypography.heading1,
        headlineMedium: AppTypography.heading2,
        titleMedium: AppTypography.title,
        bodyLarge: AppTypography.body,
        bodyMedium: AppTypography.body,
        bodySmall: AppTypography.caption,
        labelLarge: AppTypography.bodyStrong,
      );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    colorScheme: const ColorScheme.light(
      primary: AppColors.primary,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.error,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: AppColors.textPrimary,
      onError: Colors.white,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: AppTypography.heading2,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.border, width: 1),
      ),
    ),
    // Primary button — 48px, solid violet, radius 12, no gradient.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.4),
        disabledForegroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(0, 48),
        textStyle: AppTypography.bodyStrong,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ).copyWith(
        overlayColor: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) {
            return Colors.white.withValues(alpha: 0.18);
          }
          if (s.contains(WidgetState.hovered)) {
            return Colors.white.withValues(alpha: 0.10);
          }
          return null;
        }),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 48),
        textStyle: AppTypography.bodyStrong,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
    // Secondary — outline.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        backgroundColor: AppColors.surface,
        minimumSize: const Size(0, 44),
        textStyle: AppTypography.bodyStrong,
        side: const BorderSide(color: AppColors.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    ),
    // Ghost — transparent.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentDark,
        textStyle: AppTypography.bodyStrong,
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    ),
    // Inputs — 44px, rounded, violet focus ring, leading icon.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceAlt,
      hintStyle: AppTypography.body.copyWith(color: AppColors.textTertiary),
      labelStyle: AppTypography.caption,
      floatingLabelStyle: AppTypography.caption.copyWith(color: AppColors.primary),
      prefixIconColor: AppColors.textTertiary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.error, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: 13),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: AppColors.textSecondary, size: 22),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.textPrimary,
      contentTextStyle: AppTypography.body.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      titleTextStyle: AppTypography.heading2,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.textPrimary,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      textStyle: AppTypography.caption.copyWith(color: Colors.white),
    ),
  );
}
