import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/bed_data.dart';
import '../../data/models/image_quality.dart';
import '../../data/models/local_meal_record.dart';
import '../../data/models/meal_data.dart';
import '../../data/models/room_data.dart';
import '../../data/models/weight_reading.dart';
import '../../services/hardware/hardware_service.dart';
import '../../services/record_service.dart';
import '../../state/record_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import '../widgets/numeric_keypad.dart';
import 'capture_flow.dart';
import 'record_detail_dialog.dart';

/// 預覽照片、確認重量、時段與膳食後上傳 (規格 9.3 步驟 4-6;ARCHITECTURE.md §5.1)。
class PhotoConfirmScreen extends StatefulWidget {
  const PhotoConfirmScreen({
    super.key,
    required this.room,
    required this.bed,
    required this.phase,
    required this.capture,
  });

  final RoomData room;
  final BedData bed;
  final MealPhase phase;
  final CaptureResult capture;

  @override
  State<PhotoConfirmScreen> createState() => _PhotoConfirmScreenState();
}

class _PhotoConfirmScreenState extends State<PhotoConfirmScreen> {
  TimeSlot? _slot;
  MealData? _meal;
  String? _error;
  late String _imagePath;
  late ImageQualityReport _quality;
  double? _weightG;
  WeightSource _weightSource = WeightSource.none;
  String? _weightNote;
  bool _weighing = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<RecordState>();
    _slot = state.currentTimeSlot();
    _meal = state.defaultMealFor(_slot);
    _applyCapture(widget.capture);
  }

  void _applyCapture(CaptureResult c) {
    _imagePath = c.imagePath;
    _quality = c.quality;
    final w = c.weight;
    if (w != null) {
      _weightG = w.grams;
      _weightSource = WeightSource.scale;
      _weightNote = w.stable ? null : '秤未穩定,請重新秤重或手動輸入';
      if (c.scaleLooksEmpty) _weightNote = '秤上幾乎沒有重量';
    } else {
      _weightG = null;
      _weightSource = WeightSource.none;
      _weightNote = c.weightError;
    }
  }

  Future<void> _retake() async {
    final state = context.read<RecordState>();
    try {
      final capture = await runCaptureFlow(context);
      if (capture == null) return;
      await state.discardImage(_imagePath);
      setState(() {
        _applyCapture(capture);
        _error = null;
      });
    } on Object catch (e) {
      setState(() => _error = state.errorMessage(e));
    }
  }

  Future<void> _reweigh() async {
    final state = context.read<RecordState>();
    setState(() {
      _weighing = true;
      _weightNote = null;
    });
    try {
      final w = await state.readWeight();
      if (!mounted) return;
      setState(() {
        if (w == null) {
          _weightNote = '沒有讀到秤的數值';
        } else {
          _weightG = w.grams;
          _weightSource = WeightSource.scale;
          _weightNote = w.stable ? null : '秤未穩定,請再試一次';
        }
      });
    } on Object catch (e) {
      if (mounted) setState(() => _weightNote = state.errorMessage(e));
    } finally {
      if (mounted) setState(() => _weighing = false);
    }
  }

  Future<void> _enterWeight() async {
    final initial = _weightG == null ? '' : _weightG!.round().toString();
    final value = await showNumericKeypad(
      context,
      initial: initial,
      maxLength: 5,
    );
    if (value == null) return;
    final grams = double.tryParse(value);
    setState(() {
      if (grams == null) {
        _weightG = null;
        _weightSource = WeightSource.none;
      } else {
        _weightG = grams;
        _weightSource = WeightSource.manual;
      }
      _weightNote = null;
    });
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
        weightG: _weightG,
        weightSource: _weightSource,
        quality: _quality,
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
    final busy = state.uploading || state.capturing || _weighing;

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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(_imagePath),
                      key: ValueKey(_imagePath),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 80),
                      ),
                    ),
                    if (!_quality.passed)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        child: _QualityBanner(issues: _quality.issues),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _WeightBar(
                        grams: _weightG,
                        source: _weightSource,
                        note: _weightNote,
                        scaleEnabled: state.scaleEnabled,
                        weighing: _weighing,
                        onReweigh: busy ? null : _reweigh,
                        onManual: busy ? null : _enterWeight,
                      ),
                    ),
                  ],
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
                      onPressed: busy ? null : _retake,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PrimaryButton(
                        key: const Key('upload'),
                        label: '上傳',
                        height: 78,
                        fontSize: 38,
                        loading: state.uploading,
                        onPressed: busy ? null : _upload,
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

/// 照片上方的品質警示 (使用者選擇「仍要使用」時提醒)。
class _QualityBanner extends StatelessWidget {
  const _QualityBanner({required this.issues});
  final List<QualityIssue> issues;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.orangeText.withValues(alpha: 0.9),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              issues.map((i) => i.message.split(',').first).join('、'),
              key: const Key('quality-banner'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.size(20, color: Colors.white),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 照片下方的重量列:顯示秤的讀數 / 手動輸入值,並可重新秤重或手動輸入。
class _WeightBar extends StatelessWidget {
  const _WeightBar({
    required this.grams,
    required this.source,
    required this.note,
    required this.scaleEnabled,
    required this.weighing,
    required this.onReweigh,
    required this.onManual,
  });

  final double? grams;
  final WeightSource source;
  final String? note;
  final bool scaleEnabled;
  final bool weighing;
  final VoidCallback? onReweigh;
  final VoidCallback? onManual;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = switch (source) {
      WeightSource.scale => '秤',
      WeightSource.manual => '手動',
      WeightSource.none => '',
    };
    final text = grams == null
        ? (scaleEnabled ? '未取得重量' : '未秤重')
        : '${grams!.toStringAsFixed(0)} g';
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.scale_rounded, color: Colors.white, size: 28),
                const SizedBox(width: 8),
                Text(
                  text,
                  key: const Key('weight-value'),
                  style: AppText.size(30, color: Colors.white),
                ),
                if (sourceLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      sourceLabel,
                      style: AppText.size(18, color: Colors.white),
                    ),
                  ),
                ],
                const Spacer(),
                if (scaleEnabled)
                  _SmallButton(
                    key: const Key('reweigh'),
                    label: '重新秤重',
                    loading: weighing,
                    onTap: onReweigh,
                  ),
                const SizedBox(width: 8),
                _SmallButton(
                  key: const Key('weight-manual'),
                  label: '手動輸入',
                  onTap: onManual,
                ),
              ],
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  note!,
                  key: const Key('weight-note'),
                  style: AppText.size(18, color: AppColors.ticketYellow),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    super.key,
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    return Material(
      color: Colors.white.withValues(alpha: onTap == null ? 0.5 : 0.92),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: loading ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: loading
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(label, style: AppText.size(20, color: AppColors.navy)),
        ),
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
    final weight = outcome.record.weightG;
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
              if (weight != null) ...[
                const SizedBox(height: 8),
                Text(
                  '整盤重量 ${weight.toStringAsFixed(0)} g',
                  style: AppText.size(24, color: AppColors.navy),
                ),
              ],
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
