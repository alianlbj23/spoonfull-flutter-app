import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';
import '../../data/models/hardware_config.dart';
import '../../data/models/weight_reading.dart';

/// 秤的資料來源:每次呼叫 [readings] 開啟裝置並持續輸出讀數,取消訂閱時關閉。
abstract class ScaleReader {
  const ScaleReader();

  Stream<WeightReading> readings();

  String get description;

  static ScaleReader create(ScaleSettings s) => switch (s.kind) {
    ScaleKind.none => const NoScaleReader(),
    ScaleKind.hid => HidScaleReader(s.device),
    ScaleKind.serial => LineScaleReader.serial(s.device, baudRate: s.baudRate),
    ScaleKind.tcp => LineScaleReader.tcp(s.host, s.port),
    ScaleKind.mock => MockScaleReader(grams: s.mockWeightG),
  };
}

class NoScaleReader extends ScaleReader {
  const NoScaleReader();

  @override
  Stream<WeightReading> readings() => const Stream.empty();

  @override
  String get description => '未設定秤';
}

/// 模擬秤:先給幾筆晃動的讀數,再穩定在 [grams]。
class MockScaleReader extends ScaleReader {
  const MockScaleReader({
    this.grams = 420,
    this.interval = const Duration(milliseconds: 120),
    this.unstableReadings = 3,
  });

  final double grams;
  final Duration interval;
  final int unstableReadings;

  @override
  String get description => '模擬秤 (${grams.toStringAsFixed(0)} g)';

  @override
  Stream<WeightReading> readings() async* {
    final rnd = math.Random();
    var i = 0;
    while (true) {
      await Future<void>.delayed(interval);
      final jitter = i < unstableReadings ? (rnd.nextDouble() - 0.5) * 40 : 0.0;
      yield WeightReading(
        grams: grams + jitter,
        stable: i >= unstableReadings,
        at: DateTime.now(),
      );
      i++;
    }
  }
}

/// USB HID 秤 (USB HID Point of Sale Usage Tables,usage page 0x8D)。
///
/// 從 `/dev/hidrawN` 讀取,每筆報告 6 bytes:
/// `[report_id(3), status, unit, exponent(int8), weight_lo, weight_hi]`,
/// 部分裝置不帶 report_id (5 bytes)。需要 udev 規則開放 hidraw 權限,見 deploy/。
class HidScaleReader extends ScaleReader {
  const HidScaleReader(this.devicePath);

  final String devicePath;

  @override
  String get description => 'USB HID 秤 $devicePath';

  @override
  Stream<WeightReading> readings() async* {
    final file = File(devicePath);
    if (!await file.exists()) {
      throw AppException(
        AppErrorType.localValidation,
        '找不到秤 ($devicePath),請確認 USB 已接上',
        code: 'SCALE_UNAVAILABLE',
      );
    }
    await for (final chunk in file.openRead()) {
      for (final report in splitReports(chunk)) {
        final r = parseReport(report);
        if (r != null) yield r;
      }
    }
  }

  /// hidraw 一次 read 通常剛好一筆報告;保險起見把連在一起的多筆拆開。
  static Iterable<List<int>> splitReports(List<int> chunk) sync* {
    if (chunk.length == 5 || chunk.length == 6) {
      yield chunk;
      return;
    }
    final size = chunk.length % 6 == 0 ? 6 : (chunk.length % 5 == 0 ? 5 : 0);
    if (size == 0) {
      yield chunk;
      return;
    }
    for (var i = 0; i + size <= chunk.length; i += size) {
      yield chunk.sublist(i, i + size);
    }
  }

  /// 解析一筆報告,換算成公克。狀態碼:1 故障、2 歸零穩定、3 移動中、4 穩定、
  /// 5 低於零、6 超重、7/8 需校正。
  static WeightReading? parseReport(List<int> bytes) {
    List<int> b;
    if (bytes.length >= 6 && (bytes[0] == 3 || bytes[0] == 4)) {
      b = bytes.sublist(1, 6);
    } else if (bytes.length == 5) {
      b = bytes;
    } else if (bytes.length >= 6) {
      b = bytes.sublist(1, 6);
    } else {
      return null;
    }
    final status = b[0];
    final unit = b[1];
    var exp = b[2];
    if (exp > 127) exp -= 256;
    final raw = b[3] | (b[4] << 8);
    final value = raw * math.pow(10, exp).toDouble();
    final grams = toGrams(value, unit);
    if (grams == null) return null;
    final stable = status == 4 || status == 2;
    final valid = status == 2 || status == 3 || status == 4 || status == 5;
    if (!valid) return null;
    return WeightReading(
      grams: status == 5 ? -grams : grams,
      stable: stable,
      at: DateTime.now(),
      raw: bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' '),
    );
  }

  /// HID 單位碼 → 公克倍率。
  static double? toGrams(double value, int unit) => switch (unit) {
    1 => value / 1000, // mg
    2 => value, // g
    3 => value * 1000, // kg
    4 => value * 0.2, // carat
    5 => value * 37.799, // tael
    6 => value * 0.06479891, // grain
    7 => value * 1.55517384, // pennyweight
    8 => value * 1e6, // metric ton
    9 => value * 907184.74, // avoir ton
    10 => value * 31.1034768, // troy oz
    11 => value * 28.349523125, // oz
    12 => value * 453.59237, // lb
    _ => null,
  };
}

/// 文字行協定:序列埠秤、HX711 + 微控制器 (USB 序列埠),或 deploy/hx711_bridge.py 的 TCP 輸出。
///
/// 每行一個數值,例如 `ST,GS,  123.4 g`、`0.1234 kg`、`123.4`、`US,GS, 120.1 g`。
/// `ST` 視為穩定、`US` 視為不穩定;沒有單位時當公克。
class LineScaleReader extends ScaleReader {
  const LineScaleReader.serial(this.devicePath, {this.baudRate = 9600})
    : host = null,
      port = 0;

