import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/depth_image.dart';

/// 模擬 realsense_bridge.py:依參數寫出 RGB / 深度 / meta 三個檔案。
ProcessRunner fakeBridge({
  int exitCode = 0,
  int width = 64,
  int height = 48,
  int? depthWidth,
  bool writeRgb = true,
  bool writeDepth = true,
  bool writeMeta = true,
  String stderr = '',
  void Function(String exe, List<String> args)? onRun,
}) => (exe, args) async {
  onRun?.call(exe, args);
  if (args.contains('--probe')) {
    return ProcessResult(
      1,
      exitCode,
      exitCode == 0
          ? jsonEncode({
              'found': true,
              'serial': '123456789012',
              'name': 'Intel RealSense D435f',
              'firmware': '5.16.0.1',
              'usb_type': '3.2',
            })
          : jsonEncode({'found': false}),
      stderr,
    );
  }
  final i = args.indexOf('--once');
  final rgb = args[i + 1], depth = args[i + 2], meta = args[i + 3];
  if (writeRgb) {
    File(
      rgb,
    ).writeAsBytesSync(img.encodeJpg(MockCameraService.render(width, height)));
  }
  if (writeDepth) {
    File(depth).writeAsBytesSync(
      img.encodePng(MockCameraService.renderDepth(depthWidth ?? width, height)),
    );
  }
  if (writeMeta) {
    File(meta).writeAsStringSync(
      jsonEncode({'serial': '123456789012', 'width': width, 'height': height}),
    );
  }
  return ProcessResult(1, exitCode, '{"serial": "123456789012"}', stderr);
};

