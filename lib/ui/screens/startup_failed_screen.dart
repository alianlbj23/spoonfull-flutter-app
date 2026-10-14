import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/update_service.dart';
import '../widgets/buttons.dart';
import '../widgets/design_canvas.dart';
import '../widgets/update_overlay.dart';

/// 啟動失敗 (例如本機資料庫打不開) 時顯示,取代整個 App。
/// 自動更新仍在背景執行,有修正版會自己裝上並重新啟動。
class StartupFailedApp extends StatefulWidget {
  const StartupFailedApp({
    super.key,
    required this.updateStatus,
    required this.onRetry,
  });

  final ValueListenable<UpdateStatus> updateStatus;
  final Future<void> Function() onRetry;

  @override
  State<StartupFailedApp> createState() => _StartupFailedAppState();
}

class _StartupFailedAppState extends State<StartupFailedApp> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spoonfull',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      builder: (context, child) => DesignCanvas(
        child: Stack(
          children: [
            child!,
            UpdateOverlay(status: widget.updateStatus),
          ],
        ),
      ),
      home: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '系統啟動失敗',
                key: const Key('startup-failed'),
                style: AppText.size(56, color: AppColors.error),
              ),
              const SizedBox(height: 16),
              Text(
                '請按「重試」;仍然無法使用時請聯絡管理員。',
                style: AppText.size(30, color: AppColors.navy),
              ),
              const SizedBox(height: 36),
              PrimaryButton(
                key: const Key('startup-retry'),
                label: '重試',
                width: 240,
                height: 84,
                fontSize: 40,
                loading: _retrying,
                onPressed: _retrying ? null : _retry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
