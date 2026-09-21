import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// 設計稿中的膠囊形輸入框。
///
/// [controller] 不為 null 時可直接輸入;否則為唯讀顯示,點擊觸發 [onTap] (例如開啟數字鍵盤)。
class PillField extends StatelessWidget {
  const PillField({
    super.key,
    this.controller,
    this.value = '',
    this.onTap,
    this.error = false,
    this.width = 726,
    this.height = 57,
    this.fontSize = 36,
    this.keyboardType,
    this.hint,
    this.fieldKey,
  });

  final TextEditingController? controller;
  final String value;
  final VoidCallback? onTap;
  final bool error;
  final double width;
  final double height;
  final double fontSize;
  final TextInputType? keyboardType;
  final String? hint;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.error : AppColors.navy;
    final style = AppText.size(fontSize, color: color).copyWith(
      letterSpacing: 1.5,
      height: 1.1,
    );
    final shape = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(height / 2),
      border: Border.all(color: color, width: 3.5),
    );

    final text = controller != null
        ? TextField(
            key: fieldKey,
            controller: controller,
            keyboardType: keyboardType,
            textAlign: TextAlign.center,
            style: style,
            cursorColor: color,
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              hintText: hint,
              hintStyle: style.copyWith(color: color.withValues(alpha: 0.3)),
            ),
          )
        : FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value.isEmpty ? (hint ?? '') : value,
              style: value.isEmpty
                  ? style.copyWith(color: color.withValues(alpha: 0.3))
                  : style,
            ),
          );

    final box = Container(
      width: width,
      height: height,
      decoration: shape,
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: height / 2),
      child: Material(type: MaterialType.transparency, child: text),
    );
    if (controller != null) return box;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: fieldKey,
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: box,
      ),
    );
  }
}
