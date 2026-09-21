import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../state/device_state.dart';
import '../../state/record_state.dart';
import '../widgets/app_assets.dart';
import '../widgets/buttons.dart';
import '../widgets/speech_bubble.dart';
import '../widgets/status_indicator.dart';
import 'main_shell.dart';
import 'server_settings_screen.dart';

/// 開機畫面:設定圖示、開始使用、伺服器/資料庫燈號。
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final device = context.read<DeviceState>();
    final message = device.forcedLogoutMessage;
    if (message != null) {
      device.consumeForcedLogout();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      });
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ServerSettingsScreen()),
    );
  }

  void _start() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const MainShell()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceState>();
    final hasCache = context.select<RecordState, bool>(
      (s) => s.rooms.isNotEmpty,
    );
    final initializing = device.status == PairingStatus.initializing;
    final ready = device.isPaired;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 20,
            top: 20,
            child: Semantics(
              button: true,
              label: '設定',
              child: InkWell(
                key: const Key('welcome-settings'),
                customBorder: const CircleBorder(),
                onTap: _openSettings,
                child: Image.asset(AppAssets.gearLight, width: 95, height: 95),
              ),
            ),
          ),
          if (!initializing && !ready)
            const Positioned(
              left: 248,
              top: 96,
              child: SpeechBubble(
                key: Key('welcome-hint'),
                text: '點擊設定圖示進行登入設定才能\n開始使用喔!',
                color: AppColors.periwinkle,
                tail: BubbleTail.bottomLeft,
                width: 625,
                height: 172,
                fontSize: 38,
                textAlign: TextAlign.left,
              ),
            ),
          Positioned(
            left: 170,
            top: 280,
            child: Image.asset(AppAssets.mascotPixelHappy, width: 185),
          ),
          Positioned(
            left: 422,
            top: 281,
            child: PrimaryButton(
              key: const Key('start-button'),
              label: '開始使用',
              width: 402,
              height: 132,
              fontSize: 64,
              loading: initializing,
              onPressed: ready ? _start : null,
            ),
          ),
          Positioned(
            right: 14,
            bottom: 12,
            child: Row(
              children: [
                StatusIndicator(label: '伺服器', ok: device.serverReachable),
                const SizedBox(width: 16),
                StatusIndicator(
                  label: '資料庫',
                  ok: device.databaseReady && ready && hasCache,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
