import 'package:flutter/material.dart';

import '../../config/app_constants.dart';

/// 以 Figma 的 1024x600 畫布排版,等比縮放到實際螢幕 (機台觸控螢幕)。
class DesignCanvas extends StatelessWidget {
  const DesignCanvas({super.key, required this.child});

  final Widget child;

  static const Size size = Size(
    AppConstants.designWidth,
    AppConstants.designHeight,
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: media.copyWith(
                size: size,
                padding: EdgeInsets.zero,
                viewPadding: EdgeInsets.zero,
                textScaler: TextScaler.noScaling,
              ),
              child: ClipRect(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