void main() {
  late Directory tmp;
  late String bridge;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('spoonfull_rs');
    bridge = p.join(tmp.path, 'realsense_bridge.py');
    File(bridge).writeAsStringSync('# fake');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  RealSenseCameraService service(
    ProcessRunner runner, {
    CameraSettings settings = const CameraSettings(width: 64, height: 48),
    String? bridgePath,
  }) => RealSenseCameraService(
    settings,
    runner: runner,
    bridgePath: bridgePath ?? bridge,
    python: 'python3',
    mock: false,
    environment: const {},
  );

  String out() => p.join(tmp.path, 'out', 'x.jpg.raw');

  test('capture writes RGB, aligned depth PNG and meta', () async {
    late List<String> args;
    final cam = service(fakeBridge(onRun: (_, a) => args = a));
    final raw = (await cam.capture(out()))!;

    expect(args.first, bridge);
    expect(args, containsAllInOrder(['--once', raw.imagePath]));
    expect(args, containsAllInOrder(['--width', '64', '--height', '48']));
    expect(args, isNot(contains('--serial')));
    expect(args, isNot(contains('--mock')));
    expect(raw.imagePath, endsWith('.jpg'));
    expect(raw.depthPath, endsWith('_depth.png'));
    expect(raw.depthMetaPath, endsWith('_depth.json'));
    expect(File(raw.depthPath!).existsSync(), isTrue);

    final header = pngHeader(File(raw.depthPath!).readAsBytesSync());
    expect(header!.bitDepth, 16);
    expect(header.colorType, 0);
    expect((header.width, header.height), (64, 48));

    final stats = DepthStats.analyze(File(raw.depthPath!).readAsBytesSync())!;
    expect(stats.width, 64);
    expect(stats.validRatio, greaterThan(0.9));
    expect(stats.centerMedianMm, 575, reason: '餐盒格子內的深度');
  });

  test('serial and mock flags are passed to the bridge', () async {
    late List<String> args;
    final cam = RealSenseCameraService(
      const CameraSettings(device: '123456789012', width: 64, height: 48),
      runner: fakeBridge(onRun: (_, a) => args = a),
      bridgePath: bridge,
      mock: true,
      environment: const {},
    );
    await cam.capture(out());
    expect(args, containsAllInOrder(['--serial', '123456789012']));
    expect(args, contains('--mock'));
    expect(cam.description, contains('模擬'));
  });

  test('exit code 2 means no camera attached', () async {
    final cam = service(fakeBridge(exitCode: 2, writeRgb: false));
    await expectLater(
      cam.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_NOT_FOUND'),
      ),
    );
    expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);
  });

  test('exit code 1 (pyrealsense2 missing) is CAMERA_UNAVAILABLE', () async {
    final cam = service(fakeBridge(exitCode: 1, writeRgb: false));
    await expectLater(
      cam.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_UNAVAILABLE'),
      ),
    );
  });

  test('missing bridge script or python is CAMERA_UNAVAILABLE', () async {
    final noScript = service(
      fakeBridge(),
      bridgePath: p.join(tmp.path, 'missing.py'),
    );
    await expectLater(
      noScript.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_UNAVAILABLE'),
      ),
    );
    final noPython = service(
      (exe, args) => throw ProcessException(exe, args, 'not found'),
    );
    await expectLater(
      noPython.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_UNAVAILABLE'),
      ),
    );
  });

  test('timeout kills the capture and reports CAMERA_TIMEOUT', () async {
    final cam = service((_, _) => throw TimeoutException('slow'));
    await expectLater(
      cam.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_TIMEOUT'),
      ),
    );
  });

  test('missing depth output fails and cleans up', () async {
    final cam = service(fakeBridge(writeDepth: false));
    await expectLater(
      cam.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_FAILED'),
      ),
    );
    expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);
  });

  test('depth size differing from meta fails', () async {
    final cam = service(fakeBridge(depthWidth: 32));
    await expectLater(
      cam.capture(out()),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_FAILED'),
      ),
    );
    expect(Directory(p.join(tmp.path, 'out')).listSync(), isEmpty);
  });

  test('probe parses the device description', () async {
    final info = await service(fakeBridge()).probe();
    expect(info.serial, '123456789012');
    expect(info.firmware, '5.16.0.1');
    expect(info.onUsb2, isFalse);
    expect(info.summary, contains('D435f'));

    await expectLater(
      service(fakeBridge(exitCode: 2)).probe(),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_NOT_FOUND'),
      ),
    );
  });

  test('USB 2 link is flagged in the summary', () {
    final info = RealSenseInfo.fromJson({
      'serial': '1',
      'name': 'D435f',
      'usb_type': '2.1',
    });
    expect(info.onUsb2, isTrue);
    expect(info.summary, contains('USB 3'));
  });

  group('CameraSource', () {
    test('legacy values all map to RealSense', () {
      for (final v in [
        'auto',
        'v4l2',
        'nvargus',
        'libcamera',
        'folder',
        'mock',
      ]) {
        expect(CameraSource.parse(v), CameraSource.realsense, reason: v);
      }
      expect(CameraSource.parse('picker'), CameraSource.picker);
      expect(CameraSource.parse(null), CameraSource.platformDefault);
    });

    test('legacy device paths are dropped from the serial field', () {
      for (final v in ['/dev/video0', '0', 'test_images']) {
        final s = CameraSettings.fromJson({'source': 'v4l2', 'device': v});
        expect(s.source, CameraSource.realsense);
        expect(s.device, '', reason: v);
      }
      final kept = CameraSettings.fromJson({
        'source': 'realsense',
        'device': '123456789012',
      });
      expect(kept.device, '123456789012');
    });

    test('create() builds the service for each source', () {
      expect(
        CameraService.create(
          const CameraSettings(source: CameraSource.realsense),
        ),
        isA<RealSenseCameraService>(),
      );
      expect(
        CameraService.create(const CameraSettings(source: CameraSource.picker)),
        isA<ImagePickerCameraService>(),
      );
    });
  });

  test('pngHeader rejects non-PNG data', () {
    expect(pngHeader(img.encodeJpg(MockCameraService.render(8, 8))), isNull);
    expect(pngHeader([1, 2, 3]), isNull);
  });

  group('preview', previewTests);
}

