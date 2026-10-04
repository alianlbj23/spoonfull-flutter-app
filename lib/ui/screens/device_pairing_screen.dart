import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../config/app_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../state/device_state.dart';
import '../widgets/buttons.dart';
import '../widgets/numeric_keypad.dart';
import '../widgets/pill_field.dart';

/// 配對畫面 (Figma「請輸入密碼」):輸入管理端提供的配對碼,呼叫 device_pair。
class DevicePairingScreen extends StatefulWidget {
  const DevicePairingScreen({super.key});

  @override
  State<DevicePairingScreen> createState() => _DevicePairingScreenState();
}

class _DevicePairingScreenState extends State<DevicePairingScreen> {
  /// 有固定配對碼時預先填入,按確認即可。
  String _code = AppConfig.autoPairingCode;
  bool _error = false;

  Future<void> _editCode() async {
    final value = await showNumericKeypad(
      context,
      initial: _code,
      maxLength: 10,
    );
    if (value != null && value != _code) {
      setState(() {
        _code = value;
        _error = false;
      });
    }
  }

  Future<void> _confirm() async {
    final device = context.read<DeviceState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await device.pair(_code);
    if (!mounted) return;
    if (ok) {
      messenger.showSnackBar(const SnackBar(content: Text('配對成功')));
      navigator.popUntil((r) => r.isFirst);
    } else {
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceState>();
    final pairing = device.status == PairingStatus.pairing;
    final color = _error ? AppColors.error : AppColors.navy;
    final message = device.pairingError;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned(
            left: 17,
            top: 19,
            child: BackTile(onTap: () => Navigator.of(context).maybePop()),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 88,
            child: Text(
              _error ? '請重新輸入正確密碼' : '請輸入密碼',
              key: const Key('pairing-title'),
              textAlign: TextAlign.center,
              style: AppText.size(
                60,
                color: AppColors.navy,
              ).copyWith(letterSpacing: 4),
            ),
          ),
          Positioned(
            left: 164,
            top: 222,
            child: Icon(Icons.lock_rounded, size: 110, color: color),
          ),
          Positioned(
            left: 310,
            top: 237,
            child: PillField(
              fieldKey: const Key('pairing-code'),
              value: _code,
              error: _error,
              width: 498,
              height: 90,
              fontSize: 52,
              hint: '${AppConstants.pairingCodeLength} 位數配對碼',
              onTap: _editCode,
            ),
          ),
          if (_error && message != null)
            Positioned(
              left: 0,
              right: 0,
              top: 340,
              child: Text(
                message,
                key: const Key('pairing-error'),
                textAlign: TextAlign.center,
                style: AppText.size(24, color: AppColors.error),
              ),
            ),
          Positioned(
            left: 402,
            top: 391,
            child: PrimaryButton(
              key: const Key('pairing-confirm'),
              label: '確認',
              width: 220,
              height: 90,
              loading: pairing,
              onPressed: _code.isEmpty ? null : _confirm,
            ),
          ),
        ],
      ),
    );
  }
}
