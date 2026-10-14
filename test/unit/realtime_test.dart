import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/data/api/mock_api_repository.dart';
import 'package:spoonfull_flutter_app/data/models/api_models.dart';
import 'package:spoonfull_flutter_app/services/realtime_service.dart';

import '../helpers/test_services.dart';

/// 可由測試控制的假 WebSocket。
class FakeChannel implements RealtimeChannel {
  final _controller = StreamController<dynamic>();
  final List<String> sent = [];
  @override
  int? closeCode;
  bool closed = false;

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  /// server 送一則訊息。
  void push(Map<String, Object?> body) => _controller.add(jsonEncode(body));

  /// server 關閉連線。
  Future<void> serverClose([int? code]) async {
    closeCode = code;
    await _controller.close();
  }
}

/// 記錄每次連線的 uri / headers,並交出可控制的 [FakeChannel]。
class FakeConnector {
  final List<FakeChannel> channels = [];
  final List<Uri> uris = [];
  final List<Map<String, String>> headers = [];
  Object? failWith;

  Future<RealtimeChannel> call(Uri uri, Map<String, String> h) async {
    uris.add(uri);
    headers.add(h);
    // ignore: only_throw_errors
    if (failWith != null) throw failWith!;
    final channel = FakeChannel();
    channels.add(channel);
    return channel;
  }

  FakeChannel get last => channels.last;
}

/// 數每個查詢 API 被叫幾次。
class CountingApi extends MockApiRepository {
  CountingApi() : super(latency: Duration.zero);
  int rooms = 0;
  int beds = 0;
  int meals = 0;

  (int, int, int) get counts => (rooms, beds, meals);

  void reset() => rooms = beds = meals = 0;

  @override
  Future<RoomsResponse> fetchRooms({String? placeId, int? lastUpdated}) {
    rooms++;
    return super.fetchRooms(placeId: placeId, lastUpdated: lastUpdated);
  }

  @override
  Future<BedsResponse> fetchBeds({
    String? placeId,
    String? roomId,
    int? lastUpdated,
  }) {
    beds++;
    return super.fetchBeds(
      placeId: placeId,
      roomId: roomId,
      lastUpdated: lastUpdated,
    );
  }

  @override
  Future<MealsResponse> fetchMeals({String? placeId}) {
    meals++;
    return super.fetchMeals(placeId: placeId);
  }
}

const _delays = [Duration(seconds: 1), Duration(seconds: 5)];

RealtimeService _service(FakeConnector connector, {String? token = 'tok'}) =>
    RealtimeService(
      baseUrlProvider: () => 'https://server.local:8443/app/',
      tokenProvider: () async => token,
      connector: connector.call,
      reconnectDelays: _delays,
    );

