import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../config/app_constants.dart';
import '../core/utils/logger.dart';
import 'connectivity_service.dart';

/// Release 裡的 `version.json` (由 .github/workflows/build.yml 產生)。
class UpdateManifest {
  const UpdateManifest({required this.build, required this.assets});

  /// 遞增的版本編號 (GitHub Actions 的 run number),與 [AppConfig.buildNumber] 比較。
  final int build;

  /// 平台 (`linux-arm64` / `linux-x64` / `windows-x64`) → 安裝檔。
  final Map<String, UpdateAsset> assets;

  factory UpdateManifest.parse(String body) {
    final json = (jsonDecode(body) as Map).cast<String, Object?>();
    final assets = (json['assets'] as Map).cast<String, Object?>();
    return UpdateManifest(
      build: (json['build'] as num).toInt(),
      assets: {
        for (final e in assets.entries)
          e.key: UpdateAsset(
            file: (e.value as Map)['file'] as String,
            sha256: ((e.value as Map)['sha256'] as String).toLowerCase(),
          ),
      },
    );
  }
}

class UpdateAsset {
  const UpdateAsset({required this.file, required this.sha256});
  final String file;
  final String sha256;
}

enum UpdateStatus {
  idle,

  /// 正在下載新版。
  downloading,

  /// 新版已下載並驗證,等 App 閒置後安裝。
  ready,

  /// 正在替換檔案,即將重新啟動 (畫面顯示更新提示)。
  installing,
}

/// 解壓縮 [archive] 到 [target] (預設用系統的 `tar`,Windows 10 以上內建且可解 zip)。
typedef UpdateExtractor = Future<void> Function(File archive, Directory target);

Future<void> _tarExtract(File archive, Directory target) async {
  final r = await Process.run('tar', ['-xf', archive.path, '-C', target.path]);
  if (r.exitCode != 0) {
    throw StateError('tar failed (${r.exitCode}): ${r.stderr}');
  }
}

/// 自動更新:啟動時、網路恢復時與定時檢查 Release 的 `version.json`,
/// 有較新的版本就下載、驗證 SHA-256、替換安裝目錄的檔案並重新啟動。
///
/// 只在 CI 編譯的版本 ([AppConfig.buildNumber] > 0) 且安裝目錄可寫入時啟用;
/// 本機 `flutter run` 不會自我更新。為了不打斷操作,只在沒有拍照 / 上傳、
/// 且使用者一段時間沒有碰螢幕時才安裝;剛啟動時視為閒置,會立即安裝。
///
/// 壞版本的退路:安裝時被換掉的舊檔會改名成 `*.spoonfull-old` 留著,新版順利
/// 跑滿 [healthyAfter] ([confirmHealthy]) 才刪除。在那之前:
/// - 安裝到一半失敗 → 當場換回舊檔;
/// - 安裝到一半斷電 ([inProgressMarker] 還在) → 下次啟動換回舊檔;
/// - 新版一啟動就當掉 → kiosk 服務的 `deploy/spoonfull-recover.sh` 數到第 4 次
///   啟動就換回舊檔,並把這個版本寫進 [badBuildMarker],之後不再安裝它。
class UpdateService {
  UpdateService({
    required this._connectivity,
    int? currentBuild,
    String? baseUrl,
    String? platform,
    Directory? installDir,
    http.Client? client,
    UpdateExtractor? extract,
    this._restart,
    this.idleBeforeRestart = AppConstants.updateIdleBeforeRestart,
    this.installNotice = AppConstants.updateInstallNotice,
    this.healthyAfter = AppConstants.updateHealthyAfter,
  }) : currentBuild = currentBuild ?? AppConfig.buildNumber,
       _baseUrl = baseUrl ?? AppConfig.updateBaseUrl,
       platform = platform ?? detectPlatform(),
       installDir = installDir ?? File(Platform.resolvedExecutable).parent,
       _client = client ?? http.Client(),
       _extract = extract ?? _tarExtract;

