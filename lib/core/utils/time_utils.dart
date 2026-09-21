/// 規格中所有時間戳記皆為 unix timestamp (秒)。
int nowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

DateTime fromUnix(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

int toUnix(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

int? asInt(Object? value) => switch (value) {
  int v => v,
  num v => v.toInt(),
  String v => int.tryParse(v),
  _ => null,
};

double? asDouble(Object? value) => switch (value) {
  num v => v.toDouble(),
  String v => double.tryParse(v),
  _ => null,
};

String? asString(Object? value) => value?.toString();