/// 模擬 `realsense_bridge.py --preview` 的子行程:stdin 收 JSON 指令、stdout 送訊息。
class FakePreviewProcess implements Process {
  FakePreviewProcess({
    this.width = 64,
    this.height = 48,
    this.readyExit,
    this.failCapture = false,
    this.writeDepth = true,
  }) {
    stdin = IOSink(_StdinConsumer(_onLine));
    if (readyExit != null) {
      // 啟動就失敗 (例如找不到相機 → 2)
      Future<void>.microtask(() => exit(readyExit!));
    } else {
      send(
        'ready',
        utf8.encode(jsonEncode({'serial': 'ABC', 'name': 'D435f'})),
      );
    }
  }

  final int width;
  final int height;
  final int? readyExit;
  final bool failCapture;
  final bool writeDepth;
  final commands = <Map<String, Object?>>[];
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  /// 不關:quit 指令在 consumer 的 addStream 裡處理,那時 close() 會丟 StateError。
  @override
  // ignore: close_sinks
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 4242;

  void send(String kind, List<int> payload) {
    if (_out.isClosed) return;
    _out.add([...utf8.encode('$kind ${payload.length}\n'), ...payload]);
  }

  void sendFrame() => send('frame', [0xff, 0xd8, 1, 2, 3]);

  void exit(int code) {
    if (_exit.isCompleted) return;
    _out.close();
    _err.close();
    _exit.complete(code);
  }

  void _onLine(String line) {
    final cmd = (jsonDecode(line) as Map).cast<String, Object?>();
    commands.add(cmd);
    switch (cmd['cmd']) {
      case 'quit':
        exit(0);
      case 'capture':
        if (failCapture) {
          send('error', utf8.encode('擷取失敗:test'));
          return;
        }
        File(cmd['rgb'] as String).writeAsBytesSync(
          img.encodeJpg(MockCameraService.render(width, height)),
        );
        if (writeDepth) {
          File(cmd['depth'] as String).writeAsBytesSync(
            img.encodePng(MockCameraService.renderDepth(width, height)),
          );
        }
        File(cmd['meta'] as String).writeAsStringSync(
          jsonEncode({'serial': 'ABC', 'width': width, 'height': height}),
        );
        send('captured', utf8.encode('{"serial": "ABC"}'));
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    exit(-9);
    return true;
  }
}

class _StdinConsumer implements StreamConsumer<List<int>> {
  _StdinConsumer(this.onLine);
  final void Function(String line) onLine;
  final _buf = StringBuffer();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _buf.write(utf8.decode(chunk));
      var text = _buf.toString();
      var nl = text.indexOf('\n');
      while (nl >= 0) {
        final line = text.substring(0, nl).trim();
        text = text.substring(nl + 1);
        if (line.isNotEmpty) onLine(line);
        nl = text.indexOf('\n');
      }
      _buf
        ..clear()
        ..write(text);
    }
  }

  @override
  Future<void> close() async {}
}

