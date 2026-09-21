import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/bed_data.dart';
import '../../data/models/local_meal_record.dart';
import '../../data/models/meal_data.dart';
import '../../data/models/room_data.dart';
import '../../services/record_service.dart';
import '../../state/record_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import 'record_detail_dialog.dart';

/// 預覽照片、確認時段與膳食後上傳 (規格 9.3 步驟 4-6)。
class PhotoConfirmScreen extends StatefulWidget {
  const PhotoConfirmScreen({
    super.key,
    required this.room,
    required this.bed,
    required this.phase,
    required this.imagePath,
  });

  final RoomData room;
  final BedData bed;
  final MealPhase phase;
  final String imagePath;

  @override
  State<PhotoConfirmScreen> createState() => _PhotoConfirmScreenState();
}

class _PhotoConfirmScreenState extends State<PhotoConfirmScreen> {
  TimeSlot? _slot;
  MealData? _meal;
  String? _error;
  late String _imagePath = widget.imagePath;

  @override
  void initState() {
    super.initState();
    final state = context.read<RecordState>();
    _slot = state.currentTimeSlot();
    _meal = state.defaultMealFor(_slot);
  }

  Future<void> _retake() async {
    final state = context.read<RecordState>();
    try {
      final path = await state.captureImage();
      if (path == null) return;
      await state.discardImage(_imagePath);
      setState(() {
        _imagePath = path;
        _error = null;
      });
    } on Object catch (e) {
      setState(() => _error = state.errorMessage(e));
    }
  }

  Future<void> _upload() async {
    final state = context.read<RecordState>();
    if (_slot == null || _meal == null) {
      setState(() => _error = '請選擇用餐時段與膳食');
      return;
    }
    setState(() => _error = null);
    try {
      final outcome = await state.upload(
        bed: widget.bed,
        meal: _meal!,
        slot: _slot!,
        phase: widget.phase,
        imagePath: _imagePath,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UploadResultDialog(outcome: outcome),
      );
      if (!mounted) return;
      // 完成後返回病房列表 (主畫面)
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on Object catch (e) {
      // 本機驗證失敗 → 立即顯示,讓使用者重新拍攝
      setState(() => _error = state.errorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecordState>();
    final bed = widget.bed;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 25,
            top: 23,
            child: BackTile(
              width: 110,
              height: 108,
              onTap: () async {
                await state.discardImage(_imagePath);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ),
          Positioned(
            left: 25,
            top: 150,
            width: 470,
            height: 420,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ColoredBox(
                color: AppColors.periwinkleLight.withValues(alpha: 0.4),
                child: Image.file(
                  File(_imagePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 80),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 160,
            top: 40,
            right: 20,
            child: Text(
              '確認照片與餐別',
              style: AppText.size(
                44,
                color: AppColors.navy,
              ).copyWith(letterSpacing: 4),
            ),
          ),
          Positioned(
            left: 520,
            top: 150,
            right: 24,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoLine(
                  '${widget.room.roomName}  ${bed.bedName}  '
                  '${bed.patientName ?? ''}',
                ),
                const SizedBox(height: 6),
                _Chip(label: widget.phase.label, selected: true, onTap: null),
                const SizedBox(height: 14),
                _SectionTitle('用餐時段'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in state.timeSlots)
                      _Chip(
                        label:
                            '${s.inferredMealType.label} ${s.timeSlotName}',
                        selected: s.timeSlotId == _slot?.timeSlotId,
                        onTap: () => setState(() {
                          _slot = s;
                          _meal = state.defaultMealFor(s);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _SectionTitle('膳食'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in state.meals)
                      _Chip(
                        label: m.mealName,
                        selected: m.mealId == _meal?.mealId,
                        onTap: () => setState(() => _meal = m),
                      ),
                  ],
                ),
                const Spacer(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      key: const Key('upload-error'),
                      style: AppText.size(22, color: AppColors.error),
                    ),
                  ),
                Row(
                  children: [
                    PrimaryButton(
                      key: const Key('retake'),
                      label: '重拍',
                      width: 150,
                      height: 78,
                      fontSize: 34,
                      background: AppColors.periwinkle,
                      onPressed: state.uploading ? null : _retake,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PrimaryButton(
                        key: const Key('upload'),
                        label: '上傳',
                        height: 78,
                        fontSize: 38,
                        loading: state.uploading,
                        onPressed: _upload,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: AppText.size(30, color: AppColors.ticketText),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: AppText.size(24, color: AppColors.navy)),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(24);
    return Material(
      color: selected ? AppColors.navy : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: const BorderSide(color: AppColors.navy, width: 2),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Text(
            label,
            style: AppText.size(
              22,
              color: selected ? Colors.white : AppColors.navy,
            ),
          ),
        ),
      ),
    );
  }
}

/// 上傳結果:成功顯示 AI 辨識結果;排入佇列或失敗顯示提示。
class UploadResultDialog extends StatelessWidget {
  const UploadResultDialog({super.key, required this.outcome});

  final UploadOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final (mascot, color) = switch (outcome.status) {
      UploadOutcomeStatus.synced => (AppAssets.mascotPixelHappy, AppColors.success),
      UploadOutcomeStatus.queued => (AppAssets.mascotPixelWorried, AppColors.orangeText),
      UploadOutcomeStatus.failed => (AppAssets.mascotPixelDizzy, AppColors.error),
    };
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 640,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Image.asset(mascot, width: 140),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Text(
                      outcome.message,
                      key: const Key('upload-result-message'),
                      style: AppText.size(34, color: color),
                    ),
                  ),
                ],
              ),
              if (outcome.status == UploadOutcomeStatus.synced) ...[
                const SizedBox(height: 16),
                AiResultView(record: outcome.record),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('upload-done'),
                label: '完成',
                width: 240,
                height: 72,
                fontSize: 36,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
