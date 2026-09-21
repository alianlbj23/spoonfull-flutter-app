import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../data/models/local_meal_record.dart';
import '../../state/record_state.dart';
import '../widgets/buttons.dart';

/// 單筆紀錄:照片、同步狀態、AI 辨識結果,失敗時可重新上傳。
class RecordDetailDialog extends StatelessWidget {
  const RecordDetailDialog({
    super.key,
    required this.record,
    required this.title,
  });

  final LocalMealRecord record;
  final String title;

  @override
  Widget build(BuildContext context) {
    final (syncLabel, syncColor) = switch (record.syncStatus) {
      SyncStatus.synced => ('已上傳', AppColors.success),
      SyncStatus.pending => ('等待上傳', AppColors.orangeText),
      SyncStatus.failed => ('上傳失敗', AppColors.error),
    };
    final time = DateFormat(
      'yyyy/MM/dd HH:mm',
    ).format(fromUnix(record.captureTime));

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SizedBox(
        width: 880,
        height: 500,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: ColoredBox(
                    color: AppColors.periwinkleLight.withValues(alpha: 0.4),
                    child: Image.file(
                      File(record.imagePath),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 72),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              SizedBox(
                width: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.size(40, color: AppColors.navy)),
                    const SizedBox(height: 8),
                    _kv('拍攝時間', time),
                    _kv('同步狀態', syncLabel, color: syncColor),
                    if (record.recordId != null) _kv('紀錄編號', record.recordId!),
                    if (record.errorMessage != null)
                      _kv('錯誤', record.errorMessage!, color: AppColors.error),
                    const Divider(height: 24),
                    AiResultView(record: record),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (record.syncStatus == SyncStatus.failed) ...[
                          PrimaryButton(
                            key: const Key('retry-upload'),
                            label: '重新上傳',
                            width: 170,
                            height: 64,
                            fontSize: 28,
                            onPressed: () async {
                              final navigator = Navigator.of(context);
                              await context.read<RecordState>().retry(record);
                              navigator.pop();
                            },
                          ),
                          const SizedBox(width: 12),
                        ],
                        PrimaryButton(
                          label: '關閉',
                          width: 130,
                          height: 64,
                          fontSize: 28,
                          background: AppColors.periwinkle,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _kv(String k, String v, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(k, style: AppText.size(20, color: AppColors.navy)),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              fontSize: 20,
              color: color ?? Colors.black87,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// AI 辨識結果 (has_food / has_person / leftover / confidence / note)。
class AiResultView extends StatelessWidget {
  const AiResultView({super.key, required this.record});

  final LocalMealRecord record;

  @override
  Widget build(BuildContext context) {
    final ai = record.aiResult;
    final status = switch (record.aiStatus) {
      AiStatus.pending => '等待辨識',
      AiStatus.processing => '辨識中',
      AiStatus.completed => '辨識完成',
      AiStatus.failed => '辨識失敗',
    };
    String yesNo(bool? v) => v == null ? '—' : (v ? '是' : '否');

    return Column(
      key: const Key('ai-result'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('AI 辨識:$status', style: AppText.size(24, color: AppColors.navy)),
        if (ai != null) ...[
          const SizedBox(height: 6),
          if (ai.leftoverPercentage != null)
            _Meter(
              label: '剩餘量',
              value: ai.leftoverPercentage! / 100,
              text: '${ai.leftoverPercentage!.toStringAsFixed(0)}%',
            ),
          if (ai.confidence != null)
            _Meter(
              label: '信心度',
              value: ai.confidence!,
              text: '${(ai.confidence! * 100).toStringAsFixed(0)}%',
            ),
          Text(
            '偵測到食物:${yesNo(ai.hasFood)}   偵測到人員:${yesNo(ai.hasPerson)}',
            style: const TextStyle(fontSize: 18),
          ),
          if (ai.note != null && ai.note!.isNotEmpty)
            Text('備註:${ai.note}', style: const TextStyle(fontSize: 18)),
        ],
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.value, required this.text});

  final String label;
  final double value;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontSize: 18)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              minHeight: 12,
              color: AppColors.blueButtonTop,
              backgroundColor: AppColors.periwinkleLight.withValues(alpha: 0.5),
            ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Text(
            text,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