  /// 被換掉的舊檔改成這個副檔名 (Windows 無法覆蓋執行中的檔案,但可以改名),
  /// 新版確認正常後才刪除。
  static const String oldSuffix = '.spoonfull-old';

  /// 正在替換檔案;啟動時還在代表上次安裝被中斷 (斷電)。
  static const String inProgressMarker = '.update-in-progress';

  /// 新版已裝好但還沒確認正常;內容是新版的 build。
  static const String pendingMarker = '.update-pending';

  /// 被退回的版本 (內容是 build),不再安裝。
  static const String badBuildMarker = '.update-bad-build';

  /// `deploy/spoonfull-recover.sh` 的啟動計數;存在代表機台有裝這支腳本。
  static const String bootCountFile = '.boot-count';
  static const String _stagingName = '.update';

  /// 同一次執行中安裝失敗這麼多次就不再嘗試,避免更新提示一直跳出來擋住操作。
  static const int _maxInstallFailures = 3;

  final ConnectivityService _connectivity;
  final int currentBuild;
  final String _baseUrl;
  final String? platform;
  final Directory installDir;
  final http.Client _client;
  final UpdateExtractor _extract;
  final Future<void> Function()? _restart;
  final Duration idleBeforeRestart;
  final Duration installNotice;
  final Duration healthyAfter;

  /// 正在拍照或上傳時回傳 true,這時不會安裝更新。
  bool Function() isBusy = () => false;

  /// 重新啟動前的收尾 (關閉資料庫等)。
  Future<void> Function()? onBeforeRestart;

  final ValueNotifier<UpdateStatus> status = ValueNotifier(UpdateStatus.idle);

  StreamSubscription<bool>? _sub;
  Timer? _timer;
  Timer? _retry;
  Timer? _healthy;
  bool _running = false;
  Directory? _staged;
  int _stagedBuild = 0;
  int _installFailures = 0;
  DateTime? _lastActivity;

  static String? detectPlatform() {
    if (kIsWeb) return null;
    final abi = Abi.current();
    if (abi == Abi.linuxArm64) return 'linux-arm64';
    if (abi == Abi.linuxX64) return 'linux-x64';
    if (abi == Abi.windowsX64) return 'windows-x64';
    return null;
  }

  Directory get _stagingDir => Directory(p.join(installDir.path, _stagingName));

  late final bool enabled = _checkEnabled();

  bool _checkEnabled() {
    if (currentBuild <= 0) {
      Log.i('auto-update off: not a CI build');
      return false;
    }
    if (platform == null) {
      Log.i('auto-update off: unsupported platform');
      return false;
    }
    try {
      final probe = File(p.join(installDir.path, '.update-probe'));
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      Log.e('auto-update off: ${installDir.path} is not writable');
      return false;
    }
  }

  /// 使用者碰了螢幕:延後安裝,避免操作到一半重新啟動。
  void noteActivity() => _lastActivity = DateTime.now();

  File _marker(String name) => File(p.join(installDir.path, name));

  int? _readBuild(String name) {
    try {
      final f = _marker(name);
      return f.existsSync() ? int.tryParse(f.readAsStringSync().trim()) : null;
    } on FileSystemException {
      return null;
    }
  }

  /// 剛裝好的版本還沒確認正常 (舊檔還留著)。
  bool get hasUnconfirmedUpdate =>
      enabled && _marker(pendingMarker).existsSync();

  /// 機台有裝 `spoonfull-recover.sh`:啟動失敗時結束程序,腳本數到上限就會退回舊版。
  bool get rollbackSupervised =>
      hasUnconfirmedUpdate && _marker(bootCountFile).existsSync();

  void start() {
    if (!enabled) return;
    _recoverInterrupted();
    _cleanLeftovers();
    _sub = _connectivity.onStatusChange.listen((online) {
      if (online) unawaited(check());
    });
    _timer = Timer.periodic(
      AppConstants.updateCheckInterval,
      (_) => unawaited(check()),
    );
    unawaited(check());
  }

