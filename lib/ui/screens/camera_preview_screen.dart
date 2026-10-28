import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../services/hardware/camera_service.dart';
import '../../services/hardware/hardware_service.dart';
import '../../state/record_state.dart';
import '../widgets/buttons.dart';
import 'capture_flow.dart';

/// 拍照畫面:左邊是相機的即時畫面,右邊有快門。
///
/// 進來就開預覽串流 ([RecordState.openPreview]);按快門從同一條串流拍照 + 秤重
/// + 品質檢查,不通過時可以直接在這裡重拍。離開時關掉串流。
/// 回傳 [CaptureResult],取消時 null。
class CameraPreviewScreen extends StatefulWidget {
  const CameraPreviewScreen({super.key});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraPreview? _preview;
  StreamSubscription<Uint8List>? _sub;
  Uint8List? _frame;

  /// 啟動失敗或拍照失敗的訊息。
  String? _error;

  /// 串流已經結束 (程式退出、相機被拔);要按「重試」重開。
  bool _ended = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_preview?.close());
    super.dispose();
  }

  void _open() {
    final state = context.read<RecordState>();
    _sub?.cancel();
    unawaited(_preview?.close());
    setState(() {
      _frame = null;
      _error = null;
      _ended = false;
    });
    final CameraPreview preview;
    try {
      preview = state.openPreview();
    } on Object catch (e) {
      setState(() {
        _error = state.errorMessage(e);
        _ended = true;
      });
      return;
    }
    _preview = preview;
    _sub = preview.frames.listen(
      (frame) {
        if (!mounted || !identical(_preview, preview)) return;
        setState(() => _frame = frame);
      },
      onDone: () {
        if (!mounted || !identical(_preview, preview)) return;
        setState(() {
          _ended = true;
          _error ??= '相機的畫面中斷了,請確認 USB 線有接好,再按「重試」';
        });
      },
    );
    preview.ready.catchError((Object e) {
      if (!mounted || !identical(_preview, preview)) return;
      setState(() {
        _error = state.errorMessage(e);
        _ended = true;
      });
    });
  }

  Future<void> _shoot() async {
    final preview = _preview;
    if (preview == null || _busy || _ended) return;
    final state = context.read<RecordState>();
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await state.capture(via: preview);
      if (!mounted) return;
      if (result == null) return;
      if (!state.qualityCheckEnabled || result.quality.passed) {
        navigator.pop(result);
        return;
      }
      final choice = await showDialog<QualityChoice>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QualityWarningDialog(result: result),
      );
      switch (choice) {
        case QualityChoice.keep:
          navigator.pop(result);
        case QualityChoice.retake:
          await state.discardImage(result.imagePath);
        case QualityChoice.cancel:
        case null:
          await state.discardImage(result.imagePath);
          navigator.pop(null);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = state.errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    final canShoot = frame != null && !_busy && !_ended;
    return Scaffold(
      backgroundColor: Colors.black,
      body: PopScope(
        canPop: !_busy,
        child: Row(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (frame != null)
                    Image.memory(
                      frame,
                      key: const Key('preview-frame'),
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                    )
                  else
                    _Placeholder(error: _error),
                  if (frame != null && _error != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ColoredBox(
                        color: AppColors.orangeText,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Text(
                            _error!,
                            key: const Key('preview-error'),
                            style: AppText.size(24, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  if (_busy)
                    const ColoredBox(
                      color: Colors.black45,
                      child: Center(child: CaptureProgressDialog()),
                    ),
                ],
              ),
            ),
            _SidePanel(
              canShoot: canShoot,
              busy: _busy,
              ended: _ended,
              onShoot: _shoot,
              onRetry: _open,
              onBack: () => Navigator.of(context).pop(null),
            ),
          ],
        ),
      ),
    );
  }
}

/// 還沒有畫面時:啟動中的提示,或啟動失敗的原因。
class _Placeholder extends StatelessWidget {
  const _Placeholder({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: error == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 64,
                    child: CircularProgressIndicator(
                      strokeWidth: 5,
                      color: AppColors.periwinkle,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    '相機啟動中…',
                    key: const Key('preview-starting'),
                    style: AppText.size(30, color: Colors.white),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.videocam_off_rounded,
                    size: 80,
                    color: AppColors.orangeText,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    error,
                    key: const Key('preview-error'),
                    textAlign: TextAlign.center,
                    style: AppText.size(28, color: Colors.white),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({
    required this.canShoot,
    required this.busy,
    required this.ended,
    required this.onShoot,
    required this.onRetry,
    required this.onBack,
  });

  final bool canShoot;
  final bool busy;
  final bool ended;
  final VoidCallback onShoot;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final scale = context.select<RecordState, bool>((s) => s.scaleEnabled);
    final hint = busy
        ? '拍照中…'
        : ended
        ? '相機沒有畫面'
        : canShoot
        ? (scale ? '放好餐盒後\n按下快門' : '按下快門拍照')
        : '請稍候…';
    return Container(
      width: 220,
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          BackTile(
            width: 110,
            height: 100,
            color: AppColors.periwinkleLight,
            onTap: busy ? () {} : onBack,
          ),
          const Spacer(),
          ShutterButton(
            key: const Key('shutter'),
            enabled: canShoot,
            onTap: onShoot,
          ),
          const SizedBox(height: 16),
          Text(
            hint,
            key: const Key('preview-hint'),
            textAlign: TextAlign.center,
            style: AppText.size(24, color: AppColors.navy),
          ),
          const Spacer(),
          if (ended)
            PrimaryButton(
              key: const Key('preview-retry'),
              label: '重試',
              width: 180,
              height: 64,
              fontSize: 26,
              onPressed: busy ? null : onRetry,
            ),
        ],
      ),
    );
  }
}

/// 圓形快門鈕 (相機 icon)。
class ShutterButton extends StatelessWidget {
  const ShutterButton({
    super.key,
    required this.enabled,
    required this.onTap,
    this.size = 150,
  });

  final bool enabled;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: '快門',
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(
            side: BorderSide(color: AppColors.navy, width: 7),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onTap : null,
            child: SizedBox.square(
              dimension: size,
              child: Icon(
                Icons.camera_alt_rounded,
                size: size * 0.5,
                color: AppColors.navy,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
