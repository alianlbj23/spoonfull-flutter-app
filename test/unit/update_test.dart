import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:spoonfull_flutter_app/services/connectivity_service.dart';
import 'package:spoonfull_flutter_app/services/update_service.dart';

const _base = 'https://updates.test/latest/';
const _asset = 'spoonfull-linux-x64.tar.gz';

void main() {
  late Directory temp;
  late Directory installDir;
  late List<int> archive;
  late List<String> requests;
  late int restarts;

  /// 目前安裝的「舊版」。
  void writeInstalled() {
    File(p.join(installDir.path, 'app')).writeAsStringSync('old');
    Directory(p.join(installDir.path, 'data')).createSync();
    File(p.join(installDir.path, 'data', 'asset.txt')).writeAsStringSync('old');
    // 不屬於 bundle 的檔案 (例如 hx711_bridge.py) 要留著
    File(p.join(installDir.path, 'keep.txt')).writeAsStringSync('keep');
  }

  /// 用系統 tar 打包一份「新版」bundle,結構與 CI 產生的相同。
  List<int> buildArchive() {
    final bundle = Directory(p.join(temp.path, 'src', 'bundle'))
      ..createSync(recursive: true);
    File(p.join(bundle.path, 'app')).writeAsStringSync('new');
    Process.runSync('chmod', ['755', p.join(bundle.path, 'app')]);
    Directory(p.join(bundle.path, 'data')).createSync();
    File(p.join(bundle.path, 'data', 'asset.txt')).writeAsStringSync('new');
    Directory(p.join(bundle.path, 'lib')).createSync();
    File(p.join(bundle.path, 'lib', 'added.so')).writeAsStringSync('added');
    final out = p.join(temp.path, _asset);
    final r = Process.runSync('tar', [
      '-czf', out, '-C', bundle.parent.path, 'bundle', //
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return File(out).readAsBytesSync();
  }

  UpdateService service({
    required int current,
    required int latest,
    String? checksum,
    Duration idle = Duration.zero,
  }) {
    final manifest = jsonEncode({
      'build': latest,
      'assets': {
        'linux-x64': {
          'file': _asset,
          'sha256': checksum ?? sha256.convert(archive).toString(),
        },
      },
    });
    final service = UpdateService(
      connectivity: FakeConnectivityService(),
      currentBuild: current,
      baseUrl: _base,
      platform: 'linux-x64',
      installDir: installDir,
      client: MockClient((request) async {
        requests.add(request.url.toString());
        return switch (request.url.pathSegments.last) {
          'version.json' => http.Response(manifest, 200),
          _asset => http.Response.bytes(archive, 200),
          _ => http.Response('', 404),
        };
      }),
      restart: () async => restarts++,
      idleBeforeRestart: idle,
      installNotice: Duration.zero,
    );
    addTearDown(service.dispose);
    return service;
  }

  String read(String rel) =>
      File(p.join(installDir.path, rel)).readAsStringSync();

  setUp(() {
    temp = Directory.systemTemp.createTempSync('spoonfull_update');
    installDir = Directory(p.join(temp.path, 'install'))..createSync();
    writeInstalled();
    archive = buildArchive();
    requests = [];
    restarts = 0;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('newer build is downloaded, installed and the app restarts', () async {
    final updates = service(current: 5, latest: 6);
    await updates.check();

    expect(restarts, 1);
    expect(read('app'), 'new');
    expect(read(p.join('data', 'asset.txt')), 'new');
    expect(read(p.join('lib', 'added.so')), 'added');
    expect(read('keep.txt'), 'keep');
    // 執行權限要保留,否則重新啟動會失敗
    final mode = File(p.join(installDir.path, 'app')).statSync().mode;
    expect(mode & 0x49, 0x49, reason: 'app must stay executable');
    expect(Directory(p.join(installDir.path, '.update')).existsSync(), isFalse);
  });

  test('same or older build is left alone', () async {
    for (final latest in [5, 4]) {
      final updates = service(current: 5, latest: latest);
      await updates.check();
    }
    expect(restarts, 0);
    expect(read('app'), 'old');
    expect(requests, everyElement(endsWith('version.json')));
  });

  test('checksum mismatch installs nothing', () async {
    final updates = service(current: 5, latest: 6, checksum: 'deadbeef');
    await updates.check();

    expect(restarts, 0);
    expect(read('app'), 'old');
    expect(updates.status.value, UpdateStatus.idle);
    expect(Directory(p.join(installDir.path, '.update')).existsSync(), isFalse);
  });

  test('install waits while the app is busy', () async {
    final updates = service(current: 5, latest: 6);
    var busy = true;
    updates.isBusy = () => busy;

    await updates.check();
    expect(restarts, 0);
    expect(read('app'), 'old');
    expect(updates.status.value, UpdateStatus.ready);

    busy = false;
    await updates.check();
    expect(restarts, 1);
    expect(read('app'), 'new');
    // 第二次不必重新下載
    expect(requests.where((r) => r.endsWith(_asset)), hasLength(1));
  });

  test('install waits until the user has been idle', () async {
    final updates = service(
      current: 5,
      latest: 6,
      idle: const Duration(hours: 1),
    );
    updates.noteActivity();
    await updates.check();

    expect(restarts, 0);
    expect(updates.status.value, UpdateStatus.ready);
  });

  test('local builds never update themselves', () async {
    final updates = service(current: 0, latest: 6);
    expect(updates.enabled, isFalse);
    await updates.check();
    expect(requests, isEmpty);
  });
}
