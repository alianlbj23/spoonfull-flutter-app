import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/hardware_config.dart';
import '../data/models/weight_reading.dart';
import '../services/app_services.dart';
import '../services/hardware/hardware_service.dart';
import '../services/hardware/scale_service.dart';

/// 硬體設定頁的狀態:設定值、測試拍照結果、即時秤重。
class HardwareState extends ChangeNotifier {
  HardwareState(this._services);

  final AppServices _services;

  HardwareConfig get config => _services.hardware.config;
  String get cameraDescription => _services.hardware.camera.description;
  String get scaleDescription => _services.hardware.scale.reader.description;

  bool busy = false;
  String? error;
  CaptureResult? lastTest;
  WeightReading? liveReading;
  StreamSubscription<WeightReading>? _liveSub;

  Future<void> save(HardwareConfig next) async {
    await _services.hardware.apply(next);
    await stopLiveWeight();
    notifyListeners();
  }

  Future<void> testCapture() => _guard(() async {
    lastTest = await _services.hardware.testCapture();
  });

  /// 刪掉上一張測試照片。
  Future<void> discardTest() async {
    final test = lastTest;
    lastTest = null;
    if (test != null) await _services.records.discardImage(test.imagePath);
  }

  String errorMessage(Object e) => _services.errors.userMessage(e);

  Future<void> captureReference() => _guard(() async {
    await _services.hardware.captureReference();
  });

  Future<void> clearReference() => _guard(_services.hardware.clearReference);

  /// 開始顯示即時讀數;再次呼叫會先停止前一次。
  Future<void> startLiveWeight() async {
    await stopLiveWeight();
    error = null;
    liveReading = null;
    if (!_services.hardware.scale.enabled) {
      error = '尚未設定秤';
      notifyListeners();
      return;
    }
    _liveSub = _services.hardware.liveWeight().listen(
      (r) {
        liveReading = r;
        notifyListeners();
      },
      onError: (Object e) {
        error = _services.errors.userMessage(e);
        notifyListeners();
      },
    );
    notifyListeners();
  }

  bool get liveWeightRunning => _liveSub != null;

  Future<void> stopLiveWeight() async {
    final sub = _liveSub;
    _liveSub = null;
    if (sub != null) await ScaleService.cancelReading(sub);
  }

  Future<void> _guard(Future<void> Function() op) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await op();
    } on Object catch (e) {
      error = _services.errors.userMessage(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }
}