void previewTests() {
  late Directory tmp;
  late String bridge;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('spoonfull_rs_preview');
    bridge = p.join(tmp.path, 'realsense_bridge.py');
    File(bridge).writeAsStringSync('# fake');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  RealSenseCameraService camera(
    FakePreviewProcess process, {
    List<String>? args,
  }) => RealSenseCameraService(
    const CameraSettings(width: 64, height: 48),
    starter: (_, a) async {
      args?.addAll(a);
      return process;
    },
    bridgePath: bridge,
    python: 'python3',
    mock: false,
    environment: const {},
  );

  test(
    'preview streams frames and captures through the same process',
    () async {
      final process = FakePreviewProcess();
      final args = <String>[];
      final cam = camera(process, args: args);
      expect(cam.supportsPreview, isTrue);

      final preview = cam.openPreview() as RealSensePreview;
      final frames = <Uint8List>[];
      final sub = preview.frames.listen(frames.add);
      await preview.ready;
      expect(args, containsAllInOrder([bridge, '--preview']));
      expect(args, containsAllInOrder(['--width', '64', '--height', '48']));
      expect(args, containsAllInOrder(['--preview-fps', '--preview-width']));
      expect(preview.info?.serial, 'ABC');
      expect(preview.running, isTrue);

      process.sendFrame();
      process.sendFrame();
      await Future<void>.delayed(Duration.zero);
      expect(frames.length, 2);
      expect(frames.first.sublist(0, 2), [0xff, 0xd8]);

      final raw = (await preview.capture(
        p.join(tmp.path, 'out', 'a.jpg.raw'),
      ))!;
      expect(process.commands.last['cmd'], 'capture');
      expect(raw.imagePath, endsWith('.jpg'));
      expect(File(raw.depthPath!).existsSync(), isTrue);
      expect(File(raw.depthMetaPath!).existsSync(), isTrue);
      // 拍完串流還在,可以再拍
      expect(preview.running, isTrue);
      final again = (await preview.capture(
        p.join(tmp.path, 'out', 'b.jpg.raw'),
      ))!;
      expect(File(again.imagePath).existsSync(), isTrue);

      await preview.close();
      expect(process.commands.last['cmd'], 'quit');
      expect(process.killed, isFalse, reason: '正常 quit 不用 kill');
      expect(preview.running, isFalse);
      await sub.cancel();
    },
  );

  test(
    'no camera: ready fails with CAMERA_NOT_FOUND and frames close',
    () async {
      final preview = camera(FakePreviewProcess(readyExit: 2)).openPreview();
      await expectLater(
        preview.ready,
        throwsA(
          isA<AppException>().having((e) => e.code, 'code', 'CAMERA_NOT_FOUND'),
        ),
      );
      await expectLater(preview.frames.toList(), completion(isEmpty));
      await expectLater(
        preview.capture(p.join(tmp.path, 'c.raw')),
        throwsA(isA<AppException>()),
      );
      await preview.close();
    },
  );

  test('missing bridge fails without starting anything', () async {
    var started = false;
    final cam = RealSenseCameraService(
      const CameraSettings(),
      starter: (_, _) async {
        started = true;
        return FakePreviewProcess();
      },
      bridgePath: p.join(tmp.path, 'missing.py'),
      environment: const {},
    );
    final preview = cam.openPreview();
    await expectLater(
      preview.ready,
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_UNAVAILABLE'),
      ),
    );
    expect(started, isFalse);
    await preview.close();
  });

  test('bridge error reply fails the capture but keeps the stream', () async {
    final process = FakePreviewProcess(failCapture: true);
    final preview = camera(process).openPreview();
    await preview.ready;
    final out = p.join(tmp.path, 'out', 'e.jpg.raw');
    await expectLater(
      preview.capture(out),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_FAILED'),
      ),
    );
    expect((preview as RealSensePreview).running, isTrue);
    expect(File(p.setExtension(out, '.jpg')).existsSync(), isFalse);
    await preview.close();
  });

  test('bad depth output is rejected and files are removed', () async {
    final process = FakePreviewProcess(writeDepth: false);
    final preview = camera(process).openPreview();
    await preview.ready;
    final out = p.join(tmp.path, 'out', 'd.jpg.raw');
    await expectLater(
      preview.capture(out),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_FAILED'),
      ),
    );
    expect(File(p.setExtension(out, '.jpg')).existsSync(), isFalse);
    await preview.close();
  });

  test('process dying mid-stream fails a pending capture', () async {
    final process = FakePreviewProcess();
    final preview = camera(process).openPreview();
    await preview.ready;
    // 這次 capture 送出後子行程直接掛掉 (相機被拔)
    process.exit(3);
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      preview.capture(p.join(tmp.path, 'out', 'x.jpg.raw')),
      throwsA(
        isA<AppException>().having((e) => e.code, 'code', 'CAMERA_FAILED'),
      ),
    );
    await expectLater(preview.frames.toList(), completion(isEmpty));
    await preview.close();
  });

  test('close before the process started kills it when it appears', () async {
    final process = FakePreviewProcess();
    final starter = Completer<Process>();
    final cam = RealSenseCameraService(
      const CameraSettings(),
      starter: (_, _) => starter.future,
      bridgePath: bridge,
      environment: const {},
    );
    final preview = cam.openPreview();
    final closing = preview.close();
    starter.complete(process);
    await closing;
    await Future<void>.delayed(Duration.zero);
    expect(process.killed, isTrue);
  });
}
