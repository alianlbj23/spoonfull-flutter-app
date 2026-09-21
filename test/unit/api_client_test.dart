import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/data/api/api_client.dart';
import 'package:spoonfull_flutter_app/data/api/api_repository.dart';

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
    expect(captured.url.path, '/work/api/room_data.php');
    expect(captured.url.queryParameters, {'place_id': 'A', 'last_updated': '50'});
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

    test('403 → forbidden, not retryable', () async {
      final e = await errorFor(403);
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
}
