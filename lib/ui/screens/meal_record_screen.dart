import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/bed_data.dart';
import '../../data/models/local_meal_record.dart';
import '../../data/models/room_data.dart';
import '../../services/hardware/hardware_service.dart';
import '../../state/record_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import 'capture_flow.dart';
import 'photo_confirm_screen.dart';

/// 新增食物攝取紀錄:選擇餐前 / 餐後 → 確認放入餐點 → 拍照或選擇檔案。
class MealRecordScreen extends StatelessWidget {
  const MealRecordScreen({super.key, required this.room, required this.bed});

  final RoomData room;
  final BedData bed;

  Future<void> _start(BuildContext context, MealPhase phase) async {
    final state = context.read<RecordState>();
    final method = await showDialog<CaptureMethod>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => PlaceMealDialog(cameraAvailable: state.cameraAvailable),
    );
    if (method == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      // 拍照 + 秤重 + 品質檢查 (ARCHITECTURE.md §5.1)
      final capture = await runCaptureFlow(context, method: method);
      if (capture == null) return;
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PhotoConfirmScreen(
            room: room,
            bed: bed,
            phase: phase,
            capture: capture,
            captureMethod: method,
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(state.errorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 25,
            top: 23,
            child: BackTile(
              width: 130,
              height: 125,
              color: AppColors.periwinkleLight,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 153,
            top: 23,
            right: 51,
            height: 125,
            child: _HeaderBanner(room: room, bed: bed),
          ),
          const Positioned(
            left: 448,
            top: 213,
            bottom: 72,
            child: SizedBox(width: 3, child: ColoredBox(color: Colors.black)),
          ),
          Positioned(
            left: 60,
            top: 200,
            width: 380,
            height: 340,
            child: _PhaseOption(
              key: const Key('phase-before'),
              label: MealPhase.before.label,
              image: AppAssets.mealBefore,
              imageWidth: 350,
              onTap: () => _start(context, MealPhase.before),
            ),
          ),
          Positioned(
            left: 460,
            top: 200,
            width: 380,
            height: 340,
            child: _PhaseOption(
              key: const Key('phase-after'),
              label: MealPhase.after.label,
              image: AppAssets.mealAfter,
              imageWidth: 220,
              onTap: () => _start(context, MealPhase.after),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderBanner extends StatelessWidget {
  const _HeaderBanner({required this.room, required this.bed});

  final RoomData room;
  final BedData bed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.blueButtonTop, AppColors.blueButtonBottom],
        ),
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.35),
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 60),
      child: Row(
        children: [
          Container(
            width: 72,
            height: 62,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.all(6),
            child: Image.asset(AppAssets.cameraCapture),
          ),
          const SizedBox(width: 30),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '新增食物攝取紀錄',
                    style: AppText.size(
                      50,
                      color: Colors.white,
                    ).copyWith(letterSpacing: 6),
                  ),
                ),
                Text(
                  '${room.roomName} ${bed.bedName}  ${bed.patientName ?? ''}',
                  style: AppText.size(
                    20,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhaseOption extends StatelessWidget {
  const _PhaseOption({
    super.key,
    required this.label,
    required this.image,
    required this.imageWidth,
    required this.onTap,
  });

  final String label;
  final String image;
  final double imageWidth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Column(
          children: [
            const SizedBox(height: 22),
            Text(
              label,
              style: AppText.size(
                52,
                color: Colors.black,
              ).copyWith(letterSpacing: 4),
            ),
            Expanded(
              child: Center(child: Image.asset(image, width: imageWidth)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「確認放入餐點後進行下一步」對話框。
/// 確認放入餐點,選擇用相機拍照或選擇圖片檔案;回傳 [CaptureMethod],返回時為 null。
///
/// [cameraAvailable] 為 false (例如桌面平台沒有相機) 時只顯示「選擇檔案」。
class PlaceMealDialog extends StatelessWidget {
  const PlaceMealDialog({super.key, this.cameraAvailable = true});

  final bool cameraAvailable;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Colors.black, width: 1),
      ),
      child: SizedBox(
        width: 904,
        height: 526,
        child: Stack(
          children: [
            Positioned(
              left: 31,
              top: 31,
              child: BackTile(
                width: 110,
                height: 108,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              left: 150,
              right: 20,
              top: 40,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '確認放入餐點後進行下一步',
                  style: AppText.size(
                    50,
                    color: Colors.black,
                  ).copyWith(letterSpacing: 4),
                ),
              ),
            ),
            Positioned(
              left: 115,
              top: 205,
              child: Image.asset(AppAssets.handBowl, width: 200),
            ),
            Positioned(
              left: 428,
              top: 146,
              child: Image.asset(AppAssets.robot, width: 252),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 408,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (cameraAvailable) ...[
                    GradientTile(
                      key: const Key('next-step'),
                      label: '拍  照',
                      width: 392,
                      height: 88,
                      fontSize: 40,
                      onTap: () =>
                          Navigator.of(context).pop(CaptureMethod.camera),
                    ),
                    const SizedBox(width: 24),
                  ],
                  GradientTile(
                    key: const Key('choose-file'),
                    label: '選擇檔案',
                    color: TileColor.orange,
                    width: cameraAvailable ? 300 : 392,
                    height: 88,
                    fontSize: 40,
                    onTap: () => Navigator.of(context).pop(CaptureMethod.file),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
