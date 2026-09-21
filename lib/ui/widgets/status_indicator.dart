import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';

/// 歡迎畫面右下角的「● 伺服器 ● 資料庫」燈號。
class StatusIndicator extends StatelessWidget {
  const StatusIndicator({super.key, required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label ${ok ? '正常' : '異常'}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? AppColors.statusGreen : AppColors.statusRed,
              border: Border.all(color: Colors.black87, width: 2),
            ),
          ),
          const SizedBox(width: 12),
          Text(label, style: AppText.size(32, color: Colors.black)),
        ],
      ),
    );
  }
}
