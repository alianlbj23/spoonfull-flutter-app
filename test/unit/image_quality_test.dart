import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:spoonfull_flutter_app/config/app_constants.dart';
import 'package:spoonfull_flutter_app/core/utils/image_quality_analyzer.dart';
import 'package:spoonfull_flutter_app/data/models/image_quality.dart';
import 'package:spoonfull_flutter_app/services/hardware/camera_service.dart';
import 'package:spoonfull_flutter_app/services/hardware/image_pipeline.dart';

img.Image _tray({int seed = 42}) =>
    MockCameraService.render(640, 480, seed: seed);

img.Image _emptyScale({int seed = 7}) =>
    MockCameraService.render(640, 480, withTray: false, seed: seed);

img.Image _flat(int r, int g, int b) {
  final image = img.Image(width: 640, height: 480);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  img.noise(image, 6, random: math.Random(1));
  return image;
}

ImageQualityReport _analyze(img.Image image, {img.Image? reference}) =>
    ImageQualityAnalyzer.analyze(
      GrayImage.from(image),
      reference: reference == null ? null : GrayImage.from(reference),
    );

void main() {
  group('ImageQualityAnalyzer', () {
    test('well-lit sharp tray passes', () {
      final q = _analyze(_tray());
      expect(q.issues, isEmpty, reason: '$q');
      expect(q.trayScoreMethod, 'edges');
      expect(q.blurScore, greaterThan(AppConstants.qualityBlurVarianceMin));
    });

    test('dark image flags tooDark only', () {
      final q = _analyze(_flat(18, 18, 20));
      expect(q.issues, [QualityIssue.tooDark], reason: '$q');
      expect(q.meanLuma, lessThan(AppConstants.qualityDarkMeanLuma));
    });

    test('over-exposed image flags tooBright only', () {
      final q = _analyze(_flat(250, 250, 248));
      expect(q.issues, [QualityIssue.tooBright], reason: '$q');
    });

    test('blurred tray flags blurry (not trayMissing)', () {
      final blurred = img.gaussianBlur(_tray(), radius: 14);
      final q = _analyze(blurred);
      expect(q.issues, [QualityIssue.blurry], reason: '$q');
      expect(q.blurScore, lessThan(AppConstants.qualityBlurVarianceMin));
      // 邊緣被糊掉,但餐盒的對比仍在
      expect(q.roiContrast, greaterThan(AppConstants.qualityTrayContrastMin));
    });

    test('empty scale (no reference) flags trayMissing only', () {
      final q = _analyze(_emptyScale());
      expect(q.issues, [QualityIssue.trayMissing], reason: '$q');
      expect(q.trayScore, lessThan(AppConstants.qualityTrayEdgeDensityMin));
      expect(q.roiContrast, lessThan(AppConstants.qualityTrayContrastMin));
    });

    test('noisy empty scale is still trayMissing', () {
      final noisy = _emptyScale(seed: 3);
      img.noise(noisy, 12, random: math.Random(9));
      final q = _analyze(noisy);
      expect(q.issues, [QualityIssue.trayMissing], reason: '$q');
    });

    test('reference comparison: tray present vs absent', () {
      final reference = _emptyScale(seed: 1);
      final withTray = _analyze(_tray(), reference: reference);
      expect(withTray.trayScoreMethod, 'reference');
      expect(withTray.issues, isEmpty, reason: '$withTray');

      final empty = _analyze(_emptyScale(seed: 2), reference: reference);
      expect(empty.issues, [QualityIssue.trayMissing], reason: '$empty');
    });

    test('report round-trips through JSON', () {
      final q = _analyze(_emptyScale());
      final back = ImageQualityReport.fromJson(q.toJson());
      expect(back.issues, q.issues);
      expect(back.trayScoreMethod, q.trayScoreMethod);
      expect(back.meanLuma, closeTo(q.meanLuma, 0.01));
    });

    test('degenerate image does not crash', () {
      final q = ImageQualityAnalyzer.analyze(
        GrayImage(1, 1, Uint8List.fromList([0])),
      );
      expect(q.issues, isNotEmpty);
    });
  });

  group('ImagePipeline.processBytes', () {
    test('resizes long side to 1280, encodes JPEG, keeps aspect ratio', () {
      final big = MockCameraService.render(1920, 1080);
      final out = ImagePipeline.processBytes(img.encodePng(big));
      expect(out.width, AppConstants.uploadMaxLongSide);
      expect(out.height, 720);
      expect(out.jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      expect(out.quality.passed, isTrue, reason: '${out.quality}');
      final decoded = img.decodeJpg(out.jpeg)!;
      expect(decoded.width, 1280);
    });

    test('does not upscale small images', () {
      final small = MockCameraService.render(640, 480);
      final out = ImagePipeline.processBytes(img.encodeJpg(small));
      expect(out.width, 640);
      expect(out.height, 480);
    });

    test('portrait image honours EXIF orientation and long side', () {
      final portrait = MockCameraService.render(1080, 1920);
      final out = ImagePipeline.processBytes(img.encodeJpg(portrait));
      expect(out.width, 720);
      expect(out.height, 1280);
    });

    test('rejects undecodable bytes', () {
      expect(
        () => ImagePipeline.processBytes(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(anything),
      );
    });
  });
}