/// 等到條件成立 (真實時間,給非 fakeAsync 的測試用)。
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RealtimeService', () {
    test('connects to ws/machine/ with the bearer token', () async {
      final connector = FakeConnector();
      final service = _service(connector);
      service.start();
      await waitFor(() => service.isConnected);

      expect(
        connector.uris.single.toString(),
        'wss://server.local:8443/app/${AppConstants.machineEventsPath}',
      );
      expect(connector.headers.single, {'Authorization': 'Bearer tok'});
      await service.dispose();
    });

    test('emits data_changed and ignores other messages', () async {
      final connector = FakeConnector();
      final service = _service(connector);
      final events = <DataChangedEvent>[];
      service.events.listen(events.add);
      service.start();
      await waitFor(() => service.isConnected);

      connector.last.push({'event': 'connected', 'device_id': 'd'});
      connector.last.push({'event': 'pong'});
      connector.last.push({'event': 'data_changed', 'datasets': []});
      connector.last.push({
        'event': 'data_changed',
        'datasets': ['beds', 'rooms'],
        'timestamp': 1700000000,
      });
      await waitFor(() => events.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, hasLength(1));
      expect(events.single.datasets, {'beds', 'rooms'});
      expect(events.single.timestamp, 1700000000);
      await service.dispose();
    });

    test('reconnects with backoff after the server drops the socket', () {
      fakeAsync((async) {
        final connector = FakeConnector();
        final service = _service(connector);
        final states = <bool>[];
        service.connectionChanges.listen(states.add);
        service.start();
        async.flushMicrotasks();
        expect(connector.channels, hasLength(1));
        expect(service.isConnected, isTrue);

        connector.last.serverClose(1006);
        async.flushMicrotasks();
        expect(service.isConnected, isFalse);
        expect(states, [true, false]);

        connector.failWith = Exception('down');
        async.elapse(_delays[0]);
        expect(connector.uris, hasLength(2)); // 1s 後第一次重試 (失敗)
        async.elapse(_delays[1]);
        expect(connector.uris, hasLength(3)); // 5s 後第二次重試 (失敗)
        connector.failWith = null;
        async.elapse(_delays[1]); // 退避封頂在最後一個值
        expect(connector.channels, hasLength(2));
        expect(service.isConnected, isTrue);
        expect(states, [true, false, true]);

        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('4401 stops reconnecting and reports unauthorized', () {
      fakeAsync((async) {
        final connector = FakeConnector();
        final service = _service(connector);
        var unauthorized = 0;
        service.onUnauthorized = () => unauthorized++;
        service.start();
        async.flushMicrotasks();

        connector.last.serverClose(RealtimeService.closeUnauthorized);
        async.flushMicrotasks();
        expect(unauthorized, 1);
        async.elapse(const Duration(minutes: 5));
        expect(connector.uris, hasLength(1));
        expect(service.isConnected, isFalse);

        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('stop closes the socket and prevents reconnects', () {
      fakeAsync((async) {
        final connector = FakeConnector();
        final service = _service(connector);
        service.start();
        async.flushMicrotasks();
        service.stop();
        async.flushMicrotasks();
        expect(connector.last.closed, isTrue);
        expect(service.isConnected, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(connector.uris, hasLength(1));

        service.dispose();
        async.flushMicrotasks();
      });
    });

    test('waits without connecting while there is no token', () {
      fakeAsync((async) {
        final connector = FakeConnector();
        final service = _service(connector, token: null);
        service.start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(connector.uris, isEmpty);
        expect(service.isConnected, isFalse);

        service.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('SyncService + realtime', () {
    late TestEnv env;
    late CountingApi api;
    late FakeConnector connector;

    setUp(() async {
      api = CountingApi();
      connector = FakeConnector();
      env = await createTestEnv(
        api: api,
        prefs: configuredPrefs,
        realtime: _service(connector),
      );
      await env.services.pairing.pair(MockApiRepository.validPairingCode);
    });

    tearDown(() => env.dispose());

    test('connecting after start forces a full refresh', () async {
      await env.services.sync.start();
      await waitFor(() => api.counts == (1, 1, 1));
      expect(connector.channels, hasLength(1));
      expect(env.services.sync.realtimeConnected, isTrue);
      await waitFor(
        () => env.services.storage.lastUpdated('meals') != null,
      );
      expect(await env.services.storage.getRooms('demo'), isNotEmpty);
    });

    test('data_changed refreshes only the listed datasets, debounced',
        () async {
      await env.services.sync.start();
      await waitFor(() => api.counts == (1, 1, 1));
      await waitFor(
        () => env.services.storage.lastUpdated('meals') != null,
      );
      api.reset();

      // 兩個事件落在 debounce 視窗內 → 合併成一次 rooms + beds 重抓,meals 不動。
      connector.last.push({
        'event': 'data_changed',
        'datasets': ['beds'],
        'timestamp': 1,
      });
      connector.last.push({
        'event': 'data_changed',
        'datasets': ['rooms', 'beds'],
        'timestamp': 2,
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(api.counts, (0, 0, 0)); // 還在 debounce 視窗內
      await waitFor(() => api.counts == (1, 1, 0));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.counts, (1, 1, 0));

      connector.last.push({
        'event': 'data_changed',
        'datasets': ['meals'],
        'timestamp': 3,
      });
      await waitFor(() => api.counts == (1, 1, 1));
    });

    test('setPaired(false) closes the socket; setPaired(true) reopens it',
        () async {
      await env.services.sync.start();
      await waitFor(() => env.services.sync.realtimeConnected);

      await env.services.sync.setPaired(false);
      expect(env.services.sync.realtimeConnected, isFalse);
      expect(connector.last.closed, isTrue);

      await env.services.sync.setPaired(true);
      await waitFor(() => connector.channels.length == 2);
      expect(env.services.sync.realtimeConnected, isTrue);
    });
  });
}
