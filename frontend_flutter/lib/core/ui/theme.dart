import 'package:flutter/material.dart';

/// UUDesk 设计令牌：对标飞书移动端。
/// 壳层（首页/列表/设置）用浅色主题，会中/远控画面用深色主题。
abstract final class UuColors {
  // ---- 浅色（壳层）----
  static const primary = Color(0xFF3370FF); // 飞书品牌蓝
  static const primaryDark = Color(0xFF245BDB);
  static const pageBg = Color(0xFFF2F3F5); // 页面灰底
  static const card = Color(0xFFFFFFFF); // 白色卡片
  static const textPrimary = Color(0xFF1F2329);
  static const textSecondary = Color(0xFF646A73);
  static const textTertiary = Color(0xFF8F959E);
  static const line = Color(0xFFDEE0E3); // 边框
  static const lineLight = Color(0xFFEFF0F1); // 分隔线
  static const fill = Color(0xFFF7F8FA); // 浅填充（头像底/空态圆底）
  static const success = Color(0xFF34C724);
  static const danger = Color(0xFFF54A45);
  static const warning = Color(0xFFFFB800);

  // ---- 深色（会中/远控）----
  static const darkBg = Color(0xFF1F2226);
  static const darkCard = Color(0xFF2A2E33);
  static const darkBar = Color(0xFF16181C);
  static const darkText = Color(0xFFF7F8FA);
  static const darkTextSecondary = Color(0xFFB5BAC1);
  static const darkLine = Color(0xFF3A3F45);
}

abstract final class UuSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
}

abstract final class UuRadius {
  static const sm = 6.0;
  static const md = 8.0;
  static const lg = 12.0;
  static const xl = 16.0;
}

/// 壳层浅色主题。
ThemeData uuLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: UuColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: UuColors.primary,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE1E8FF),
    onPrimaryContainer: UuColors.primaryDark,
    surface: UuColors.card,
    onSurface: UuColors.textPrimary,
    surfaceContainerHighest: UuColors.fill,
    onSurfaceVariant: UuColors.textSecondary,
    outline: UuColors.textTertiary,
    outlineVariant: UuColors.line,
    error: UuColors.danger,
  );
  final text = _textTheme(Brightness.light);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: UuColors.pageBg,
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: UuColors.card,
      foregroundColor: UuColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: UuColors.textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      color: UuColors.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UuRadius.lg),
      ),
    ),
    listTileTheme: ListTileThemeData(
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall
          ?.copyWith(color: UuColors.textSecondary),
      iconColor: UuColors.textSecondary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: const DividerThemeData(
      color: UuColors.lineLight,
      thickness: 0.8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UuColors.fill,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      hintStyle: const TextStyle(color: UuColors.textTertiary, fontSize: 14),
      labelStyle: const TextStyle(color: UuColors.textSecondary, fontSize: 14),
      helperStyle: const TextStyle(color: UuColors.textTertiary, fontSize: 12),
      counterStyle: const TextStyle(color: UuColors.textTertiary, fontSize: 12),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: UuColors.lineLight),
        borderRadius: BorderRadius.all(Radius.circular(UuRadius.md)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: UuColors.primary, width: 1.4),
        borderRadius: BorderRadius.all(Radius.circular(UuRadius.md)),
      ),
      border: const OutlineInputBorder(
        borderSide: BorderSide(color: UuColors.lineLight),
        borderRadius: BorderRadius.all(Radius.circular(UuRadius.md)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UuRadius.md),
        ),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(0, 44),
        backgroundColor: UuColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UuRadius.md),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        foregroundColor: UuColors.textPrimary,
        side: const BorderSide(color: UuColors.line),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UuRadius.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UuColors.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: UuColors.card,
      indicatorColor: UuColors.primary.withValues(alpha: 0.10),
      height: 62,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? UuColors.primary
              : UuColors.textTertiary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? UuColors.primary
              : UuColors.textTertiary,
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : const Color(0xFFBBBBBB),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? UuColors.primary
            : const Color(0xFFE0E1E3),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xE6343A41),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UuRadius.md),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: UuColors.primary,
      linearTrackColor: UuColors.lineLight,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: UuColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UuRadius.lg),
      ),
      elevation: 6,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: UuColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UuRadius.xl),
        ),
      ),
    ),
  );
}

/// 会中/远控深色主题（房间页、抽屉、控制条）。
ThemeData uuDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: UuColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: UuColors.primary,
    onPrimary: Colors.white,
    surface: UuColors.darkBg,
    onSurface: UuColors.darkText,
    surfaceContainer: UuColors.darkCard,
    surfaceContainerHigh: UuColors.darkCard,
    surfaceContainerHighest: UuColors.darkLine,
    onSurfaceVariant: UuColors.darkTextSecondary,
    outline: UuColors.darkTextSecondary,
    outlineVariant: UuColors.darkLine,
    error: UuColors.danger,
  );
  final text = _textTheme(Brightness.dark);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: UuColors.darkBg,
    textTheme: text,
    appBarTheme: const AppBarTheme(
      backgroundColor: UuColors.darkBar,
      foregroundColor: UuColors.darkText,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: UuColors.darkText,
      ),
    ),
    cardTheme: CardThemeData(
      color: UuColors.darkCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UuRadius.lg),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: UuColors.darkLine,
      thickness: 0.8,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UuColors.darkCard,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      hintStyle: const TextStyle(color: UuColors.darkTextSecondary),
      enabledBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: UuColors.darkLine),
        borderRadius: BorderRadius.circular(UuRadius.md),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: const BorderSide(color: UuColors.primary, width: 1.4),
        borderRadius: BorderRadius.circular(UuRadius.md),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        backgroundColor: UuColors.primary,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UuRadius.md),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UuColors.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: UuColors.darkBg),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: UuColors.darkCard,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(UuRadius.xl))),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: UuColors.primary,
    ),
  );
}

TextTheme _textTheme(Brightness brightness) {
  final main = brightness == Brightness.light
      ? UuColors.textPrimary
      : UuColors.darkText;
  final sub = brightness == Brightness.light
      ? UuColors.textSecondary
      : UuColors.darkTextSecondary;
  return TextTheme(
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: main),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: main),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: main),
    bodyLarge: TextStyle(fontSize: 15, color: main),
    bodyMedium: TextStyle(fontSize: 14, color: main),
    bodySmall: TextStyle(fontSize: 12, color: sub),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: main),
  );
}
