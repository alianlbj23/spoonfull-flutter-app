import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/device_state.dart';
import '../../state/record_state.dart';
import '../../state/sync_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/buttons.dart';
import '../widgets/side_rail.dart';
import 'room_list_screen.dart';
import 'server_settings_screen.dart';

/// 主畫面框架:左側欄 + 內容區 (各分頁有獨立的導覽堆疊) + 側選單。
class MainShell extends StatefulWidget {
  const MainShell({super.key, this.initialTab = ShellTab.capture});

  final ShellTab initialTab;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  late ShellTab _tab = widget.initialTab;
  final _navigatorKeys = {
    for (final t in ShellTab.values) t: GlobalKey<NavigatorState>(),
  };
  NavigatorState? get _nav => _navigatorKeys[_tab]!.currentState;
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final DeviceState _device;

  @override
  void initState() {
    super.initState();
    _device = context.read<DeviceState>()..addListener(_onDeviceChanged);
    // loadAll 會立刻 notifyListeners,不能在 build 期間 (initState) 呼叫。
    final records = context.read<RecordState>();
    WidgetsBinding.instance.addPostFrameCallback((_) => records.loadAll());
  }

  @override
  void dispose() {
    _device.removeListener(_onDeviceChanged);
    _drawer.dispose();
    super.dispose();
  }

  /// Token 失效 / 重新配對時返回歡迎畫面 (規格 6.1:401 → 返回配對)。
  void _onDeviceChanged() {
    if (_device.status == PairingStatus.notPaired && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _openDrawer() => _drawer.forward();
  void _closeDrawer() => _drawer.reverse();

  void _select(ShellTab tab) {
    _closeDrawer();
    if (tab == _tab) {
      _nav?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = tab);
    }
  }

  void _logout() {
    _closeDrawer();
    Navigator.of(context).pop();
  }

  Widget _rootFor(ShellTab tab) => switch (tab) {
    ShellTab.capture => const RoomListScreen(color: TileColor.blue),
    ShellTab.records => const RoomListScreen(color: TileColor.orange),
    ShellTab.settings => ServerSettingsScreen(
      embedded: true,
      onBack: () => _select(ShellTab.capture),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncState>();
    return NavigatorPopHandler(
      onPopWithResult: (_) {
        if (_drawer.value > 0) {
          _closeDrawer();
        } else {
          _nav?.maybePop();
        }
      },
      child: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                SideRail(
                  onOpenMenu: _openDrawer,
                  online: sync.isOnline,
                  pendingCount: sync.pendingCount,
                  syncing: sync.isSyncing,
                ),
                Expanded(
                  child: ClipRect(
                    // 每個分頁使用不同的 key,切換時重建導覽堆疊。
                    child: Navigator(
                      key: _navigatorKeys[_tab],
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => _rootFor(_tab),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            AnimatedBuilder(
              animation: _drawer,
              builder: (context, _) => _drawer.value == 0
                  ? const SizedBox.shrink()
                  : AppDrawerOverlay(
                      animation: _drawer,
                      current: _tab,
                      onSelect: _select,
                      onLogout: _logout,
                      onDismiss: _closeDrawer,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
