import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spoonfull_flutter_app/config/app_config.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/core/utils/server_address.dart';
import 'package:spoonfull_flutter_app/core/utils/validators.dart';
import 'package:spoonfull_flutter_app/data/local/preferences_storage.dart';
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
  test('hardware id is 1–128 chars of A-Za-z0-9._:-', () {
    expect(
      () => Validators.hardwareId('3f1c2a9e-8b7d-4e21-9c55-0a1b2c3d4e5f'),
      returnsNormally,
    );
    expect(() => Validators.hardwareId('pi.local:01'), returnsNormally);
    expect(() => Validators.hardwareId('a' * 128), returnsNormally);
    expect(() => Validators.hardwareId(''), _throwsValidation);
    expect(() => Validators.hardwareId('a' * 129), _throwsValidation);
    expect(() => Validators.hardwareId('bad id'), _throwsValidation);
    expect(() => Validators.hardwareId('機台'), _throwsValidation);
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
    expect(
      Validators.detectMime(Uint8List.fromList([0x47, 0x49, 0x46])),
      isNull,
    );
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
      const ServerSettings(
        host: '10.0.0.5',
        port: '8080',
        placeId: 'A',
      ).baseUrl,
      'http://10.0.0.5:8080/',
    );
    expect(
      const ServerSettings(
        host: 'https://api.example.com/',
        port: '443',
      ).baseUrl,
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

  group('ServerAddress', () {
    String? url(String input, [String port = '']) =>
        ServerAddress.resolve(input, port: port).baseUrl;
    String? error(String input, [String port = '']) =>
        ServerAddress.resolve(input, port: port).error;

    test('full URLs keep scheme, default the port, add a trailing slash', () {
      expect(
        url('https://foodintakesystem.com'),
        'https://foodintakesystem.com/',
      );
      expect(
        url('  https://foodintakesystem.com/  '),
        'https://foodintakesystem.com/',
      );
      expect(url('http://192.168.1.10:8000'), 'http://192.168.1.10:8000/');
      expect(url('https://example.org/app'), 'https://example.org/app/');
    });

    test('bare host: LAN → http, public → https', () {
      expect(url('192.168.1.10'), 'http://192.168.1.10/');
      expect(url('10.0.0.5', '8080'), 'http://10.0.0.5:8080/');
      expect(url('172.20.1.1:8000'), 'http://172.20.1.1:8000/');
      expect(url('localhost:8000'), 'http://localhost:8000/');
      expect(url('spoon-server.local'), 'http://spoon-server.local/');
      expect(url('foodintakesystem.com'), 'https://foodintakesystem.com/');
      expect(url('8.8.8.8'), 'https://8.8.8.8/');
      expect(url('172.32.0.1'), 'https://172.32.0.1/', reason: '不在 172.16/12');
    });

    test('port field is used only when the URL has none', () {
      expect(url('https://example.org', '8443'), 'https://example.org:8443/');
      expect(url('http://10.0.0.5:8000', '9000'), 'http://10.0.0.5:8000/');
      expect(error('10.0.0.5', '70000'), isNotNull);
      expect(error('10.0.0.5', 'abc'), isNotNull);
    });

    test('http to a public host is rejected with a Chinese message', () {
      final r = ServerAddress.resolve('http://foodintakesystem.com');
      expect(r.isValid, isFalse);
      expect(r.error, contains('https://'));
      expect(
        ServerAddress.resolve(
          'http://foodintakesystem.com',
          allowInsecurePublic: true,
        ).baseUrl,
        'http://foodintakesystem.com/',
      );
      expect(ServerAddress.resolve('http://192.168.0.2').isValid, isTrue);
    });

    test('garbage and unsupported schemes are rejected', () {
      expect(error(''), isNotNull);
      expect(error('ftp://example.org'), isNotNull);
      expect(error('http://'), isNotNull);
    });

    test('private host detection', () {
      for (final h in [
        '10.1.2.3',
        '192.168.0.1',
        '127.0.0.1',
        '::1',
        'fd00::1',
        '[fe80::1]',
        'localhost',
        'nas',
        'pi.local',
      ]) {
        expect(ServerAddress.isPrivateHost(h), isTrue, reason: h);
      }
      for (final h in ['1.1.1.1', 'foodintakesystem.com', '2001:db8::1']) {
        expect(ServerAddress.isPrivateHost(h), isFalse, reason: h);
      }
    });

    test('ServerSettings is complete without a port', () {
      const s = ServerSettings(
        host: 'https://foodintakesystem.com',
        placeId: 'A',
      );
      expect(s.isComplete, isTrue);
      expect(s.baseUrl, 'https://foodintakesystem.com/');
    });
  });

  group('stored server settings migration', () {
    Future<PreferencesStorage> prefs(Map<String, Object> values) async {
      SharedPreferences.setMockInitialValues(values);
      return PreferencesStorage(await SharedPreferences.getInstance());
    }

    test('old host + port keeps connecting to the same http URL', () async {
      final p = await prefs({
        'server.host': 'myserver.example.com',
        'server.port': '8000',
        'device_config.location': 'A',
      });
      final s = p.readServerSettings();
      expect(
        s.baseUrl,
        'http://myserver.example.com:8000/',
        reason: '舊版沒寫協定一律 http,升級後不能變成 https',
      );
      expect(s.port, '');
      expect(s.isComplete, isTrue);
      // 已轉成新格式,再讀一次結果相同。
      expect(
        p.readServerSettings().baseUrl,
        'http://myserver.example.com:8000/',
      );
    });

    test('old https form and LAN form keep working', () async {
      final p1 = await prefs({
        'server.host': 'https://api.example.com/',
        'server.port': '8443',
      });
      expect(p1.readServerSettings().baseUrl, 'https://api.example.com:8443/');
      final p2 = await prefs({
        'server.host': '192.168.0.10',
        'server.port': '8080',
      });
      expect(p2.readServerSettings().baseUrl, 'http://192.168.0.10:8080/');
    });

    test('fresh install defaults to the public server', () async {
      final p = await prefs({});
      final s = p.readServerSettings();
      expect(AppConfig.defaultServerHost, 'https://foodintakesystem.com');
      expect(s.host, AppConfig.defaultServerHost);
      expect(s.baseUrl, 'https://foodintakesystem.com/');
      expect(s.isComplete, isFalse, reason: '場域仍要由使用者填');
      // 預設值不寫進偏好,再讀一次仍是預設。
      expect(p.readServerSettings().host, AppConfig.defaultServerHost);
    });

    test('a saved address replaces the default', () async {
      final p = await prefs({});
      await p.writeServerSettings(
        const ServerSettings(host: '192.168.1.10', port: '8000', placeId: 'A'),
      );
      expect(p.readServerSettings().baseUrl, 'http://192.168.1.10:8000/');
    });

    test('fresh install without a place still checks the default server', () {
      // checkServer 只看位址;場域留空時歡迎畫面的伺服器燈號仍有意義。
      const s = ServerSettings(host: 'https://foodintakesystem.com');
      expect(s.baseUrl, isNotNull);
      expect(s.isComplete, isFalse);
    });

    test('a saved empty address is not replaced by the default', () async {
      final p = await prefs({'server.host': '', 'server.config_version': 2});
      expect(p.readServerSettings().host, '');
    });

    test('new-format settings are not rewritten', () async {
      final p = await prefs({});
      await p.writeServerSettings(
        const ServerSettings(host: 'foodintakesystem.com', placeId: 'A'),
      );
      final s = p.readServerSettings();
      expect(s.host, 'foodintakesystem.com');
      expect(s.baseUrl, 'https://foodintakesystem.com/');
    });
  });
}