  /// 檢查一次;有新版就下載,閒置時安裝並重新啟動。失敗只記 log,下次再試。
  Future<void> check() async {
    if (!enabled || _running) return;
    if (_installFailures >= _maxInstallFailures) return;
    _running = true;
    try {
      if (_staged == null) {
        final manifest = await _fetchManifest();
        if (manifest.build <= currentBuild) return;
        if (manifest.build == _readBuild(badBuildMarker)) {
          Log.i('update: build ${manifest.build} was rolled back, skipping');
          return;
        }
        final asset = manifest.assets[platform];
        if (asset == null) return;
        Log.i('update: build ${manifest.build} available (have $currentBuild)');
        status.value = UpdateStatus.downloading;
        _staged = await _download(asset);
        _stagedBuild = manifest.build;
        status.value = UpdateStatus.ready;
      }
      await _installWhenIdle();
    } on Object catch (e) {
      Log.e('update check failed', e);
      if (_staged == null) status.value = UpdateStatus.idle;
    } finally {
      _running = false;
    }
  }

  bool get _idle {
    if (isBusy()) return false;
    final last = _lastActivity;
    return last == null || DateTime.now().difference(last) >= idleBeforeRestart;
  }

  Future<void> _installWhenIdle() async {
    if (!_idle) {
      _retry ??= Timer(AppConstants.updateIdleRetry, () {
        _retry = null;
        unawaited(check());
      });
      return;
    }
    status.value = UpdateStatus.installing;
    // 讓使用者看到更新提示;提示會擋住觸控,這段時間不會開始新的操作。
    await Future<void>.delayed(installNotice);
    try {
      _install(_staged!, _stagedBuild);
    } on Object {
      // 檔案已換回舊版。拿掉提示讓使用者繼續操作,下次檢查重新下載。
      _installFailures++;
      _staged = null;
      _cleanLeftovers();
      status.value = UpdateStatus.idle;
      rethrow;
    }
    Log.i('update installed, restarting');
    try {
      await onBeforeRestart?.call().timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      Log.e('pre-restart cleanup failed', e);
    }
    await (_restart ?? _defaultRestart)();
  }

  Uri _url(String file) => Uri.parse(_baseUrl).resolve(file);

  Future<UpdateManifest> _fetchManifest() async {
    final res = await _client
        .get(_url('version.json'))
        .timeout(AppConstants.requestTimeout);
    if (res.statusCode != 200) {
      throw HttpException('version.json: HTTP ${res.statusCode}');
    }
    return UpdateManifest.parse(utf8.decode(res.bodyBytes));
  }

