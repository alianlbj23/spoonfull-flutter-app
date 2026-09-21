import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/room_data.dart';
import '../../state/record_state.dart';
import '../../state/sync_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import '../widgets/page_background.dart';
import '../widgets/speech_bubble.dart';
import 'bed_list_screen.dart';

/// 病房列表。藍色 = 拍攝首頁,橘色 = 膳食攝影紀錄。
class RoomListScreen extends StatelessWidget {
  const RoomListScreen({super.key, required this.color});

  final TileColor color;

  bool get _isCapture => color == TileColor.blue;

  void _openRoom(BuildContext context, RoomData room) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BedListScreen(room: room, color: color),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RecordState>();
    final sync = context.watch<SyncState>();
    final rooms = state.rooms;

    return PageBackground(
      child: Column(
        children: [
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(color.cheerMascot, width: 128),
              const SizedBox(width: 14),
              SpeechBubble(
                text: _isCapture ? '在這裡開始進行拍照記錄!' : '在這裡可以查看攝影紀錄!',
                color: color.text,
                width: 560,
                height: 88,
              ),
            ],
          ),
          const SizedBox(height: 28),
          Expanded(
            child: rooms.isEmpty
                ? _EmptyRooms(
                    loading: state.loading || sync.isSyncing,
                    onRefresh: sync.refreshNow,
                  )
                : RefreshIndicator(
                    onRefresh: sync.refreshNow,
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(90, 0, 90, 24),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 31,
                            mainAxisExtent: 96,
                          ),
                      itemCount: rooms.length,
                      itemBuilder: (context, i) => GradientTile(
                        key: Key('room-${rooms[i].roomId}'),
                        label: rooms[i].roomName,
                        color: color,
                        onTap: () => _openRoom(context, rooms[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  const _EmptyRooms({required this.loading, required this.onRefresh});

  final bool loading;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.periwinkle),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(AppAssets.mascotPixelWorried, width: 170),
        const SizedBox(height: 16),
        Text(
          '尚無病房資料,請確認網路後重新整理',
          style: AppText.size(28, color: AppColors.periwinkle),
        ),
        const SizedBox(height: 20),
        PrimaryButton(
          label: '重新整理',
          width: 240,
          height: 70,
          fontSize: 32,
          onPressed: onRefresh,
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}
