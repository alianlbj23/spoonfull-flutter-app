import 'package:flutter/material.dart';

/// 取自 Figma 設計稿的色票。
class AppColors {
  AppColors._();

  static const Color navy = Color(0xFF2328A8);
  static const Color periwinkle = Color(0xFF8CA4F9);
  static const Color periwinkleLight = Color(0xFFAFBFFD);
  static const Color arrowTint = Color(0xFFDCE6FF);

  static const Color blueButtonTop = Color(0xFF4B6BFF);
  static const Color blueButtonBottom = Color(0xFF7182F6);
  static const Color blueText = Color(0xFF8CA4F9);
  static const Color keypadKey = Color(0xFF4A6CFF);

  static const Color orangeButtonTop = Color(0xFFFFA170);
  static const Color orangeButtonBottom = Color(0xFFFF7E68);
  static const Color orangeText = Color(0xFFFF7048);

  static const Color railTop = Color(0xFF242AAB);
  static const Color railBottom = Color(0xFF6769BA);

  static const Color pageTop = Color(0xFFFFFFFF);
  static const Color pageBottom = Color(0xFFFFE3EE);

  static const Color ticketGreen = Color(0xFFAAFF9C);
  static const Color ticketYellow = Color(0xFFF5F3A9);
  static const Color ticketBorder = Color(0xFF5A6BF0);
  static const Color ticketText = Color(0xFF5566E8);

  static const Color error = Color(0xFFBD2427);
  static const Color statusRed = Color(0xFFFF6B6B);
  static const Color statusGreen = Color(0xFF6BFF9C);
  static const Color success = Color(0xFF3FBF6A);

  static const Color robotPink = Color(0xFFFBA0E0);

  static const LinearGradient pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [pageTop, pageBottom],
  );

  static const LinearGradient railGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [railTop, railBottom],
  );
}
