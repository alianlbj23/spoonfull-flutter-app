import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 白 → 淡粉紅漸層背景。
class PageBackground extends StatelessWidget {
  const PageBackground({super.key, required this.child, this.plain = false});

  final Widget child;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: plain ? Colors.white : null,
          gradient: plain ? null : AppColors.pageGradient,
        ),
        child: SizedBox.expand(child: child),
      ),
    );
  }
}
