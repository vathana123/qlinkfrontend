import 'package:flutter/material.dart';

abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData _build(Brightness brightness) {
    final seeded = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3478F6),
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    final colors = dark
        ? seeded.copyWith(
            primary: const Color(0xFF3478F6),
            onPrimary: const Color(0xFFFFFFFF),
            primaryContainer: const Color(0xFF19345D),
            onPrimaryContainer: const Color(0xFFE7EDF7),
            secondary: const Color(0xFF9BBBF5),
            onSecondary: const Color(0xFF102342),
            secondaryContainer: const Color(0xFF223149),
            onSecondaryContainer: const Color(0xFFDCE8FF),
            surface: const Color(0xFF10141C),
            surfaceDim: const Color(0xFF080B11),
            surfaceBright: const Color(0xFF293241),
            surfaceContainerLowest: const Color(0xFF080B11),
            surfaceContainerLow: const Color(0xFF10141C),
            surfaceContainer: const Color(0xFF181F2A),
            surfaceContainerHigh: const Color(0xFF202938),
            surfaceContainerHighest: const Color(0xFF293241),
            onSurface: const Color(0xFFE7EDF7),
            onSurfaceVariant: const Color(0xFFA9B5C8),
            outline: const Color(0xFF78869B),
            outlineVariant: const Color(0xFF293241),
          )
        : seeded;
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: dark
          ? colors.surfaceContainerLowest
          : colors.surface,
      cardTheme: dark
          ? CardThemeData(
              color: colors.surfaceContainer,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: colors.outlineVariant),
              ),
            )
          : null,
      inputDecorationTheme: dark
          ? InputDecorationTheme(
              filled: true,
              fillColor: colors.surfaceContainer,
              hintStyle: TextStyle(color: colors.onSurfaceVariant),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: colors.primary, width: 2),
              ),
            )
          : null,
      bottomSheetTheme: dark
          ? BottomSheetThemeData(
              backgroundColor: colors.surfaceContainer,
              modalBackgroundColor: colors.surfaceContainer,
              showDragHandle: true,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
            )
          : null,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .45),
        thickness: .5,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
