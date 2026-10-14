import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_utils.dart';
import '../../data/models/device_config.dart';
import '../../state/device_state.dart';
import '../../state/sync_state.dart';
import '../widgets/buttons.dart';
import '../widgets/numeric_keypad.dart';
import '../widgets/pill_field.dart';
import 'device_pairing_screen.dart';
import 'hardware_settings_screen.dart';

/// 設定畫面:伺服器位址 / 埠 / 場域 (Figma 設定頁)。
///
/// [embedded] 為 true 時嵌在主畫面 (側欄右側),並提供系統狀態與維護功能。
class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key, this.embedded = false, this.onBack});

  final bool embedded;
  final VoidCallback? onBack;

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _place;
  String _port = '';
  bool _showErrors = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<DeviceState>().serverSettings;
    _host = TextEditingController(text: s.host)
      ..addListener(() => setState(() {}));
    _place = TextEditingController(text: s.placeId);
    _port = s.port;
  }

  @override
  void dispose() {
    _host.dispose();
    _place.dispose();
    super.dispose();
  }

  ServerSettings get _settings => ServerSettings(
    host: _host.text.trim(),
    port: _port.trim(),
    placeId: _place.text.trim(),
  );

  bool get _hostInvalid => !_settings.address.isValid;

  /// 埠可省略 (依協定預設 443 / 80);有填就必須是合法的埠。
  bool get _portInvalid {
    if (_port.trim().isEmpty) return false;
    final p = int.tryParse(_port);
    return p == null || p <= 0 || p > 65535;
  }

  bool get _placeInvalid => _place.text.trim().isEmpty;

  void _back() {
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _editPort() async {
    final value = await showNumericKeypad(
      context,
      initial: _port,
      maxLength: 5,
    );
    if (value != null) setState(() => _port = value);
  }

  Future<void> _save() async {
    setState(() => _showErrors = true);
    if (_hostInvalid || _portInvalid || _placeInvalid) return;
    setState(() => _saving = true);
    final device = context.read<DeviceState>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await device.saveServerSettings(_settings);
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('儲存失敗:${device.errorMessage(e)}')),
      );
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;

    if (!device.isPaired) {
      // 有固定配對碼 (--dart-define=PAIRING_CODE) → 直接自動配對,不跳鍵盤。
      if (AppConfig.hasAutoPairingCode) {
        setState(() => _saving = true);
        final ok = await device.autoPair();
        if (!mounted) return;
        setState(() => _saving = false);
        if (ok) {
          messenger.showSnackBar(const SnackBar(content: Text('已自動配對')));
          if (!widget.embedded) navigator.maybePop();
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text('自動配對失敗:${device.pairingError ?? ''}')),
        );
      }
      // 嵌在主畫面時,解除配對會由 MainShell 帶回歡迎畫面。
      if (widget.embedded) return;
      // 尚未配對 → 進入配對碼輸入畫面
      await navigator.push(
        MaterialPageRoute<void>(builder: (_) => const DevicePairingScreen()),
      );
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('設定已儲存')));
    if (!widget.embedded) navigator.maybePop();
  }

  Widget _label(String text, bool error) => Padding(
    padding: const EdgeInsets.only(left: 12, bottom: 6),
    child: Text(
      error ? '*$text' : text,
      style: AppText.size(40, color: error ? AppColors.error : AppColors.navy),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hostErr = _showErrors && _hostInvalid;
    final portErr = _showErrors && _portInvalid;
    final placeErr = _showErrors && _placeInvalid;
    final left = widget.embedded ? 122.0 : 186.0;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned(left: 17, top: 19, child: BackTile(onTap: _back)),
          if (widget.embedded)
            Positioned(
              right: 16,
              top: 16,
              child: IconButton.filledTonal(
                key: const Key('system-status'),
                tooltip: '系統狀態',
                iconSize: 36,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const SystemStatusDialog(),
                ),
                icon: const Icon(Icons.tune_rounded),
              ),
            ),
          Positioned(
            left: left,
            top: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('伺服器位址', hostErr),
                PillField(
                  fieldKey: const Key('field-host'),
                  controller: _host,
                  error: hostErr,
                  keyboardType: TextInputType.url,
                  hint: 'https://foodintakesystem.com',
                ),
                _ResolvedAddress(settings: _settings, showErrors: _showErrors),
                _label('埠 (選填)', portErr),
                PillField(
                  fieldKey: const Key('field-port'),
                  value: _port,
                  error: portErr,
                  hint: '預設 443 / 80',
                  onTap: _editPort,
                ),
                const SizedBox(height: 22),
                _label('場域', placeErr),
                PillField(
                  fieldKey: const Key('field-place'),
                  controller: _place,
                  error: placeErr,
                ),
              ],
            ),
          ),
          if (context.watch<DeviceState>().clockSkewWarning case final w?)
            Positioned(
              left: left,
              right: 16,
              top: 440,
              child: Row(
                key: const Key('clock-skew-warning'),
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    color: AppColors.orangeText,
                    size: 26,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      w,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.size(20, color: AppColors.orangeText),
                    ),
                  ),
                ],
              ),
            ),
          Positioned(
            left: left + 165,
            top: 485,
            child: PrimaryButton(
              key: const Key('save-settings'),
              label: '儲存設定',
              loading: _saving,
              onPressed: _save,
            ),
          ),
          Positioned(
            left: left + 165 + 322 + 24,
            top: 485,
            child: PrimaryButton(
              key: const Key('hardware-settings'),
              label: '硬體設定',
              width: 220,
              fontSize: 36,
              background: AppColors.periwinkle,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const HardwareSettingsScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 位址欄下方的一行:實際會連到的網址,或格式錯誤 / 公開網域用 http 的提示。
class _ResolvedAddress extends StatelessWidget {
  const _ResolvedAddress({required this.settings, required this.showErrors});

  final ServerSettings settings;
  final bool showErrors;

  @override
  Widget build(BuildContext context) {
    final address = settings.address;
    final empty = settings.host.trim().isEmpty;
    final String text;
    final Color color;
    if (empty) {
      text = '可輸入完整網址,例如 https://foodintakesystem.com';
      color = AppColors.navy.withValues(alpha: 0.6);
    } else if (address.error != null) {
      // 打字中不要一直顯示紅字;按過儲存或格式已可判斷 (http 公開網址) 才顯示。
      text = address.error!;
      color = showErrors || address.uri != null
          ? AppColors.error
          : AppColors.navy.withValues(alpha: 0.6);
    } else {
      text = '將連線到 ${address.baseUrl}';
      color = AppColors.navy;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 4),
      child: SizedBox(
        width: 726,
        child: Text(
          text,
          key: const Key('resolved-url'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.size(20, color: color),
        ),
      ),
    );
  }
}

/// 系統狀態與維護 (規格 9.2 設定:刷新快取 / 重新配對 / 連線狀態 / 清除快取)。
class SystemStatusDialog extends StatelessWidget {
  const SystemStatusDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceState>();
    final sync = context.watch<SyncState>();
    final lastSync = sync.lastSync == null
        ? '尚未同步'
        : DateFormat('yyyy/MM/dd HH:mm').format(fromUnix(sync.lastSync!));
    final style = AppText.size(24, color: AppColors.navy);

    Widget row(String k, String v, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 170, child: Text(k, style: style)),
          Expanded(
            child: Text(
              v,
              style: style.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text('系統狀態', style: AppText.size(34, color: AppColors.navy)),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row(
              '版本',
              AppConfig.buildNumber > 0
                  ? 'build ${AppConfig.buildNumber}'
                  : '開發版 (不會自動更新)',
            ),
            row('設備 ID', device.config.deviceId),
            row('設備名稱', device.config.deviceName),
            row(
              '配對狀態',
              device.isPaired ? '已配對' : '未配對',
              color: device.isPaired ? AppColors.success : AppColors.error,
            ),
            row(
              '網路',
              sync.isOnline ? '在線' : '離線',
              color: sync.isOnline ? AppColors.success : AppColors.error,
            ),
            row(
              '伺服器',
              device.serverReachable ? '可連線' : '無法連線',
              color: device.serverReachable
                  ? AppColors.success
                  : AppColors.error,
            ),
            row('伺服器網址', device.serverSettings.baseUrl ?? '未設定'),
            if (device.serverSettings.baseUrl?.startsWith('http://') ?? false)
              row('連線加密', '未加密 (http),資料以明文傳輸', color: AppColors.orangeText),
            if (device.clockSkewWarning != null)
              row(
                '機台時間',
                device.clockSkewWarning!,
                color: AppColors.orangeText,
              ),
            if (device.serverHealth?.legacy ?? false)
              row('伺服器版本', '舊版 (沒有健康檢查 API)'),
            row('最後同步', lastSync),
            row('待上傳', '${sync.pendingCount} 筆'),
            row(
              '上傳失敗',
              '${sync.failedCount} 筆',
              color: sync.failedCount > 0 ? AppColors.error : null,
            ),
            if (sync.lastError != null)
              row('最近錯誤', sync.lastError!, color: AppColors.error),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton.icon(
          key: const Key('action-clear-cache'),
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('清除本機快取'),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('清除本機快取?'),
                content: const Text('將刪除病房、床位與膳食快取資料 (不會刪除未上傳的紀錄)。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('清除'),
                  ),
                ],
              ),
            );
            if (ok == true) await sync.clearCache();
          },
        ),
        TextButton.icon(
          key: const Key('action-repair'),
          icon: const Icon(Icons.link_off_rounded),
          label: const Text('重新配對'),
          onPressed: () async {
            final navigator = Navigator.of(context);
            await device.unpair();
            navigator.popUntil((r) => r.isFirst);
          },
        ),
        FilledButton.icon(
          key: const Key('action-refresh'),
          icon: sync.isSyncing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.refresh_rounded),
          label: const Text('重新整理資料'),
          onPressed: sync.isSyncing
              ? null
              : () {
                  sync.refreshNow();
                  device.checkServer();
                },
        ),
      ],
    );
  }
}
