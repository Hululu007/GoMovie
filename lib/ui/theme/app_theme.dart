import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

abstract final class AppTheme {
  static const crimson = Color(0xFFFF2E54);
  static const gold = Color(0xFFFF9E2C);
  static const brandGradient = LinearGradient(
    colors: [crimson, gold],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData build(
    Color seed,
    Brightness brightness, {
    required bool television,
    bool pureBlack = false,
  }) {
    final seeded = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final scheme = switch ((brightness, pureBlack, seed.toARGB32())) {
      (Brightness.dark, true, _) => seeded.copyWith(
        surface: Colors.black,
        surfaceDim: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF0B0B0B),
        surfaceContainer: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF242424),
      ),
      (Brightness.dark, false, 0xFFFF2E54) => seeded.copyWith(
        primary: const Color(0xFFFF2E54),
        onPrimary: Colors.white,
        tertiary: const Color(0xFFFF9E2C),
        onTertiary: const Color(0xFF1A0E00),
        surface: const Color(0xFF0A0A0C),
        surfaceDim: const Color(0xFF070709),
        surfaceContainerLowest: const Color(0xFF0A0A0C),
        surfaceContainerLow: const Color(0xFF121216),
        surfaceContainer: const Color(0xFF16161B),
        surfaceContainerHigh: const Color(0xFF1E1E24),
        surfaceContainerHighest: const Color(0xFF27272F),
        outlineVariant: const Color(0xFF2B2B33),
      ),
      _ => seeded,
    };
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      pageTransitionsTheme: pageTransitions(television: television),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
    );
    final titled = theme.copyWith(
      appBarTheme: theme.appBarTheme.copyWith(
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return theme.textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
    );
    return television ? _television(titled) : titled;
  }

  static ThemeData _television(ThemeData theme) {
    final colors = theme.colorScheme;
    final button = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.focused)
            ? colors.onSurface.withValues(alpha: 0.12)
            : null,
      ),
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    return theme.copyWith(
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      focusColor: colors.primary.withValues(alpha: 0.16),
      iconButtonTheme: IconButtonThemeData(style: button),
      filledButtonTheme: FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(style: button),
      textButtonTheme: TextButtonThemeData(style: button),
    );
  }
}
