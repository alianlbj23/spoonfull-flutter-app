import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:spoonfull_flutter_app/core/errors/app_exception.dart';
import 'package:spoonfull_flutter_app/data/models/hardware_config.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('spoonfull_folder'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('cycles through images in name order and copies them', () async {
    for (final name in ['b.jpg', 'a.png', 'notes.txt']) {
      final image = MockCameraService.render(64, 48, seed: name.length);
      File(p.join(tmp.path, name)).writeAsBytesSync(
        name.endsWith('.png') ? img.encodePng(image) : img.encodeJpg(image),
      );
    }
    final camera = FolderCameraService(tmp.path);
    expect(camera.listImages().map((f) => p.basename(f.path)), ['a.png', 'b.jpg']);

    final out = p.join(tmp.path, 'out', 'x');
    expect(await camera.capture('$out.raw'), endsWith('.png'));
    expect(await camera.capture('$out.raw'), endsWith('.jpg'));
    expect(await camera.capture('$out.raw'), endsWith('.png'), reason: '循環');
  });

  test('empty folder raises a local validation error', () async {
    final camera = FolderCameraService(tmp.path);
    expect(
      () => camera.capture(p.join(tmp.path, 'x.raw')),
      throwsA(isA<AppException>().having((e) => e.code, 'code', 'CAMERA_UNAVAILABLE')),
    );
  });

  test('device path left at /dev/video0 falls back to test_images', () {
    final camera = CameraService.create(
      const CameraSettings(source: CameraSource.folder),
    );
    expect(camera, isA<FolderCameraService>());
    expect(
      (camera as FolderCameraService).directory.path,
      FolderCameraService.defaultFolder,
    );
  });
}
