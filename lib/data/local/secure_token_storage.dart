import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/utils/logger.dart';
import '../models/auth_token.dart';

/// Token 加密儲存 (規格 8.1:不可存在 SharedPreferences 明碼)。
abstract class TokenStorage {
  Future<AuthToken?> read();
  Future<void> write(AuthToken token);
  Future<void> clear();
}

class SecureTokenStorage implements TokenStorage {
  SecureTokenStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'auth_token';
  final FlutterSecureStorage _storage;

  @override
  Future<AuthToken?> read() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return AuthToken.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(AuthToken token) =>
      _storage.write(key: _key, value: jsonEncode(token.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// 檔案儲存 (權限 0600):Linux kiosk 沒有 keyring / libsecret 時的備援。
class FileTokenStorage implements TokenStorage {
  FileTokenStorage({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async {
    final dir = await _directory();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'auth_token.json'));
  }

  @override
  Future<AuthToken?> read() async {
    final f = await _file();
    if (!await f.exists()) return null;
    try {
      return AuthToken.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, Object?>,
      );
    } catch (_) {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(AuthToken token) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(token.toJson()), flush: true);
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', ['600', f.path]);
      } catch (_) {}
    }
  }

  @override
  Future<void> clear() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }
}

/// 先用系統安全儲存;在 Linux kiosk (無 keyring daemon) 失敗時改用檔案儲存。
///
/// ARCHITECTURE.md §5.1:flutter_secure_storage 在 Linux 依賴 keyring,
/// 機台沒有桌面環境時會丟 PlatformException,這裡確保配對狀態不會因此消失。
class FallbackTokenStorage implements TokenStorage {
  FallbackTokenStorage({TokenStorage? primary, TokenStorage? fallback})
    : _primary = primary ?? SecureTokenStorage(),
      _fallback = fallback ?? FileTokenStorage();

  final TokenStorage _primary;
  final TokenStorage _fallback;
  bool _useFallback = false;

  Future<T> _run<T>(
    Future<T> Function(TokenStorage s) op, {
    required String what,
  }) async {
    if (!_useFallback) {
      try {
        return await op(_primary);
      } on PlatformException catch (e) {
        Log.i('secure storage $what failed (${e.message}), using file storage');
      } on MissingPluginException catch (e) {
        Log.i('secure storage unavailable ($e), using file storage');
      }
      _useFallback = true;
    }
    return op(_fallback);
  }

  @override
  Future<AuthToken?> read() => _run((s) => s.read(), what: 'read');

  @override
  Future<void> write(AuthToken token) =>
      _run((s) => s.write(token), what: 'write');

  @override
  Future<void> clear() => _run((s) => s.clear(), what: 'clear');
}

/// 測試用記憶體實作。
class InMemoryTokenStorage implements TokenStorage {
  AuthToken? _token;

  @override
  Future<AuthToken?> read() async => _token;

  @override
  Future<void> write(AuthToken token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}
