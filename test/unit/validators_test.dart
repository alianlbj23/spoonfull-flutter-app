import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/validators.dart';
import 'package:spoonfull_flutter_app/data/models/bed_data.dart';
import 'package:spoonfull_flutter_app/data/models/device_config.dart';
import 'package:spoonfull_flutter_app/data/models/meal_data.dart';

final _throwsValidation = throwsA(
  isA<AppException>().having(
    (e) => e.type,
    'type',
    AppErrorType.localValidation,
  ),
);

BedData _bed(String id, String? patient) => BedData(
  placeId: 'p',
  roomId: 'R1',
  bedId: id,
  bedName: id,
  patientId: patient,
  lastUpdated: 0,
);

void main() {
  test('pairing code must be 6 digits', () {
    expect(() => Validators.pairingCode('123456'), returnsNormally);
    expect(() => Validators.pairingCode('12345'), _throwsValidation);
    expect(() => Validators.pairingCode('1567960410'), _throwsValidation);
    expect(() => Validators.pairingCode('12a456'), _throwsValidation);
  });

  test('image dimensions 480x320 ~ 4000x3000 in either orientation', () {
    expect(() => Validators.dimensions(1920, 1080), returnsNormally);
    expect(() => Validators.dimensions(1080, 1920), returnsNormally);
    expect(() => Validators.dimensions(480, 320), returnsNormally);
    expect(() => Validators.dimensions(400, 300), _throwsValidation);
    expect(() => Validators.dimensions(5000, 3000), _throwsValidation);
  });

  test('MIME detection by magic bytes', () {
    expect(
      Validators.detectMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
      'image/jpeg',
    );
    expect(
      Validators.detectMime(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      ),
      'image/png',
    );
    expect(Validators.detectMime(Uint8List.fromList([0x47, 0x49, 0x46])), isNull);
  });

  test('bed must belong to room and patient must match', () {
    final beds = [_bed('B1', 'P1'), _bed('B2', null)];
    expect(
      () => Validators.bedAndPatient(bed: beds[0], roomBeds: beds),
      returnsNormally,
    );
    expect(
      () => Validators.bedAndPatient(bed: beds[1], roomBeds: beds),
      _throwsValidation,
    );
    expect(
      () => Validators.bedAndPatient(bed: _bed('B9', 'P9'), roomBeds: beds),
      _throwsValidation,
    );
    expect(
      () => Validators.bedAndPatient(bed: _bed('B1', 'OTHER'), roomBeds: beds),
      _throwsValidation,
    );
  });

  test('meal must exist', () {
    final meals = [
      const MealData(
        placeId: 'p',
        mealId: 'M1',
        mealName: 'x',
        mealType: MealType.lunch,
        lastUpdated: 0,
      ),
    ];
    expect(() => Validators.meal('M1', meals), returnsNormally);
    expect(() => Validators.meal('M2', meals), _throwsValidation);
    expect(() => Validators.meal('', meals), _throwsValidation);
  });

  test('ServerSettings builds base URL', () {
    expect(
      const ServerSettings(host: '10.0.0.5', port: '8080', placeId: 'A').baseUrl,
      'http://10.0.0.5:8080/',
    );
    expect(
      const ServerSettings(host: 'https://api.example.com/', port: '443')
          .baseUrl,
      'https://api.example.com/',
    );
    expect(const ServerSettings(host: '').baseUrl, isNull);
    expect(
      const ServerSettings(host: 'a', port: '1', placeId: '').isComplete,
      isFalse,
    );
  });

  test('time slot infers meal type from start time', () {
    TimeSlot slot(String start) => TimeSlot(
      timeSlotId: start,
      timeSlotName: start,
      startTime: start,
      endTime: '23:59',
    );
    expect(slot('07:00').inferredMealType, MealType.breakfast);
    expect(slot('11:30').inferredMealType, MealType.lunch);
    expect(slot('17:00').inferredMealType, MealType.dinner);
    expect(slot('21:30').inferredMealType, MealType.snack);
  });
}
