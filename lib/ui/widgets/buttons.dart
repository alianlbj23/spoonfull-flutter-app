import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'icons.dart';

enum TileColor { blue, orange }

extension TileColorX on TileColor {
  List<Color> get gradient => switch (this) {
    TileColor.blue => const [AppColors.blueButtonTop, AppColors.blueButtonBottom],
    TileColor.orange => const [
      AppColors.orangeButtonTop,
      AppColors.orangeButtonBottom,
    ],
  };

  Color get text => switch (this) {
    TileColor.blue => AppColors.blueText,
    TileColor.orange => AppColors.orangeText,
  };

  String get cheerMascot => switch (this) {
    TileColor.blue => 'assets/images/mascot_cheer_blue.png',
    TileColor.orange => 'assets/images/mascot_cheer_orange.png',
  };

  String get faceMascot => switch (this) {
    TileColor.blue => 'assets/images/mascot_face_blue.png',
    TileColor.orange => 'assets/images/mascot_face_orange.png',
  };
}

/// 病房/床位用的漸層大按鈕 (頂部有亮邊)。
class GradientTile extends StatelessWidget {
  const GradientTile({
    super.key,
    required this.label,
    this.subtitle,
    required this.onTap,
    this.color = TileColor.blue,
    this.width = 241,
    this.height = 96,
    this.fontSize = 56,
  });

  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final TileColor color;
  final double width;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final radius = BorderRadius.circular(12);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: color.gradient,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.35),
                width: 3,
              ),
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: AppText.size(
                          subtitle == null ? fontSize : fontSize * 0.8,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (subtitle != null)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          style: AppText.size(
                            22,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 深藍色實心按鈕 (開始使用 / 儲存設定 / 確認);停用時為淺藍底深藍字。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.width = 322,
    this.height = 90,
    this.fontSize = 44,
    this.loading = false,
    this.letterSpacing = 0,
    this.background = AppColors.navy,
  });

  final String label;
  final VoidCallback? onPressed;
  final double width;
  final double height;
  final double fontSize;
  final bool loading;
  final double letterSpacing;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final radius = BorderRadius.circular(12);
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        color: enabled || loading ? background : AppColors.periwinkle,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? onPressed : null,
          child: Center(
            child: loading
                ? const SizedBox.square(
                    dimension: 36,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 4,
                    ),
                  )
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: AppText.size(
                        fontSize,
                        color: enabled ? Colors.white : AppColors.navy,
                      ).copyWith(letterSpacing: letterSpacing),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// 左上角的淺藍色返回方塊。
class BackTile extends StatelessWidget {
  const BackTile({
    super.key,
    required this.onTap,
    this.width = 128,
    this.height = 124,
    this.color = AppColors.periwinkle,
  });

  final VoidCallback onTap;
  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      label: '返回',
      child: SizedBox(
        width: width,
        height: height,
        child: Material(
          color: color,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Center(child: ArrowLeftIcon(size: height * 0.55)),
          ),
        ),
      ),
    );
  }
}

/// 淺藍色方形按鈕 (日期切換用)。
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.child,
    required this.onTap,
    this.width = 78,
    this.height = 111,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final Widget child;
  final VoidCallback? onTap;
  final double width;
  final double height;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onTap == null ? 0.5 : 1,
    child: SizedBox(
      width: width,
      height: height,
      child: Material(
        color: AppColors.periwinkle,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: Center(child: child),
        ),
      ),
    ),
  );
}
