import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../state/device_state.dart';
import '../widgets/buttons.dart';

/// 配對畫面:顯示配對碼給管理員,等管理員在網頁核准 (Device Authorization Flow)。
///
/// 進入畫面就取碼並開始輪詢;離開畫面或 App 進背景時停止,回來時繼續
/// (碼過期就重新取)。
class DevicePairingScreen extends StatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen>
    with WidgetsBindingObserver {
  late final DeviceState _device;

  /// 每秒重畫一次倒數。
  Timer? _ticker;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _device = context.read<DeviceState>()..addListener(_onDeviceChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // startPairing 會立刻 notifyListeners,不能在 build 期間呼叫。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _device.resumePairing();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _device.removeListener(_onDeviceChanged);
    _device.stopPairing();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _device.resumePairing();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _device.stopPairing();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _onDeviceChanged() {
    if (!_device.isPaired || _done || !mounted) return;
    _done = true;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('配對成功')));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  static String _mmss(Duration d) {
    final s = d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceState>();
    final code = device.pairingCode;
    final left = device.pairingTimeLeft();
    final retryIn = device.pairingRetryIn();
    final error = device.pairingError;
    final denied = device.pairingDenied;

    final String statusText;
    final Color statusColor;
    if (denied || (error != null && code == null && retryIn == null)) {
      statusText = error ?? '配對失敗';
      statusColor = AppColors.error;
    } else if (error != null && retryIn != null) {
      statusText = '$error,${retryIn.inSeconds + 1} 秒後重試';
      statusColor = AppColors.orangeText;
    } else if (code == null) {
      statusText = '正在向伺服器取得配對碼…';
      statusColor = AppColors.navy;
    } else {
      statusText = '等待管理員核准…';
      statusColor = AppColors.navy;
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 70,
            child: Text(
              '請在管理後台核准此機台',
              key: const Key('pairing-title'),
              textAlign: TextAlign.center,
              style: AppText.size(
                52,
                color: AppColors.navy,
              ).copyWith(letterSpacing: 2),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 150,
            child: Text(
              code == null ? '請到管理後台「機台管理」輸入下方的配對碼' : '請到管理後台「機台管理」輸入:$code',
              key: const Key('pairing-hint'),
              textAlign: TextAlign.center,
              style: AppText.size(26, color: AppColors.navy),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 205,
            child: Container(
              height: 150,
              margin: const EdgeInsets.symmetric(horizontal: 212),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: denied ? const Color(0xFFFFECEC) : AppColors.arrowTint,
                borderRadius: BorderRadius.circular(32),
              ),
              child: code == null
                  ? const SizedBox.square(
                      dimension: 56,
                      child: CircularProgressIndicator(
                        strokeWidth: 5,
                        color: AppColors.navy,
                      ),
                    )
                  : Text(
                      code,
                      key: const Key('pairing-code'),
                      style: AppText.size(
                        104,
                        color: AppColors.navy,
                      ).copyWith(letterSpacing: 8, fontWeight: FontWeight.w700),
                    ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 372,
            child: Text(
              left == null ? '' : '配對碼有效時間 ${_mmss(left)}',
              key: const Key('pairing-countdown'),
              textAlign: TextAlign.center,
              style: AppText.size(
                24,
                color: AppColors.navy.withValues(alpha: 0.7),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 412,
            child: Text(
              statusText,
              key: const Key('pairing-status'),
              textAlign: TextAlign.center,
              maxLines: 2,
              style: AppText.size(26, color: statusColor),
            ),
          ),
          if (denied)
            Positioned(
              left: 0,
              right: 0,
              top: 480,
              child: Center(
                child: PrimaryButton(
                  key: const Key('pairing-restart'),
                  label: '重新取得配對碼',
                  width: 420,
                  height: 90,
                  fontSize: 36,
                  onPressed: device.startPairing,
                ),
              ),
            ),
          // 放最後:滿版置中的標題與提示文字會蓋住左上角,返回鍵要在它們之上。
          Positioned(
            left: 17,
            top: 19,
            child: BackTile(onTap: () => Navigator.of(context).maybePop()),
          ),
        ],
      ),
    );
  }
}
