import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../../config/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/logger.dart';

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

  /// 確認伺服器是否可連線:只要有任何 HTTP 回應就視為可達。
  Future<bool> ping() async {
    try {
      await _http
          .get(_uri(''))
          .timeout(AppConstants.healthCheckTimeout);
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
    throw _fail(request, _mapError(response.statusCode, body));
  }

  AppException _fail(http.BaseRequest request, AppException error) {
    for (final i in _interceptors) {
      i.onError(request, error);
    }
    return error;
  }

  static AppException _mapError(int status, Map<String, Object?>? body) {
    final err = body?['error'];
    final code = err is Map ? err['code']?.toString() : null;
    final message = err is Map ? err['message']?.toString() : null;

    if (status == 401 || code == 'TOKEN_EXPIRED') {
      return AppException(
        AppErrorType.unauthorized,
        message ?? '認證失敗,需要重新配對',
        code: code,
        statusCode: status,
      );
    }
    if (status == 403) {
      return AppException(
        AppErrorType.forbidden,
        message ?? '無權限操作此資源',
        code: code,
        statusCode: status,
      );
    }
    if (status == 422) {
      return AppException(
        AppErrorType.validation,
        message ?? '資料驗證失敗',
        code: code,
        statusCode: status,
      );
    }
    if (status >= 500) {
      return AppException(
        AppErrorType.server,
        message ?? '伺服器故障,請稍後重試',
        code: code,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return AppException(
        AppErrorType.client,
        message ?? '請求參數錯誤',
        code: code,
        statusCode: status,
      );
    }
    // 2xx 但 success != true 或無法解析
    if (code != null) {
      return AppException(
        AppErrorType.client,
        message ?? code,
        code: code,
        statusCode: status,
      );
    }
    return AppException(
      AppErrorType.parse,
      '伺服器回應格式錯誤',
      statusCode: status,
    );
  }

  void close() => _http.close();
}
