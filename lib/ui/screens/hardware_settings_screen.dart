import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/hardware_config.dart';
import '../../services/hardware/hardware_service.dart';
import '../../state/hardware_state.dart';
import '../widgets/buttons.dart';
import '../widgets/pill_field.dart';

/// 機台硬體設定 (ARCHITECTURE.md §5.1):相機來源、秤、品質檢查、空秤參考照。
class HardwareSettingsScreen extends StatefulWidget {
  const HardwareSettingsScreen({super.key});

  @override
  State<HardwareSettingsScreen> createState() => _HardwareSettingsScreenState();
}

class _HardwareSettingsScreenState extends State<HardwareSettingsScreen> {
  late HardwareConfig _config;
  late final HardwareState _state;
  late final TextEditingController _cameraDevice;
  late final TextEditingController _scaleDevice;
  late final TextEditingController _scaleHost;
  late final TextEditingController _scalePort;
  late final TextEditingController _scaleBaud;
  late final TextEditingController _mockWeight;
  bool _saving = false;

  static const _resolutions = [(640, 480), (1280, 720), (1920, 1080)];

  @override
  void initState() {
    super.initState();
    _state = context.read<HardwareState>();
    _config = _state.config;
    _cameraDevice = TextEditingController(text: _config.camera.device);
    _scaleDevice = TextEditingController(text: _config.scale.device);
    _scaleHost = TextEditingController(text: _config.scale.host);
    _scalePort = TextEditingController(text: '${_config.scale.port}');
    _scaleBaud = TextEditingController(text: '${_config.scale.baudRate}');
    _mockWeight = TextEditingController(
      text: _config.scale.mockWeightG.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    // dispose 中不能再查 context 的祖先,用 initState 存下的參考。
    _state.stopLiveWeight();
    for (final c in [
      _cameraDevice,
      _scaleDevice,
      _scaleHost,
      _scalePort,
      _scaleBaud,
      _mockWeight,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  HardwareConfig get _edited => _config.copyWith(
    camera: _config.camera.copyWith(device: _cameraDevice.text.trim()),
    scale: _config.scale.copyWith(
      device: _scaleDevice.text.trim(),
      host: _scaleHost.text.trim(),
      port: int.tryParse(_scalePort.text.trim()) ?? _config.scale.port,
      baudRate: int.tryParse(_scaleBaud.text.trim()) ?? _config.scale.baudRate,
      mockWeightG:
          double.tryParse(_mockWeight.text.trim()) ?? _config.scale.mockWeightG,
    ),
  );

  Future<void> _save({bool pop = true}) async {
    setState(() => _saving = true);
    final state = context.read<HardwareState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await state.save(_edited);
    if (!mounted) return;
    setState(() {
      _config = state.config;
      _saving = false;
    });
    messenger.showSnackBar(const SnackBar(content: Text('硬體設定已儲存')));
    if (pop) navigator.maybePop();
  }

  /// 測試前先套用目前畫面上的設定,才會用新的相機 / 秤。
  Future<void> _applyThen(Future<void> Function() op) async {
    final state = context.read<HardwareState>();
    await state.save(_edited);
    if (!mounted) return;
    setState(() => _config = state.config);
    await op();
  }

  Future<void> _testCapture() => _applyThen(() async {
    final state = context.read<HardwareState>();
    await state.testCapture();
    final result = state.lastTest;
    if (!mounted || result == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _TestCaptureDialog(result: result),
    );
  });

  Future<void> _captureReference() => _applyThen(() async {
    final state = context.read<HardwareState>();
    await state.captureReference();
    if (mounted) setState(() => _config = state.config);
  });

  Future<void> _clearReference() async {
    final state = context.read<HardwareState>();
    await state.clearReference();
    if (mounted) setState(() => _config = state.config);
  }

  Future<void> _toggleLiveWeight() => _applyThen(() async {
    final state = context.read<HardwareState>();
    if (state.liveWeightRunning) {
      await state.stopLiveWeight();
      setState(() {});
    } else {
      await state.startLiveWeight();
    }
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HardwareState>();
    final cam = _config.camera;
    final sc = _config.scale;
    final ref = _config.referenceImagePath;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned(
            left: 17,
            top: 19,
            child: BackTile(
              width: 96,
              height: 92,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Positioned(
            left: 130,
            top: 30,
            child: Text(
              '硬體設定',
              style: AppText.size(
                40,
                color: AppColors.navy,
              ).copyWith(letterSpacing: 4),
            ),
          ),
          Positioned(
            right: 24,
            top: 28,
            child: PrimaryButton(
              key: const Key('save-hardware'),
              label: '儲存',
              width: 150,
              height: 60,
              fontSize: 28,
              loading: _saving || state.busy,
              onPressed: _save,
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            top: 120,
            bottom: 12,
            child: ListView(
              children: [
                if (state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      state.error!,
                      key: const Key('hardware-error'),
                      style: AppText.size(22, color: AppColors.error),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------------- 相機 ----------------
                    Expanded(
                      child: _Section(
                        title: '相機',
                        subtitle: state.cameraDescription,
                        children: [
                          _Label('來源'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s in CameraSource.values)
                                OptionChip(
                                  key: Key('camera-${s.name}'),
                                  label: s.label,
                                  selected: cam.source == s,
                                  onTap: () => setState(
                                    () => _config = _config.copyWith(
                                      camera: cam.copyWith(source: s),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _Label(
                            cam.source == CameraSource.folder
                                ? '圖片資料夾 (相對於執行目錄或絕對路徑)'
                                : '裝置 (V4L2 路徑 / CSI sensor-id)',
                          ),
                          PillField(
                            fieldKey: const Key('camera-device'),
                            controller: _cameraDevice,
                            width: 440,
                            height: 46,
                            fontSize: 22,
                            hint: cam.source == CameraSource.folder
                                ? 'test_images'
                                : '/dev/video0',
                          ),
                          const SizedBox(height: 10),
                          _Label('擷取解析度'),
                          Wrap(
                            spacing: 6,
                            children: [
                              for (final (w, h) in _resolutions)
                                OptionChip(
                                  label: '${w}x$h',
                                  selected: cam.width == w && cam.height == h,
                                  onTap: () => setState(
                                    () => _config = _config.copyWith(
                                      camera: cam.copyWith(width: w, height: h),
                                    ),
                                  ),
                                ),
                              OptionChip(
                                label: 'MJPEG',
                                selected: cam.mjpeg,
                                onTap: () => setState(
                                  () => _config = _config.copyWith(
                                    camera: cam.copyWith(mjpeg: !cam.mjpeg),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              PrimaryButton(
                                key: const Key('test-capture'),
                                label: '測試拍照',
                                width: 170,
                                height: 54,
                                fontSize: 24,
                                loading: state.busy,
                                onPressed: _testCapture,
                              ),
                              const SizedBox(width: 10),
                              PrimaryButton(
                                key: const Key('capture-reference'),
                                label: '拍攝空秤參考照',
                                width: 230,
                                height: 54,
                                fontSize: 24,
                                background: AppColors.periwinkle,
                                onPressed: state.busy ? null : _captureReference,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              if (ref != null && File(ref).existsSync())
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    File(ref),
                                    key: ValueKey('$ref-${File(ref).lastModifiedSync()}'),
                                    width: 120,
                                    height: 68,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  ref == null
                                      ? '尚無參考照:以畫面中央的邊緣密度判斷餐盒是否在畫面。\n'
                                            '建議在秤上不放任何東西時拍一張,判斷會更準。'
                                      : '已設定空秤參考照,拍照時會與它比對。',
                                  style: AppText.size(18, color: Colors.black87),
                                ),
                              ),
                              if (ref != null)
                                TextButton(
                                  key: const Key('clear-reference'),
                                  onPressed: state.busy ? null : _clearReference,
                                  child: const Text('清除'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Switch(
                                key: const Key('quality-toggle'),
                                value: _config.qualityCheckEnabled,
                                activeThumbColor: AppColors.navy,
                                onChanged: (v) => setState(
                                  () => _config = _config.copyWith(
                                    qualityCheckEnabled: v,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '拍照品質檢查 (過暗 / 過亮 / 模糊 / 餐盒不在畫面時提示重拍)',
                                  style: AppText.size(20, color: AppColors.navy),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 20),
                    // ---------------- 秤 ----------------
                    Expanded(
                      child: _Section(
                        title: '秤',
                        subtitle: state.scaleDescription,
                        children: [
                          _Label('類型'),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final k in ScaleKind.values)
                                OptionChip(
                                  key: Key('scale-${k.name}'),
                                  label: k.label,
                                  selected: sc.kind == k,
                                  onTap: () => setState(
                                    () => _config = _config.copyWith(
                                      scale: sc.copyWith(kind: k),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (sc.kind == ScaleKind.hid ||
                              sc.kind == ScaleKind.serial) ...[
                            _Label(
                              sc.kind == ScaleKind.hid
                                  ? '裝置 (/dev/hidrawN)'
                                  : '裝置 (/dev/ttyUSB0 或 /dev/ttyACM0)',
                            ),
                            PillField(
                              fieldKey: const Key('scale-device'),
                              controller: _scaleDevice,
                              width: 440,
                              height: 46,
                              fontSize: 22,
                            ),
                          ],
                          if (sc.kind == ScaleKind.serial) ...[
                            const SizedBox(height: 10),
                            _Label('鮑率'),
                            PillField(
                              fieldKey: const Key('scale-baud'),
                              controller: _scaleBaud,
                              width: 200,
                              height: 46,
                              fontSize: 22,
                              keyboardType: TextInputType.number,
                            ),
                          ],
                          if (sc.kind == ScaleKind.tcp) ...[
                            _Label('bridge 位址與埠 (deploy/hx711_bridge.py)'),
                            Row(
                              children: [
                                PillField(
                                  fieldKey: const Key('scale-host'),
                                  controller: _scaleHost,
                                  width: 280,
                                  height: 46,
                                  fontSize: 22,
                                ),
                                const SizedBox(width: 8),
                                PillField(
                                  fieldKey: const Key('scale-port'),
                                  controller: _scalePort,
                                  width: 140,
                                  height: 46,
                                  fontSize: 22,
                                  keyboardType: TextInputType.number,
                                ),
                              ],
                            ),
                          ],
                          if (sc.kind == ScaleKind.mock) ...[
                            _Label('模擬重量 (g)'),
                            PillField(
                              fieldKey: const Key('scale-mock-weight'),
                              controller: _mockWeight,
                              width: 200,
                              height: 46,
                              fontSize: 22,
                              keyboardType: TextInputType.number,
                            ),
                          ],
                          if (sc.kind == ScaleKind.none)
                            Text(
                              '沒有秤時不會送 weight_g,server 會用菜單標準份量估算並標記 estimated。',
                              style: AppText.size(18, color: Colors.black87),
                            ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              PrimaryButton(
                                key: const Key('live-weight'),
                                label: state.liveWeightRunning ? '停止讀取' : '即時讀數',
                                width: 170,
                                height: 54,
                                fontSize: 24,
                                onPressed: sc.enabled ? _toggleLiveWeight : null,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _LiveWeight(state: state),
                              ),
                            ],
                          ),
                        ],
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

class _LiveWeight extends StatelessWidget {
  const _LiveWeight({required this.state});
  final HardwareState state;

  @override
  Widget build(BuildContext context) {
    final r = state.liveReading;
    if (!state.liveWeightRunning) {
      return Text('—', style: AppText.size(30, color: AppColors.periwinkle));
    }
    if (r == null) {
      return Text('等待秤回應…', style: AppText.size(22, color: AppColors.navy));
    }
    return Row(
      children: [
        Text(
          '${r.grams.toStringAsFixed(1)} g',
          key: const Key('live-weight-value'),
          style: AppText.size(34, color: AppColors.navy),
        ),
        const SizedBox(width: 10),
        Icon(
          r.stable ? Icons.check_circle_rounded : Icons.sync_rounded,
          color: r.stable ? AppColors.success : AppColors.orangeText,
          size: 28,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.periwinkleLight.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.size(30, color: AppColors.navy)),
        Text(
          subtitle,
          style: AppText.size(16, color: Colors.black54),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: AppText.size(20, color: AppColors.navy)),
  );
}

/// 可選取的膠囊標籤 (硬體設定頁)。
class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: AppText.size(
              19,
              color: selected ? Colors.white : AppColors.navy,
            ),
          ),
        ),
      ),
    );
  }
}

/// 測試拍照結果:照片縮圖 + 品質指標。
class _TestCaptureDialog extends StatelessWidget {
  const _TestCaptureDialog({required this.result});
  final CaptureResult result;

  @override
  Widget build(BuildContext context) {
    final q = result.quality;
    final style = AppText.size(20, color: Colors.black87);
    return AlertDialog(
      backgroundColor: Colors.white,
      title: Text(
        q.passed ? '品質檢查通過' : '品質檢查未通過',
        key: const Key('test-capture-result'),
        style: AppText.size(
          30,
          color: q.passed ? AppColors.success : AppColors.orangeText,
        ),
      ),
      content: SizedBox(
        width: 760,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(result.imagePath),
                width: 400,
                height: 225,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('尺寸 ${result.width}x${result.height}', style: style),
                  Text('平均亮度 ${q.meanLuma.toStringAsFixed(0)} / 255', style: style),
                  Text('清晰度 ${q.blurScore.toStringAsFixed(1)}', style: style),
                  Text(
                    '餐盒 ${q.trayScore.toStringAsFixed(2)} (${q.trayScoreMethod == 'reference' ? '與參考照差異' : '邊緣密度'})',
                    style: style,
                  ),
                  const SizedBox(height: 8),
                  for (final i in q.issues)
                    Text('• ${i.message}', style: AppText.size(20, color: AppColors.orangeText)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('關閉'),
        ),
      ],
    );
  }
}