  const LineScaleReader.tcp(this.host, this.port)
    : devicePath = null,
      baudRate = 0;

  final String? devicePath;
  final int baudRate;
  final String? host;
  final int port;

  bool get isTcp => host != null;

  @override
  String get description =>
      isTcp ? 'HX711 bridge $host:$port' : '序列埠 $devicePath @ $baudRate';

  @override
  Stream<WeightReading> readings() async* {
    final Stream<List<int>> bytes;
    Socket? socket;
    if (isTcp) {
      try {
        socket = await Socket.connect(
          host!,
          port,
          timeout: const Duration(seconds: 3),
        );
      } on Object catch (e) {
        throw AppException(
          AppErrorType.localValidation,
          '無法連線到秤的服務 ($host:$port): $e',
          code: 'SCALE_UNAVAILABLE',
        );
      }
      bytes = socket;
    } else {
      final file = File(devicePath!);
      if (!await file.exists()) {
        throw AppException(
          AppErrorType.localValidation,
          '找不到秤 ($devicePath),請確認 USB 已接上',
          code: 'SCALE_UNAVAILABLE',
        );
      }
      await configureSerial(devicePath!, baudRate);
      bytes = file.openRead();
    }
    try {
      await for (final line in bytes
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        final r = parseLine(line);
        if (r != null) yield r;
      }
    } finally {
      // 訂閱取消 (讀到穩定值) 時關閉連線,不留下開著的 socket。
      socket?.destroy();
    }
  }

  /// 以 `stty` 設定 raw 模式與鮑率 (沒有 stty 時略過,靠裝置預設)。
  static Future<void> configureSerial(String device, int baud) async {
    if (!Platform.isLinux) return;
    try {
      final r = await Process.run('stty', [
        '-F', device, '$baud', 'raw', '-echo', '-echoe', '-echok', '-hupcl',
        'cs8', '-cstopb', '-parenb',
      ]);
      if (r.exitCode != 0) Log.i('stty failed: ${r.stderr}');
    } catch (e) {
      Log.i('stty unavailable: $e');
    }
  }

  static final _number = RegExp(r'[-+]?\d+(?:\.\d+)?');
  static final _unit = RegExp(r'(kg|lb|oz|g)\b', caseSensitive: false);

  static WeightReading? parseLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return null;
    final m = _number.firstMatch(text);
    if (m == null) return null;
    final value = double.tryParse(m.group(0)!);
    if (value == null) return null;
    final unit = _unit.firstMatch(text.substring(m.end))?.group(1)?.toLowerCase();
    final grams = switch (unit) {
      'kg' => value * 1000,
      'lb' => value * 453.59237,
      'oz' => value * 28.349523125,
      _ => value,
    };
    // 只有秤明確說 ST 才算穩定;純數字協定沒有旗標,交給連續讀數判斷。
    final upper = text.toUpperCase();
    final stable = upper.contains('ST') && !upper.contains('US');
    return WeightReading(
      grams: grams,
      stable: stable,
      at: DateTime.now(),
      raw: text,
    );
  }
}

/// 秤重服務:提供即時讀數與「等到穩定再取值」。
class ScaleService {
  ScaleService(this.reader, {required this.settings});

  final ScaleReader reader;
  final ScaleSettings settings;

  bool get enabled => settings.enabled;

  /// 即時讀數 (硬體設定頁顯示用)。
  Stream<WeightReading> get readings => reader.readings();

  /// 等待穩定讀數:連續 [window] 筆落在 [toleranceG] 內,或秤連續回報穩定。
  /// 逾時回傳最後一筆 (標記為不穩定);完全沒有讀數時回 null。
  Future<WeightReading?> readStable({
    Duration timeout = AppConstants.scaleStableTimeout,
    int window = AppConstants.scaleStableWindow,
    double toleranceG = AppConstants.scaleStableToleranceG,
  }) async {
    if (!enabled) return null;
    final completer = Completer<WeightReading?>();
    final recent = <WeightReading>[];
    WeightReading? last;
    var deviceStable = 0;
    late final StreamSubscription<WeightReading> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(last?.copyWith(stable: false));
      }
    });

    void finish(WeightReading r) {
      if (completer.isCompleted) return;
      completer.complete(r);
    }

    sub = reader.readings().listen(
      (r) {
        last = r;
        recent.add(r);
        if (recent.length > window) recent.removeAt(0);
        deviceStable = r.stable ? deviceStable + 1 : 0;
        final stable = detectStable(
          recent,
          window: window,
          toleranceG: toleranceG,
        );
        if (stable != null) {
          finish(stable);
        } else if (deviceStable >= 3) {
          finish(r.copyWith(stable: true));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(last);
      },
    );
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  /// 純函式:最近 [window] 筆的最大最小差 ≤ [toleranceG] → 回傳平均值 (穩定)。
  static WeightReading? detectStable(
    List<WeightReading> recent, {
    required int window,
    required double toleranceG,
  }) {
    if (recent.length < window) return null;
    final tail = recent.sublist(recent.length - window);
    var min = double.infinity, max = double.negativeInfinity, sum = 0.0;
    for (final r in tail) {
      min = math.min(min, r.grams);
      max = math.max(max, r.grams);
      sum += r.grams;
    }
    if (max - min > toleranceG) return null;
    return WeightReading(
      grams: sum / tail.length,
      stable: true,
      at: tail.last.at ?? DateTime.now(),
      raw: tail.last.raw,
    );
  }
}
