import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Figma 使用粗體襯線中文字型;機台 (Ubuntu/L4T) 上對應 Noto Serif CJK TC。
const List<String> kSerifFallback = [
  'Noto Serif TC',
  'Noto Serif CJK TC',
  'Source Han Serif TC',
  'PMingLiU',
  'serif',
];

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.navy,
        primary: AppColors.navy,
        error: AppColors.error,
      ),
      scaffoldBackgroundColor: Colors.white,
      fontFamilyFallback: kSerifFallback,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamilyFallback: kSerifFallback,
        bodyColor: AppColors.navy,
        displayColor: AppColors.navy,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.navy,
      ),
    );
  }
}

/// 設計稿中的主要字級。
class AppText {
  AppText._();

  static const TextStyle heavy = TextStyle(
    fontWeight: FontWeight.w900,
    fontFamilyFallback: kSerifFallback,
    height: 1.2,
  );

  static TextStyle size(double fontSize, {Color? color}) =>
      heavy.copyWith(fontSize: fontSize, color: color);
}
