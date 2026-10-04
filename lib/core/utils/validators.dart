import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../config/app_constants.dart';
import '../../data/models/bed_data.dart';
import '../../data/models/meal_data.dart';
import '../errors/app_exception.dart';

/// 輸入驗證 (規格 8.4)。
class Validators {
  Validators._();

  static AppException _invalid(String message, [String? code]) =>
      AppException(AppErrorType.localValidation, message, code: code);

  static void pairingCode(String code) {
    final re = RegExp('^\\d{${AppConstants.pairingCodeLength}}\$');
    if (!re.hasMatch(code)) {
      throw _invalid(
        '配對碼需為 ${AppConstants.pairingCodeLength} 位數字',
        'INVALID_PAIRING_CODE',
      );
    }
  }

  /// bed_id 非空、存在於目前病房的床位清單;patient_id 與床位一致。
  static void bedAndPatient({
    required BedData bed,
    required List<BedData> roomBeds,
  }) {
    if (bed.bedId.isEmpty) throw _invalid('床位ID無效', 'INVALID_BED_ID');
    if (!roomBeds.any((b) => b.bedId == bed.bedId)) {
      throw _invalid('床位不在此病房中', 'INVALID_BED_ID');
    }
    final current = roomBeds.firstWhere((b) => b.bedId == bed.bedId);
    if (!bed.hasPatient || current.patientId != bed.patientId) {
      throw _invalid('病患ID與床位不一致', 'INVALID_PATIENT_ID');
    }
  }

  static void meal(String mealId, List<MealData> meals) {
    if (mealId.isEmpty || !meals.any((m) => m.mealId == mealId)) {
      throw _invalid('請選擇有效的膳食');
    }
  }

  /// 整盤重量:可省略;有值時必須是 0 ~ 20 kg 的有限數。
  static void weight(double? grams) {
    if (grams == null) return;
    if (!grams.isFinite || grams < 0 || grams > 20000) {
      throw _invalid('重量 ${grams.toStringAsFixed(0)} g 不合理,請重新秤重', 'INVALID_WEIGHT');
    }
  }

  /// 依檔頭判斷 MIME,只允許 JPEG / PNG。
  static String? detectMime(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    return null;
  }

  /// 驗證格式 (JPG/PNG)、大小 (<5MB)、尺寸 (480x320 ~ 4000x3000)。
  static Future<String> image(String path) async {
    final file = File(path);
    if (!await file.exists()) throw _invalid('找不到照片檔案');
    final length = await file.length();
    if (length > AppConstants.maxImageBytes) {
      throw _invalid('圖片超過 5MB 限制,請重新拍攝', 'IMAGE_TOO_LARGE');
    }
    final bytes = await file.readAsBytes();
    final mime = detectMime(bytes);
    if (mime == null) {
      throw _invalid('僅支援 JPG / PNG 圖片', 'INVALID_IMAGE_FORMAT');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    descriptor.dispose();
    buffer.dispose();
    dimensions(w, h);
    return mime;
  }

  static void dimensions(int width, int height) {
    final long = math.max(width, height);
    final short = math.min(width, height);
    if (long < AppConstants.minImageLongSide ||
        short < AppConstants.minImageShortSide ||
        long > AppConstants.maxImageLongSide ||
        short > AppConstants.maxImageShortSide) {
      throw _invalid(
        '圖片尺寸 ${width}x$height 不在允許範圍 (480x320 ~ 4000x3000)',
        'INVALID_IMAGE_FORMAT',
      );
    }
  }
}
