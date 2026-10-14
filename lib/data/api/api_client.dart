import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';
import '../models/api_models.dart';

typedef TokenProvider = Future<String?> Function();
typedef BaseUrlProvider = String? Function();

/// HTTP 攔截器 (規格 2 Data Layer:HTTP Interceptors)。
abstract class ApiInterceptor {
  const ApiInterceptor();
  Future<void> onRequest(http.BaseRequest request) async {}
  void onResponse(http.BaseRequest request, http.Response response) {}
  void onError(http.BaseRequest request, AppException error) {}
}

/// Token 管理:每次呼叫讀取 token 並放入 Authorization header (規格 8.1)。
class AuthInterceptor extends ApiInterceptor {
  const AuthInterceptor(this.tokenProvider);
  final TokenProvider tokenProvider;

  @override
  Future<void> onRequest(http.BaseRequest request) async {
    if (request.headers.containsKey(ApiClient.skipAuthHeader)) {
      request.headers.remove(ApiClient.skipAuthHeader);
      return;
    }
    final token = await tokenProvider();
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
  }
}

class LoggingInterceptor extends ApiInterceptor {
  const LoggingInterceptor();

  @override
  Future<void> onRequest(http.BaseRequest request) async =>
      Log.d('→ ${request.method} ${request.url}');

  @override
  void onResponse(http.BaseRequest request, http.Response response) =>
      Log.d('← ${response.statusCode} ${request.url}');

  @override
  void onError(http.BaseRequest request, AppException error) =>
      Log.i('✗ ${request.url} $error');
}

/// 收到 401 / TOKEN_EXPIRED 時通知上層清除 token 並返回配對畫面。
class UnauthorizedInterceptor extends ApiInterceptor {
  const UnauthorizedInterceptor(this.onUnauthorized);
  final void Function() onUnauthorized;

  @override
  void onError(http.BaseRequest request, AppException error) {
    if (error.type == AppErrorType.unauthorized) onUnauthorized();
  }
}

/// 封裝後端統一回應格式 `{success, data, error}`。
class ApiClient {
  ApiClient({
    required this.baseUrlProvider,
    List<ApiInterceptor> interceptors = const [],
    http.Client? httpClient,
  }) : _interceptors = List.unmodifiable(interceptors),
       _http = httpClient ?? http.Client();

  /// 設定此 header 的請求不附帶 Bearer token (例如配對)。
  static const String skipAuthHeader = 'x-skip-auth';

