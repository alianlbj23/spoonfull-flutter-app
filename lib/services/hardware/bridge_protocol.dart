import 'dart:typed_data';

/// `realsense_bridge.py --preview` 從 stdout 送來的一則訊息。
///
/// [kind] 為 `ready` / `frame` / `captured` / `error`;[payload] 依種類是
/// JSON、JPEG 或 UTF-8 文字 (格式見 deploy/realsense_bridge.py 開頭)。
class BridgeMessage {
  const BridgeMessage(this.kind, this.payload);

  final String kind;
  final Uint8List payload;
}

/// 把 stdout 的位元組流切成 [BridgeMessage]:每則是一行「`<kind> <bytes>\n`」
/// 接著 bytes 個 byte 的內容。訊息可以跨 chunk,chunk 也可以含好幾則。
/// 標頭不合格式時丟 [FormatException] (之後的資料就不可信了)。
class BridgeMessageParser {
  BridgeMessageParser(this.onMessage);

  final void Function(BridgeMessage message) onMessage;

  /// 標頭最長的合理長度 (kind 幾個字 + 空白 + 位元數)。
  static const _maxHeader = 64;

  Uint8List _buf = Uint8List(0);
  int _start = 0;
  int _end = 0;

  String? _kind;
  int _need = 0;

  int get _available => _end - _start;

  void add(List<int> chunk) {
    _append(chunk);
    while (true) {
      if (_kind == null) {
        if (!_parseHeader()) return;
      }
      if (_available < _need) return;
      final payload = Uint8List.sublistView(_buf, _start, _start + _need);
      _start += _need;
      final kind = _kind!;
      _kind = null;
      _need = 0;
      onMessage(BridgeMessage(kind, Uint8List.fromList(payload)));
    }
  }

  bool _parseHeader() {
    final limit = _start + _available;
    for (var i = _start; i < limit; i++) {
      if (_buf[i] != 0x0a) {
        if (i - _start > _maxHeader) {
          throw FormatException('bridge header too long');
        }
        continue;
      }
      final line = String.fromCharCodes(_buf, _start, i).trim();
      final sp = line.indexOf(' ');
      final size = sp < 0 ? null : int.tryParse(line.substring(sp + 1));
      if (sp <= 0 || size == null || size < 0) {
        throw FormatException('bad bridge header: "$line"');
      }
      _kind = line.substring(0, sp);
      _need = size;
      _start = i + 1;
      return true;
    }
    if (_available > _maxHeader) {
      throw FormatException('bridge header too long');
    }
    return false;
  }

  void _append(List<int> chunk) {
    if (_start > 0 && _start >= (_buf.length >> 1)) {
      _buf.setRange(0, _available, _buf, _start);
      _end -= _start;
      _start = 0;
    }
    if (_end + chunk.length > _buf.length) {
      final grown = Uint8List((_end + chunk.length) * 2);
      grown.setRange(0, _end, _buf);
      _buf = grown;
    }
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }
}
