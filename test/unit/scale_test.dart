import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/data/models/weight_reading.dart';
import 'package:spoonfull_flutter_app/services/hardware/scale_service.dart';

/// 依序吐出指定讀數的假秤。
class _ScriptedReader extends ScaleReader {
  _ScriptedReader(this.values, {this.interval = Duration.zero});
  final List<WeightReading> values;
  final Duration interval;

  @override
  String get description => 'scripted';

  @override
  Stream<WeightReading> readings() async* {
    for (final v in values) {
      if (interval > Duration.zero) await Future<void>.delayed(interval);
      yield v;
    }
    // 之後維持最後一筆,模擬秤持續回報
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      yield values.last;
    }
  }
}

WeightReading _r(double g, {bool stable = false}) =>
    WeightReading(grams: g, stable: stable);

void main() {
  group('HidScaleReader.parseReport', () {
    test('grams with report id, stable', () {
      // report 3, status 4 (stable), unit 2 (g), exp 0, 0x012C = 300
      final r = HidScaleReader.parseReport([3, 4, 2, 0, 0x2C, 0x01]);
      expect(r, isNotNull);
      expect(r!.grams, 300);
      expect(r.stable, isTrue);
    });

    test('negative exponent and kilograms', () {
      // 1234 * 10^-3 kg = 1.234 kg = 1234 g
      final r = HidScaleReader.parseReport([3, 4, 3, 0xFD, 0xD2, 0x04]);
      expect(r!.grams, closeTo(1234, 0.01));
    });

    test('ounces convert to grams, in-motion is not stable', () {
      // 10.0 oz: raw 100, exp -1, unit 11, status 3 (in motion)
      final r = HidScaleReader.parseReport([3, 3, 11, 0xFF, 100, 0]);
      expect(r!.grams, closeTo(283.5, 0.1));
      expect(r.stable, isFalse);
    });

    test('five-byte report without id and zero status', () {
      final r = HidScaleReader.parseReport([2, 2, 0, 0, 0]);
      expect(r!.grams, 0);
      expect(r.stable, isTrue);
    });

    test('fault / calibration statuses are dropped', () {
      expect(HidScaleReader.parseReport([3, 1, 2, 0, 5, 0]), isNull);
      expect(HidScaleReader.parseReport([3, 7, 2, 0, 5, 0]), isNull);
      expect(HidScaleReader.parseReport([3, 4]), isNull);
    });

    test('splitReports separates concatenated reports', () {
      final chunks = HidScaleReader.splitReports([
        3, 4, 2, 0, 10, 0, //
        3, 4, 2, 0, 20, 0,
      ]).toList();
      expect(chunks, hasLength(2));
      expect(HidScaleReader.parseReport(chunks[1])!.grams, 20);
    });
  });

  group('LineScaleReader.parseLine', () {
    test('serial protocol with ST/US flags and unit', () {
      final stable = LineScaleReader.parseLine('ST,GS,  123.4 g');
      expect(stable!.grams, closeTo(123.4, 0.001));
      expect(stable.stable, isTrue);

      final moving = LineScaleReader.parseLine('US,GS,  120.1 g');
      expect(moving!.grams, closeTo(120.1, 0.001));
      expect(moving.stable, isFalse);
    });

    test('kilograms, pounds and bare numbers', () {
      expect(LineScaleReader.parseLine('0.1234 kg')!.grams, closeTo(123.4, 0.001));
      expect(LineScaleReader.parseLine('1.0 lb')!.grams, closeTo(453.59, 0.01));
      expect(LineScaleReader.parseLine('  -5 ')!.grams, -5);
      expect(LineScaleReader.parseLine('W: 87g')!.grams, 87);
    });

    test('bare numbers are not assumed stable (window decides)', () {
      expect(LineScaleReader.parseLine('123.4')!.stable, isFalse);
      expect(LineScaleReader.parseLine('0.5 kg')!.stable, isFalse);
    });

    test('garbage lines are ignored', () {
      expect(LineScaleReader.parseLine(''), isNull);
      expect(LineScaleReader.parseLine('ready'), isNull);
    });
  });

  group('ScaleService.readStable', () {
    const settings = ScaleSettings(kind: ScaleKind.mock);

    test('returns averaged value once readings settle', () async {
      final service = ScaleService(
        _ScriptedReader([
          _r(100), _r(380), _r(410), // 放上餐盒時晃動
          _r(420.5), _r(419.8), _r(420.1), _r(420.3), _r(419.9),
        ]),
        settings: settings,
      );
      final w = await service.readStable(
        timeout: const Duration(seconds: 2),
        window: 5,
        toleranceG: 2,
      );
      expect(w, isNotNull);
      expect(w!.stable, isTrue);
      expect(w.grams, closeTo(420.1, 0.2));
    });

    test('device-reported stable flag finishes early', () async {
      final service = ScaleService(
        _ScriptedReader([
          _r(300, stable: true),
          _r(300, stable: true),
          _r(300, stable: true),
        ]),
        settings: settings,
      );
      final w = await service.readStable(timeout: const Duration(seconds: 2));
      expect(w!.grams, 300);
      expect(w.stable, isTrue);
    });

    test('times out with last reading marked unstable', () async {
      final values = [for (var i = 0; i < 50; i++) _r(100.0 + (i % 2) * 30)];
      final service = ScaleService(
        _ScriptedReader(values, interval: const Duration(milliseconds: 5)),
        settings: settings,
      );
      final w = await service.readStable(
        timeout: const Duration(milliseconds: 150),
      );
      expect(w, isNotNull);
      expect(w!.stable, isFalse);
    });

    test('disabled scale returns null immediately', () async {
      final service = ScaleService(
        const NoScaleReader(),
        settings: const ScaleSettings(kind: ScaleKind.none),
      );
      expect(await service.readStable(), isNull);
    });

    test('mock reader settles on configured weight', () async {
      final service = ScaleService(
        const MockScaleReader(grams: 512, interval: Duration(milliseconds: 1)),
        settings: const ScaleSettings(kind: ScaleKind.mock, mockWeightG: 512),
      );
      final w = await service.readStable(timeout: const Duration(seconds: 3));
      expect(w!.grams, closeTo(512, 0.01));
      expect(w.stable, isTrue);
    });
  });

  test('detectStable requires a full window within tolerance', () {
    final recent = [_r(1), _r(2), _r(3)];
    expect(
      ScaleService.detectStable(recent, window: 5, toleranceG: 2),
      isNull,
    );
    expect(
      ScaleService.detectStable(
        [_r(10), _r(10.5), _r(9.8), _r(10.2), _r(10.1)],
        window: 5,
        toleranceG: 2,
      )!.grams,
      closeTo(10.12, 0.01),
    );
    expect(
      ScaleService.detectStable(
        [_r(10), _r(30), _r(9.8), _r(10.2), _r(10.1)],
        window: 5,
        toleranceG: 2,
      ),
      isNull,
    );
  });
}