  final BaseUrlProvider baseUrlProvider;
  final List<ApiInterceptor> _interceptors;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrlProvider();
    if (base == null || base.isEmpty) {
      throw const AppException(
        AppErrorType.localValidation,
        '尚未設定伺服器位址',
        code: 'NO_SERVER',
      );
    }
    final uri = Uri.parse(base).resolve(path);
    final q = {...?query}..removeWhere((_, v) => v.isEmpty);
    return q.isEmpty ? uri : uri.replace(queryParameters: q);
  }

  Future<Map<String, Object?>> get(
    String path, {
    Map<String, String>? query,
  }) {
    final request = http.Request('GET', _uri(path, query))
      ..headers['Content-Type'] = 'application/json';
    return _send(request, AppConstants.requestTimeout);
  }

  Future<Map<String, Object?>> postJson(
    String path,
    Map<String, Object?> body, {
    bool authenticated = true,
  }) {
    final request = http.Request('POST', _uri(path))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    if (!authenticated) request.headers[skipAuthHeader] = '1';
    return _send(request, AppConstants.requestTimeout);
  }

  Future<Map<String, Object?>> postMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required List<int> fileBytes,
    required String fileName,
    required String mimeType,
  }) {
    final request = http.MultipartRequest('POST', _uri(path))
      ..fields.addAll(fields)
      ..files.add(
        http.MultipartFile.fromBytes(
          fileField,
          fileBytes,
          filename: fileName,
          contentType: MediaType.parse(mimeType),
        ),
      );
    return _send(request, AppConstants.uploadTimeout);
  }

  /// `GET api/machine/health/` (不需認證)。
  Future<Map<String, Object?>> health() {
    final request = http.Request('GET', _uri(AppConstants.healthPath))
      ..headers[skipAuthHeader] = '1';
    return _send(request, AppConstants.healthCheckTimeout);
  }

  /// 檢查伺服器狀態:優先呼叫 [health];舊版 server 沒有這支 API (404) 時退回
  /// 舊做法 —— 對 BASE_URL 發 GET,有任何 HTTP 回應就算可達。
  Future<ServerHealth> checkHealth() async {
    try {
      final data = await health();
      final result = ServerHealth.fromJson(data, checkedAt: DateTime.now());
      if (result.hasClockSkew) {
        Log.i(
          'clock skew: device is ${result.clockSkew!.inSeconds}s '
          'off server time (server_time=${result.serverTime})',
        );
      }
      return result;
    } on AppException catch (e) {
      if (e.statusCode == 404) {
        Log.i('health endpoint missing (older server), falling back to ping');
        return ServerHealth.legacy(reachable: await _legacyPing());
      }
      return ServerHealth.unreachable(e.message);
    } on Object catch (e) {
      return ServerHealth.unreachable(e.toString());
    }
  }

  /// 伺服器是否可連線 (見 [checkHealth])。
  Future<bool> ping() async => (await checkHealth()).reachable;

  /// 舊版 server:只要有任何 HTTP 回應就視為可達。
  Future<bool> _legacyPing() async {
    try {
      await _http.get(_uri('')).timeout(AppConstants.healthCheckTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, Object?>> _send(
    http.BaseRequest request,
    Duration timeout,
  ) async {
    for (final i in _interceptors) {
      await i.onRequest(request);
    }
    http.Response response;
    try {
      final streamed = await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw _fail(
        request,
        const AppException(AppErrorType.timeout, '連線逾時,請檢查網路'),
      );
    } on http.ClientException catch (e) {
      throw _fail(
        request,
        AppException(AppErrorType.network, '無法連線到伺服器: ${e.message}'),
      );
    } on TlsException catch (e) {
      // 憑證 / 交握失敗 (例如代理換了憑證、機台時鐘錯誤導致憑證「尚未生效」)。
      throw _fail(
        request,
        AppException(AppErrorType.network, '無法建立加密連線: ${e.message}'),
      );
    } on IOException catch (e) {
      // SocketException、HttpException 等,一律當成暫時性的連線問題。
      throw _fail(
        request,
        AppException(AppErrorType.network, '無法連線到伺服器: $e'),
      );
    }
    for (final i in _interceptors) {
      i.onResponse(request, response);
    }

    Map<String, Object?>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) body = decoded.cast<String, Object?>();
    } catch (_) {
      body = null;
    }

    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (ok && body != null && body['success'] == true) {
      final data = body['data'];
      return data is Map ? data.cast<String, Object?>() : <String, Object?>{};
    }
    throw _fail(
      request,
      _mapError(response.statusCode, body, response.headers),
    );
  }

  AppException _fail(http.BaseRequest request, AppException error) {
    for (final i in _interceptors) {
      i.onError(request, error);
    }
    return error;
  }

  /// 把錯誤回應轉成 [AppException]。
  ///
  /// [body] 為 null 代表回應不是 JSON (HTML 錯誤頁、Cloudflare Access 登入頁等),
  /// 那一定不是 app server 自己的答覆:不當成 401 (不會因此解除配對),一律可重試。
  static AppException _mapError(
    int status,
    Map<String, Object?>? body, [
    Map<String, String> headers = const {},
  ]) {
    final retryAfter = parseRetryAfter(headers['retry-after']);
    if (body == null) {
      if (status >= 500) {
        return AppException(
          AppErrorType.server,
          '伺服器故障,請稍後重試',
          statusCode: status,
          retryable: true,
          retryAfter: retryAfter,
        );
      }
      return AppException(
        AppErrorType.parse,
        status >= 200 && status < 300
            ? '伺服器回應格式錯誤'
            : '伺服器回應異常 (HTTP $status),可能被代理或防火牆攔截',
        statusCode: status,
        retryable: true,
        retryAfter: retryAfter,
      );
    }

    final err = body['error'];
    final envelope = err is Map;
    final code = envelope ? err['code']?.toString() : null;
    final message = envelope ? err['message']?.toString() : null;
    final flag = envelope ? err['retryable'] : null;
    // server 明講就照做;舊版 server 沒給時,只有 app server 自己的 4xx 錯誤信封
    // (408 / 429 除外) 不重試。
    final retryable = flag is bool
        ? flag
        : !(envelope &&
              status >= 400 &&
              status < 500 &&
              status != 408 &&
              status != 429);

    AppException make(AppErrorType type, String fallback) => AppException(
      type,
      (message == null || message.isEmpty) ? fallback : message,
      code: code,
      statusCode: status,
      retryable: retryable,
      retryAfter: retryAfter,
    );

    if (status == 401 || code == 'TOKEN_EXPIRED') {
      return make(AppErrorType.unauthorized, '認證失敗,需要重新配對');
    }
    if (status == 403) return make(AppErrorType.forbidden, '無權限操作此資源');
    if (status == 422) return make(AppErrorType.validation, '資料驗證失敗');
    if (status >= 500) return make(AppErrorType.server, '伺服器故障,請稍後重試');
    if (status >= 400) return make(AppErrorType.client, '請求參數錯誤');
    // 2xx / 3xx 但 success != true
    if (code != null) return make(AppErrorType.client, code);
    return AppException(
      AppErrorType.parse,
      '伺服器回應格式錯誤',
      statusCode: status,
      retryable: true,
      retryAfter: retryAfter,
    );
  }

  /// `Retry-After`:秒數或 HTTP 日期;無法解析時回 null。
  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    final v = value?.trim();
    if (v == null || v.isEmpty) return null;
    final seconds = int.tryParse(v);
    if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
    try {
      final at = HttpDate.parse(v);
      final d = at.difference(now ?? DateTime.now());
      return d.isNegative ? Duration.zero : d;
    } on Object {
      return null;
    }
  }

  void close() => _http.close();
}