  /// 下載、驗證並解壓縮到安裝目錄下的暫存資料夾 (同一個檔案系統,之後才能直接改名)。
  /// 回傳新版檔案的根目錄。
  Future<Directory> _download(UpdateAsset asset) async {
    final staging = _stagingDir;
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    try {
      final archive = File(p.join(staging.path, p.basename(asset.file)));
      final res = await _client
          .send(http.Request('GET', _url(asset.file)))
          .timeout(AppConstants.requestTimeout);
      if (res.statusCode != 200) {
        throw HttpException('${asset.file}: HTTP ${res.statusCode}');
      }
      await res.stream
          .pipe(archive.openWrite())
          .timeout(AppConstants.updateDownloadTimeout);

      // Release 的檔案是一個一個換的:檔案與 version.json 不一致時這裡會擋下,下次再試。
      final digest = (await sha256.bind(archive.openRead()).first).toString();
      if (digest != asset.sha256) {
        throw StateError('${asset.file}: checksum mismatch');
      }

      final files = Directory(p.join(staging.path, 'files'))..createSync();
      await _extract(archive, files);
      archive.deleteSync();
      // Linux 的壓縮檔最外層是 bundle/,Windows 的 zip 沒有。
      final bundle = Directory(p.join(files.path, 'bundle'));
      final root = bundle.existsSync() ? bundle : files;
      if (!Directory(p.join(root.path, 'data')).existsSync()) {
        throw StateError('${asset.file}: not an app bundle');
      }
      return root;
    } on Object {
      try {
        staging.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// 把新版檔案逐一改名到安裝目錄,被換掉的舊檔留成 `*.spoonfull-old`。
  /// 執行中的程式仍使用舊檔,重新啟動後才換成新版。中途失敗會把已換的檔案換回去。
  void _install(Directory root, int build) {
    // 上一個版本還沒確認就又要更新:它能活到下載完新版,拿它當這次的退路。
    _commit();
    final marker = _marker(inProgressMarker)..writeAsStringSync('$build');
    final moved = <(File, File?)>[];
    try {
      for (final entity in root.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final dest = File(
          p.join(installDir.path, p.relative(entity.path, from: root.path)),
        );
        dest.parent.createSync(recursive: true);
        final old = dest.existsSync()
            ? dest.renameSync('${dest.path}$oldSuffix')
            : null;
        moved.add((dest, old));
        entity.renameSync(dest.path);
      }
      marker.renameSync(_marker(pendingMarker).path);
    } on Object catch (e) {
      Log.e('update install failed, restoring previous files', e);
      for (final (dest, old) in moved.reversed) {
        try {
          if (dest.existsSync()) dest.deleteSync();
          old?.renameSync(dest.path);
        } on FileSystemException catch (e) {
          Log.e('update: cannot restore ${dest.path}', e);
        }
      }
      try {
        marker.deleteSync();
      } on FileSystemException catch (_) {}
      rethrow;
    }
    _staged = null;
    try {
      _stagingDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  Iterable<File> _oldFiles() => installDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.endsWith(oldSuffix));

  /// 目前的版本確認正常:刪掉留著當退路的舊檔與標記。
  void _commit() {
    try {
      for (final f in _oldFiles()) {
        f.deleteSync();
      }
      for (final name in const [pendingMarker, bootCountFile]) {
        final f = _marker(name);
        if (f.existsSync()) f.deleteSync();
      }
    } on FileSystemException catch (e) {
      Log.i('update commit: $e');
    }
  }

  /// App 已正常啟動:[healthyAfter] 之後確認這個版本,刪掉舊檔。
  /// 由 main() 在服務都建立成功後呼叫;啟動失敗時不呼叫,舊檔留著當退路。
  void confirmHealthy() {
    if (!enabled) return;
    _healthy?.cancel();
    _healthy = Timer(healthyAfter, () {
      if (hasUnconfirmedUpdate) Log.i('update: build $currentBuild confirmed');
      _commit();
    });
  }

  /// 上次安裝到一半被中斷 (斷電):把舊檔換回去。kiosk 服務的
  /// `spoonfull-recover.sh` 會在 App 啟動前先做;這裡是沒有那支腳本時的備援。
  void _recoverInterrupted() {
    final marker = _marker(inProgressMarker);
    try {
      if (!marker.existsSync()) return;
      Log.e('update: previous install was interrupted, restoring old files');
      for (final old in _oldFiles().toList()) {
        final dest = old.path.substring(0, old.path.length - oldSuffix.length);
        try {
          old.renameSync(dest);
        } on FileSystemException catch (e) {
          Log.e('update: cannot restore $dest', e);
        }
      }
      marker.deleteSync();
    } on FileSystemException catch (e) {
      Log.i('update recovery: $e');
    }
  }

  /// 清掉上次更新留下的暫存資料夾。
  void _cleanLeftovers() {
    try {
      if (_stagingDir.existsSync()) _stagingDir.deleteSync(recursive: true);
    } on FileSystemException catch (e) {
      Log.i('update cleanup: $e');
    }
  }

  /// kiosk 服務 (`SPOONFULL_SUPERVISED=1`,`Restart=always`) 會自己把 App 帶起來;
  /// 其他情況先啟動新的程序再結束。
  Future<void> _defaultRestart() async {
    if (Platform.environment['SPOONFULL_SUPERVISED'] != '1') {
      await Process.start(
        Platform.resolvedExecutable,
        const [],
        workingDirectory: installDir.path,
        mode: ProcessStartMode.detached,
      );
    }
    exit(0);
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _retry?.cancel();
    _healthy?.cancel();
    await _sub?.cancel();
    _client.close();
  }
}
