import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/data/local/secure_token_storage.dart';
import 'package:spoonfull_flutter_app/data/models/auth_token.dart';

/// keyring 是否可用可以在測試中切換。
class _FlakyKeyring extends InMemoryTokenStorage {
  bool available = true;

  void _check() {
    if (!available) throw PlatformException(code: 'keyring unavailable');
  }

  @override
  Future<AuthToken?> read() {
    _check();
    return super.read();
  }

  @override
  Future<void> write(AuthToken token) {
    _check();
    return super.write(token);
  }

  @override
  Future<void> clear() {
    _check();
    return super.clear();
  }
}

void main() {
  late Directory dir;
  const token = AuthToken(deviceToken: 'tok', tokenAcquiredAt: 1);

  setUp(() => dir = Directory.systemTemp.createTempSync('spoonfull_token'));
  tearDown(() => dir.deleteSync(recursive: true));

  FileTokenStorage file() => FileTokenStorage(directory: () async => dir);

  test('file storage round-trips and is only readable by the owner', () async {
    final storage = file();
    await storage.write(token);
    expect((await storage.read())!.deviceToken, 'tok');
    if (Platform.isLinux || Platform.isMacOS) {
      final mode = File('${dir.path}/auth_token.json').statSync().mode;
      expect(mode & 0x3F, 0, reason: 'group / other 不能讀');
    }
    await storage.clear();
    expect(await storage.read(), isNull);
  });

  test(
    'token written while the keyring was down is still found later',
    () async {
      final keyring = _FlakyKeyring()..available = false;
      await FallbackTokenStorage(
        primary: keyring,
        fallback: file(),
      ).write(token);

      // 下次開機 keyring 正常了,但 token 在檔案裡
      keyring.available = true;
      final next = FallbackTokenStorage(primary: keyring, fallback: file());
      expect((await next.read())!.deviceToken, 'tok');

      // 解除配對要兩邊都清
      await next.clear();
      expect(await next.read(), isNull);
      expect(await file().read(), isNull);
    },
  );

  test('writing to the keyring removes a stale file token', () async {
    await file().write(const AuthToken(deviceToken: 'old', tokenAcquiredAt: 1));
    final storage = FallbackTokenStorage(
      primary: _FlakyKeyring(),
      fallback: file(),
    );
    await storage.write(token);
    expect((await storage.read())!.deviceToken, 'tok');
    expect(await file().read(), isNull);
  });
}
