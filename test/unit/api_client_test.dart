import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/data/api/api_client.dart';
import 'package:spoonfull_flutter_app/data/api/api_repository.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';

ApiClient _client(
  MockClientHandler handler, {
  void Function()? onUnauthorized,
}) => ApiClient(
  baseUrlProvider: () => 'http://server.local:8080/',
  httpClient: MockClient(handler),
  interceptors: [
    AuthInterceptor(() async => 'tok-123'),
    UnauthorizedInterceptor(onUnauthorized ?? () {}),
  ],
);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('adds bearer token and parses rooms', () async {
    late http.Request captured;
    final repo = HttpApiRepository(
      _client((req) async {
        captured = req;
        return _json({
          'success': true,
          'data': {
            'rooms': [
              {
                'place_id': 'A',
                'room_id': 'R1',
                'room_name': '101',
                'beds_count': 3,
                'updated_at': 100,
              },
            ],
            'timestamp': 200,
          },
        }, 200);
      }),
    );

    final res = await repo.fetchRooms(placeId: 'A', lastUpdated: 50);

    expect(captured.headers['Authorization'], 'Bearer tok-123');
    expect(captured.url.path, '/api/machine/rooms/');
    expect(captured.url.queryParameters, {
      'place_id': 'A',
      'last_updated': '50',
    });
    expect(res.rooms.single.roomName, '101');
    expect(res.timestamp, 200);
  });

  test('pairing request is sent without Authorization header', () async {
    late http.Request captured;
    final repo = HttpApiRepository(
      _client((req) async {
        captured = req;
        return _json({
          'success': true,
          'data': {'device_id': 'd', 'device_token': 't', 'expires_in': 10},
        }, 200);
      }),
    );
    final r = await repo.pairDevice(
      deviceId: 'd',
      deviceName: 'n',
      location: 'l',
      pairingCode: '123456',
    );
    expect(captured.headers.containsKey('Authorization'), isFalse);
    expect(captured.headers.containsKey(ApiClient.skipAuthHeader), isFalse);
    expect(jsonDecode(captured.body)['pairing_code'], '123456');
    expect(r.deviceToken, 't');
    expect(r.expiresIn, 10);
  });

  group('error mapping (spec 6.1)', () {
    Future<AppException> errorFor(int status, [Object? body]) async {
      final client = _client((_) async => _json(body ?? {}, status));
      try {
        await client.get('x');
      } on AppException catch (e) {
        return e;
      }
      fail('expected exception');
    }

    test('401 → unauthorized and notifies', () async {
      var notified = false;
      final client = _client(
        (_) async => _json({}, 401),
        onUnauthorized: () => notified = true,
      );
      await expectLater(
        client.get('x'),
        throwsA(
          isA<AppException>().having(
            (e) => e.type,
            'type',
            AppErrorType.unauthorized,
          ),
        ),
      );
      expect(notified, isTrue);
    });

    test('TOKEN_EXPIRED code → unauthorized', () async {
      final e = await errorFor(400, {
        'success': false,
        'error': {'code': 'TOKEN_EXPIRED', 'message': 'expired'},
      });
      expect(e.type, AppErrorType.unauthorized);
    });

    test('403 envelope → forbidden, not retryable', () async {
      final e = await errorFor(403, {
        'success': false,
        'error': {'code': 'FORBIDDEN', 'message': '無權限'},
      });
      expect(e.type, AppErrorType.forbidden);
      expect(e.isRetryable, isFalse);
    });

    test('422 → validation', () async {
      expect((await errorFor(422)).type, AppErrorType.validation);
    });

    test('400 carries server code/message', () async {
      final e = await errorFor(400, {
        'success': false,
        'error': {'code': 'INVALID_BED_ID', 'message': '床位ID無效'},
      });
      expect(e.type, AppErrorType.client);
      expect(e.code, 'INVALID_BED_ID');
      expect(e.message, '床位ID無效');
    });

    test('500 → server, retryable', () async {
      final e = await errorFor(503);
      expect(e.type, AppErrorType.server);
      expect(e.isRetryable, isTrue);
    });

    test('connection failure → network, retryable', () async {
      final client = _client((_) async => throw http.ClientException('down'));
      await expectLater(
        client.get('x'),
        throwsA(
          isA<AppException>()
              .having((e) => e.type, 'type', AppErrorType.network)
              .having((e) => e.isRetryable, 'retryable', isTrue),
        ),
      );
    });
  });

  group('retry semantics', () {
    Future<AppException> errorFrom(http.Response response) async {
      final client = _client((_) async => response);
      try {
        await client.get('x');
      } on AppException catch (e) {
        return e;
      }
      fail('expected exception');
    }

    http.Response html(int status) => http.Response(
      '<html><body>Cloudflare</body></html>',
      status,
      headers: {'content-type': 'text/html'},
    );

    Map<String, Object?> envelope(String code, [bool? retryable]) => {
      'success': false,
      'error': {'code': code, 'message': 'm', 'retryable': ?retryable},
    };

    test('server retryable flag wins over the status code', () async {
      final e1 = await errorFrom(_json(envelope('X', true), 422));
      expect(e1.isRetryable, isTrue);
      final e2 = await errorFrom(_json(envelope('X', false), 503));
      expect(e2.isRetryable, isFalse);
    });

    test('older server: 4xx envelope is final, 408/429/5xx retry', () async {
      expect(
        (await errorFrom(_json(envelope('BAD'), 400))).isRetryable,
        isFalse,
      );
      expect((await errorFrom(_json(envelope('V'), 422))).isRetryable, isFalse);
      expect((await errorFrom(_json(envelope('T'), 408))).isRetryable, isTrue);
      expect(
        (await errorFrom(_json(envelope('THROTTLED'), 429))).isRetryable,
        isTrue,
      );
      expect((await errorFrom(_json(envelope('E'), 500))).isRetryable, isTrue);
    });

    test('HTML from a proxy is always retryable and never unpairs', () async {
      var notified = false;
      for (final status in [200, 302, 401, 403, 404, 502, 530]) {
        final client = _client(
          (_) async => html(status),
          onUnauthorized: () => notified = true,
        );
        try {
          await client.get('x');
          fail('expected exception');
        } on AppException catch (e) {
          expect(e.isRetryable, isTrue, reason: 'HTTP $status');
          expect(e.type, isNot(AppErrorType.unauthorized));
          expect(e.statusCode, status);
        }
      }
      expect(notified, isFalse);
    });

    test('JSON body without envelope on 4xx is retryable', () async {
      expect(
        (await errorFrom(_json({'detail': 'x'}, 400))).isRetryable,
        isTrue,
      );
    });

    test('Retry-After seconds are carried on the exception', () async {
      final e = await errorFrom(
        http.Response(
          jsonEncode(envelope('THROTTLED', true)),
          429,
          headers: {'content-type': 'application/json', 'retry-after': '42'},
        ),
      );
      expect(e.code, 'THROTTLED');
      expect(e.retryAfter, const Duration(seconds: 42));
    });

    test('parseRetryAfter accepts seconds and HTTP dates', () {
      expect(ApiClient.parseRetryAfter('7'), const Duration(seconds: 7));
      expect(ApiClient.parseRetryAfter(null), isNull);
      expect(ApiClient.parseRetryAfter('soon'), isNull);
      final now = DateTime.utc(2026, 10, 14, 12);
      expect(
        ApiClient.parseRetryAfter('Wed, 14 Oct 2026 12:01:00 GMT', now: now),
        const Duration(minutes: 1),
      );
    });

    test('socket and TLS errors are retryable network errors', () async {
      for (final error in <IOException>[
        const SocketException('refused'),
        const HandshakeException('bad cert'),
      ]) {
        final client = _client((_) async => throw error);
        await expectLater(
          client.get('x'),
          throwsA(
            isA<AppException>()
                .having((e) => e.type, 'type', AppErrorType.network)
                .having((e) => e.isRetryable, 'retryable', isTrue),
          ),
        );
      }
    });
  });

  group('health check', () {
    test(
      'uses api/machine/health/ without auth and reads server_time',
      () async {
        late http.Request captured;
        final serverTime = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600;
        final client = _client((req) async {
          captured = req;
          return _json({
            'success': true,
            'data': {
              'status': 'ok',
              'server_time': serverTime,
              'api_version': 1,
            },
          }, 200);
        });
        final health = await client.checkHealth();
        expect(captured.url.path, '/api/machine/health/');
        expect(captured.headers.containsKey('Authorization'), isFalse);
        expect(health.reachable, isTrue);
        expect(health.legacy, isFalse);
        expect(health.apiVersion, 1);
        expect(health.hasClockSkew, isTrue, reason: '機台快了 10 分鐘');
        expect(health.clockSkewWarning, contains('快'));
        expect(await client.ping(), isTrue);
      },
    );

    test('small clock difference gives no warning', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final client = _client(
        (_) async => _json({
          'success': true,
          'data': {'status': 'ok', 'server_time': now - 30},
        }, 200),
      );
      final health = await client.checkHealth();
      expect(health.hasClockSkew, isFalse);
      expect(health.clockSkewWarning, isNull);
    });

    test('404 falls back to the old any-response ping', () async {
      final paths = <String>[];
      final client = _client((req) async {
        paths.add(req.url.path);
        return req.url.path.endsWith('health/')
            ? http.Response('<h1>Not Found</h1>', 404)
            : http.Response('hello', 200);
      });
      final health = await client.checkHealth();
      expect(health.legacy, isTrue);
      expect(health.reachable, isTrue);
      expect(paths, ['/api/machine/health/', '/']);
    });

    test('502 from the proxy is unreachable (no fallback)', () async {
      final client = _client(
        (_) async => http.Response('<html>502 Bad Gateway</html>', 502),
      );
      final health = await client.checkHealth();
      expect(health.reachable, isFalse);
      expect(health.legacy, isFalse);
    });
  });

  test('record response flags and meal hints are parsed', () async {
    final repo = HttpApiRepository(
      _client(
        (_) async => _json({
          'success': true,
          'data': {
            'current_slot': 'lunch',
            'time_slots': [
              {
                'time_slot_id': 'lunch',
                'start_time': '11:00',
                'end_time': '13:30',
              },
            ],
            'meals': [
              {
                'meal_id': '7',
                'meal_name': '軟食',
                'meal_type': 'lunch',
                'meal_time_slot': 'lunch',
                'assigned_patient_ids': ['12', 13],
              },
            ],
            'timestamp': 5,
          },
        }, 200),
      ),
    );
    final res = await repo.fetchMeals();
    expect(res.currentSlot, 'lunch');
    expect(res.meals.single.mealTimeSlot, 'lunch');
    expect(res.meals.single.assignedPatientIds, ['12', '13']);
    expect(res.meals.single.isAssignedTo('13'), isTrue);

    final result = MealRecordResult.fromJson({
      'record_id': '9',
      'duplicate': true,
      'assignment_mismatch': false,
      'bed_mismatch': true,
    });
    expect(result.duplicate, isTrue);
    expect(result.assignmentMismatch, isFalse);
    expect(result.bedMismatch, isTrue);
    expect(MealRecordResult.fromJson({'record_id': '1'}).bedMismatch, isFalse);
  });
}
