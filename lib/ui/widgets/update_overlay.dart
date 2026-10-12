import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/update_service.dart';

/// 安裝更新時蓋住整個畫面的提示;同時擋住觸控,避免重新啟動前開始新的操作。
class UpdateOverlay extends StatelessWidget {
  const UpdateOverlay({super.key, required this.status});

  final ValueListenable<UpdateStatus> status;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: status,
      builder: (context, value, _) {
        if (value != UpdateStatus.installing) return const SizedBox.shrink();
        return Positioned.fill(
          child: ColoredBox(
            key: const Key('update-overlay'),
            color: Colors.black54,
            child: Center(
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 32,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 56,
                        child: CircularProgressIndicator(
                          strokeWidth: 5,
                          color: AppColors.navy,
                        ),
                      ),
                      const SizedBox(width: 28),
                      Text(
                        '正在更新到最新版本,即將重新啟動…',
                        style: AppText.size(32, color: AppColors.navy),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
