import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 左側窄欄 (顯示 S),點擊開啟側選單;底部顯示連線與待上傳數量。
class SideRail extends StatelessWidget {
  const SideRail({
    super.key,
    required this.onOpenMenu,
    required this.online,
    required this.pendingCount,
    this.syncing = false,
  });

  final VoidCallback onOpenMenu;
  final bool online;
  final int pendingCount;
  final bool syncing;

  static const double width = 64;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '開啟選單',
      child: GestureDetector(
        key: const Key('side-rail'),
        behavior: HitTestBehavior.opaque,
        onTap: onOpenMenu,
        child: Container(
          width: width,
          decoration: const BoxDecoration(gradient: AppColors.railGradient),
          child: Column(
            children: [
              const SizedBox(height: 10),
              const Text(
                'S',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  fontFamilyFallback: ['Quicksand', 'Nunito', 'sans-serif'],
                ),
              ),
              const Spacer(),
              Tooltip(
                message: online ? '在線' : '離線',
                child: Icon(
                  online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                  color: online ? Colors.white : AppColors.statusRed,
                  size: 30,
                ),
              ),
              if (syncing)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (pendingCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Tooltip(
                    message: '待上傳 $pendingCount 筆',
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: AppColors.orangeButtonBottom,
                      child: Text(
                        '$pendingCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
