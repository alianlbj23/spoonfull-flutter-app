import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/bed_data.dart';
import '../../data/models/room_data.dart';
import '../../state/record_state.dart';
import '../widgets/buttons.dart';
import '../widgets/page_background.dart';
import '../widgets/speech_bubble.dart';
import 'bed_detail_screen.dart';
import 'meal_record_screen.dart';

/// 床位列表 (「要幫誰紀錄呢?」/「要查看誰的紀錄呢?」)。
class BedListScreen extends StatelessWidget {
  const BedListScreen({super.key, required this.room, required this.color});

  final RoomData room;
  final TileColor color;

  bool get _isCapture => color == TileColor.blue;

  void _openBed(BuildContext context, BedData bed) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _isCapture
            ? MealRecordScreen(room: room, bed: bed)
            : BedDetailScreen(room: room, bed: bed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final beds = context.watch<RecordState>().bedsFor(room.roomId);

    return PageBackground(
      child: Stack(
        children: [
          Positioned(
            left: 23,
            top: 28,
            child: BackTile(onTap: () => Navigator.of(context).pop()),
          ),
          Positioned(
            left: 238,
            top: 44,
            child: Row(
              children: [
                Image.asset(color.faceMascot, width: 90),
                const SizedBox(width: 30),
                SpeechBubble(
                  text: _isCapture ? '要幫誰紀錄呢?' : '要查看誰的紀錄呢?',
                  color: color.text,
                  width: _isCapture ? 355 : 415,
                  height: 88,
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 200,
            bottom: 0,
            child: beds.isEmpty
                ? Center(
                    child: Text(
                      '此病房沒有床位資料',
                      style: TextStyle(fontSize: 28, color: color.text),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(86, 0, 86, 24),
                    child: Wrap(
                      spacing: 31,
                      runSpacing: 10,
                      children: [
                        for (final bed in beds)
                          GradientTile(
                            key: Key('bed-${bed.bedId}'),
                            label: bed.bedName,
                            subtitle: bed.hasPatient
                                ? bed.patientName ?? bed.patientId
                                : '空床',
                            fontSize: 52,
                            color: color,
                            // 拍攝時必須有病患;查看紀錄則不限制。
                            onTap: !_isCapture || bed.hasPatient
                                ? () => _openBed(context, bed)
                                : null,
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
