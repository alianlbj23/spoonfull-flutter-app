import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/bed_data.dart';
import '../../data/models/local_meal_record.dart';
import '../../data/models/meal_data.dart';
import '../../data/models/room_data.dart';
import '../../state/record_state.dart';
import '../widgets/buttons.dart';
import '../widgets/icons.dart';
import '../widgets/meal_ticket.dart';
import 'record_detail_dialog.dart';

/// 床位的膳食攝影紀錄 (Figma 紀錄票券頁):依日期顯示各時段餐前/餐後狀態。
class BedDetailScreen extends StatefulWidget {
  const BedDetailScreen({super.key, required this.room, required this.bed});

  final RoomData room;
  final BedData bed;

  @override
  State<BedDetailScreen> createState() => _BedDetailScreenState();
}

class _BedDetailScreenState extends State<BedDetailScreen> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  List<LocalMealRecord> _records = const [];
  int _lastVersion = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final records = await context.read<RecordState>().recordsFor(
      widget.bed.bedId,
      _day,
    );
    if (mounted) setState(() => _records = records);
  }

  void _shiftDay(int days) {
    setState(() => _day = _day.add(Duration(days: days)));
    _load();
  }

  LocalMealRecord? _find(TimeSlot slot, MealPhase phase) {
    for (final r in _records) {
      if (r.mealTimeSlot == slot.timeSlotId && r.beforeAfter == phase) {
        return r;
      }
    }
    return null;
  }

  static TicketStatus _status(LocalMealRecord? r) => switch (r?.syncStatus) {
    null => TicketStatus.none,
    SyncStatus.synced => TicketStatus.synced,
    SyncStatus.pending => TicketStatus.pending,
    SyncStatus.failed => TicketStatus.failed,
  };

  Future<void> _openRecord(LocalMealRecord? record, String title) async {
    if (record == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$title 尚無攝影紀錄')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => RecordDetailDialog(record: record, title: title),
    );
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecordState>();
    final slots = state.timeSlots;
    // 紀錄有變動 (上傳成功、重試…) 時重新讀取,讓結果即時反映在票券上。
    final version = state.recordsVersion;
    if (_lastVersion != -1 && version != _lastVersion) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    _lastVersion = version;
    final today = DateUtils.dateOnly(DateTime.now());
    final dateLabel = DateFormat('MM/dd').format(_day);
    final headerStyle = AppText.size(
      44,
      color: AppColors.ticketText,
    ).copyWith(letterSpacing: 3, fontWeight: FontWeight.w600);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 30,
            top: 41,
            child: BackTile(
              width: 110,
              height: 108,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 166,
            top: 38,
            width: 440,
            height: 116,
            child: FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(
                '房號${widget.room.roomName}-${widget.bed.bedName}\n'
                '${widget.bed.patientName ?? '—'}',
                style: headerStyle,
              ),
            ),
          ),
          Positioned(
            right: 38,
            top: 41,
            child: Row(
              children: [
                SquareIconButton(
                  key: const Key('prev-day'),
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(12),
                  ),
                  onTap: () => _shiftDay(-1),
                  child: const TriangleIcon(pointLeft: true, size: 44),
                ),
                Container(
                  width: 146,
                  height: 111,
                  decoration: BoxDecoration(
                    color: AppColors.ticketYellow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${_day.year}\n$dateLabel',
                    key: const Key('current-day'),
                    textAlign: TextAlign.center,
                    style: AppText.size(
                      34,
                      color: AppColors.ticketText,
                    ).copyWith(letterSpacing: 2, fontWeight: FontWeight.w600),
                  ),
                ),
                SquareIconButton(
                  key: const Key('next-day'),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(12),
                  ),
                  onTap: _day.isBefore(today) ? () => _shiftDay(1) : null,
                  child: const TriangleIcon(pointLeft: false, size: 44),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 192,
            height: 372,
            child: slots.isEmpty
                ? Center(
                    child: Text(
                      '尚無用餐時段資料',
                      style: AppText.size(28, color: AppColors.ticketText),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    itemCount: slots.length * 2,
                    separatorBuilder: (_, _) => const SizedBox(width: 22),
                    itemBuilder: (context, i) {
                      final slot = slots[i ~/ 2];
                      final phase = i.isEven
                          ? MealPhase.before
                          : MealPhase.after;
                      final record = _find(slot, phase);
                      final title =
                          '${slot.inferredMealType.label}${phase.label.substring(1)}';
                      return MealTicket(
                        key: Key('ticket-${slot.timeSlotId}-${phase.name}'),
                        dateLabel: dateLabel,
                        title: title,
                        color: phase == MealPhase.before
                            ? AppColors.ticketGreen
                            : AppColors.ticketYellow,
                        status: _status(record),
                        onTap: () => _openRecord(record, title),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
