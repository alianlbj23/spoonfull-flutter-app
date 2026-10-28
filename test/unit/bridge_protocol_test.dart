import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spoonfull_flutter_app/services/hardware/bridge_protocol.dart';

void main() {
  List<BridgeMessage> parse(Iterable<List<int>> chunks) {
    final out = <BridgeMessage>[];
    final parser = BridgeMessageParser(out.add);
    for (final c in chunks) {
      parser.add(c);
    }
    return out;
  }

  List<int> msg(String kind, List<int> payload) => [
    ...utf8.encode('$kind ${payload.length}\n'),
    ...payload,
  ];

  test('splits messages that arrive in one chunk', () {
    final frame = List<int>.generate(300, (i) => i & 0xff);
    final got = parse([
      [...msg('ready', utf8.encode('{"a":1}')), ...msg('frame', frame)],
    ]);
    expect(got.map((m) => m.kind), ['ready', 'frame']);
    expect(utf8.decode(got[0].payload), '{"a":1}');
    expect(got[1].payload, frame);
  });

  test('reassembles a message split across chunks, header included', () {
    final frame = List<int>.generate(1000, (i) => (i * 7) & 0xff);
    final bytes = [
      ...msg('frame', frame),
      ...msg('captured', [1, 2, 3]),
    ];
    // 一次 1 byte、一次 17 bytes 兩種切法都要得到同樣的結果
    for (final size in [1, 17, 999]) {
      final chunks = <List<int>>[];
      for (var i = 0; i < bytes.length; i += size) {
        chunks.add(bytes.sublist(i, (i + size).clamp(0, bytes.length)));
      }
      final got = parse(chunks);
      expect(got.map((m) => m.kind), ['frame', 'captured'], reason: '$size');
      expect(got[0].payload, frame);
      expect(got[1].payload, [1, 2, 3]);
    }
  });

  test('empty payload and payload containing newlines are fine', () {
    final got = parse([msg('error', []), msg('error', utf8.encode('a\nb\n'))]);
    expect(got.length, 2);
    expect(got[0].payload, isEmpty);
    expect(utf8.decode(got[1].payload), 'a\nb\n');
  });

  test('bad header throws', () {
    expect(
      () => parse([utf8.encode('garbage\n')]),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parse([utf8.encode('frame abc\n')]),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parse([List.filled(200, 0x41)]),
      throwsA(isA<FormatException>()),
      reason: '沒有換行的垃圾不能無限累積',
    );
  });
}
