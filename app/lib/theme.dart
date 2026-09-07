// Central design tokens and the ThemeData built from them, following the
// Material 3 spacing, shape, and colour-role scales rather than ad hoc
// paddings and colours scattered through widgets.

import 'package:flutter/material.dart';

/// Fixed 4dp-grid spacing scale used everywhere instead of literal numbers.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// The Material 3 shape scale. Components pick a step from here so corner
/// rounding is consistent and never invented per widget.
abstract final class AppRadius {
  static const double extraSmall = 4;
  static const double small = 8;
  static const double medium = 12;
  static const double large = 16;
  static const double extraLarge = 28;
}

const Color _seed = Color(0xFF2F6FED);

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
  );
  final base = ThemeData(colorScheme: scheme);

  // The Material 3 typescale, with slightly heavier titles and labels: the
  // default weights thin out on a phone at large system type sizes.
  final textTheme = base.textTheme.copyWith(
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    labelMedium: base.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: scheme.surfaceTint,
      elevation: 0,
      scrolledUnderElevation: 3,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.medium)),
      ),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      side: BorderSide.none,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.small)),
      ),
      labelStyle: textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
    ),
    // Material 3 filled fields: no outline, rounded top corners, and an
    // indicator that thickens on focus.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: const UnderlineInputBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.extraSmall),
        ),
      ),
      enabledBorder: UnderlineInputBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.extraSmall),
        ),
        borderSide: BorderSide(color: scheme.onSurfaceVariant),
      ),
      focusedBorder: UnderlineInputBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.extraSmall),
        ),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: UnderlineInputBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.extraSmall),
        ),
        borderSide: BorderSide(color: scheme.error),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
    ),
    // Material 3 buttons are stadium-shaped. 48dp minimum keeps every one of
    // them at or above the recommended touch target.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: const StadiumBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    listTileTheme: ListTileThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.medium)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: textTheme.bodyLarge,
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.extraLarge),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.extraLarge)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.extraSmall)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.surfaceContainerHighest,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}

/// Monospace text style for code and raw tool output: used wherever content
/// needs a fixed-width font with horizontal scroll instead of wrapping.
TextStyle monospaceStyle(BuildContext context, {double? fontSize}) {
  final theme = Theme.of(context);
  return (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
    fontFamily: 'monospace',
    fontSize: fontSize ?? theme.textTheme.bodySmall?.fontSize,
    color: theme.colorScheme.onSurface,
  );
}
