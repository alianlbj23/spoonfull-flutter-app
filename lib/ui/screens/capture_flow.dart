import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/image_quality.dart';
import '../../services/hardware/hardware_service.dart';
import '../../state/record_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import 'camera_preview_screen.dart';

/// 品質檢查不通過時使用者的選擇。
enum QualityChoice { retake, keep, cancel }

/// 拍照流程 (ARCHITECTURE.md §5.1):
/// 相機能即時預覽時 (RealSense) 開 [CameraPreviewScreen]:顯示畫面、按快門才拍,
/// 品質不佳的重拍也在同一個畫面裡完成。
/// 其他情況顯示「拍照中」→ 擷取 + 秤重 → 品質檢查不通過時提示重拍 → 回傳結果。
/// [method] 為 [CaptureMethod.file] 時改為選擇圖片檔案,重拍也沿用同一種方式。
/// 使用者取消時回傳 null;錯誤會往外丟,由呼叫端顯示。
Future<CaptureResult?> runCaptureFlow(
  BuildContext context, {
  CaptureMethod method = CaptureMethod.camera,
}) async {
  final state = context.read<RecordState>();
  if (method == CaptureMethod.camera && state.previewSupported) {
    return Navigator.of(context).push<CaptureResult?>(
      MaterialPageRoute(builder: (_) => const CameraPreviewScreen()),
    );
  }
  while (true) {
    if (!context.mounted) return null;
    final result = await _withProgress(
      context,
      state.capture(method: method),
      method,
    );
    if (result == null) return null;
    if (!state.qualityCheckEnabled || result.quality.passed) return result;
    if (!context.mounted) return result;

    final choice = await showDialog<QualityChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => QualityWarningDialog(result: result),
    );
    switch (choice) {
      case QualityChoice.keep:
        return result;
      case QualityChoice.retake:
        await state.discardImage(result.imagePath);
        continue;
      case QualityChoice.cancel:
      case null:
        await state.discardImage(result.imagePath);
        return null;
    }
  }
}

Future<T> _withProgress<T>(
  BuildContext context,
  Future<T> future,
  CaptureMethod method,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          PopScope(canPop: false, child: CaptureProgressDialog(method: method)),
    ).then((_) => dialogOpen = false),
  );
  try {
    return await future;
  } finally {
    if (dialogOpen && navigator.canPop()) navigator.pop();
  }
}

/// 「拍照與秤重中」提示。
class CaptureProgressDialog extends StatelessWidget {
  const CaptureProgressDialog({super.key, this.method = CaptureMethod.camera});

  final CaptureMethod method;

  @override
  Widget build(BuildContext context) {
    final scale = context.select<RecordState, bool>((s) => s.scaleEnabled);
    return Dialog(
      key: const Key('capture-progress'),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
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
            Text(switch ((method, scale)) {
              (CaptureMethod.file, true) => '選擇圖片與秤重中…',
              (CaptureMethod.file, false) => '請選擇圖片檔案…',
              (CaptureMethod.camera, true) => '拍照與秤重中,請勿移動餐盒…',
              (CaptureMethod.camera, false) => '拍照中,請勿移動餐盒…',
            }, style: AppText.size(32, color: AppColors.navy)),
          ],
        ),
      ),
    );
  }
}

/// 品質檢查不通過:列出問題,可重拍或仍要使用這張照片。
class QualityWarningDialog extends StatelessWidget {
  const QualityWarningDialog({super.key, required this.result});

  final CaptureResult result;

  @override
  Widget build(BuildContext context) {
    final issues = result.quality.issues;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 720,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Image.asset(AppAssets.mascotPixelWorried, width: 110),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Text(
                      '照片品質不佳',
                      key: const Key('quality-warning'),
                      style: AppText.size(38, color: AppColors.orangeText),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final issue in issues)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: AppColors.orangeText,
                        size: 30,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          issue.message,
                          style: AppText.size(26, color: Colors.black87),
                        ),
                      ),
                    ],
                  ),
                ),
              if (result.scaleLooksEmpty &&
                  !issues.contains(QualityIssue.trayMissing))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '秤上幾乎沒有重量,請確認餐盒已放在秤面上',
                    style: AppText.size(24, color: AppColors.orangeText),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PrimaryButton(
                    key: const Key('quality-cancel'),
                    label: '取消',
                    width: 130,
                    height: 64,
                    fontSize: 26,
                    background: AppColors.periwinkle,
                    onPressed: () =>
                        Navigator.of(context).pop(QualityChoice.cancel),
                  ),
                  const SizedBox(width: 12),
                  PrimaryButton(
                    key: const Key('quality-keep'),
                    label: '仍要使用',
                    width: 170,
                    height: 64,
                    fontSize: 26,
                    background: AppColors.periwinkle,
                    onPressed: () =>
                        Navigator.of(context).pop(QualityChoice.keep),
                  ),
                  const SizedBox(width: 12),
                  PrimaryButton(
                    key: const Key('quality-retake'),
                    label: '重拍',
                    width: 170,
                    height: 64,
                    fontSize: 28,
                    onPressed: () =>
                        Navigator.of(context).pop(QualityChoice.retake),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
