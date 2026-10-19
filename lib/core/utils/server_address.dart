import 'dart:io';

/// 把設定畫面輸入的伺服器位址轉成 BASE_URL。
///
/// 可輸入完整網址 (`https://foodintakesystem.com`、`http://192.168.1.10:8000`)
/// 或只輸入主機名稱 / IP:
/// - 沒寫協定時,院內區網位址 (私有 IP、localhost、`.local`、沒有點的主機名稱)
///   預設 `http`,其他 (公開網域) 預設 `https`。
/// - 埠可省略,依協定預設 443 / 80;網址裡寫了埠就以網址為準,否則用 [port] 欄位。
/// - 公開網域不接受 `http://` (資料與 token 會明文經過網際網路)。
class ServerAddress {
  const ServerAddress._(this.uri, this.error);

  /// 解析後的 BASE_URL (路徑結尾一定有 `/`);格式錯誤時為 null。
  final Uri? uri;

  /// 給使用者看的錯誤 (中文);沒有錯誤時為 null。
  final String? error;

  bool get isValid => uri != null && error == null;
  String? get baseUrl => uri?.toString();
  bool get isSecure => uri?.scheme == 'https';

  static final _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://');

  /// [allowInsecurePublic] 為 true 時不擋公開網域的 http (只用在已存的舊設定,
  /// 讓升級前就能用的機台繼續運作)。
  static ServerAddress resolve(
    String input, {
    String port = '',
    bool allowInsecurePublic = false,
  }) {
    final raw = input.trim();
    if (raw.isEmpty) return const ServerAddress._(null, '請輸入伺服器位址');
    final m = _scheme.firstMatch(raw);
    final explicitScheme = m?.group(1)?.toLowerCase();
    if (explicitScheme != null &&
        explicitScheme != 'http' &&
        explicitScheme != 'https') {
      return const ServerAddress._(null, '只支援 http:// 或 https:// 開頭的網址');
    }
    final parsed = Uri.tryParse(explicitScheme == null ? 'http://$raw' : raw);
    if (parsed == null || parsed.host.isEmpty) {
      return const ServerAddress._(null, '伺服器位址格式錯誤');
    }
    final private = isPrivateHost(parsed.host);
    final scheme = explicitScheme ?? (private ? 'http' : 'https');

    int? explicitPort;
    if (parsed.hasPort) {
      explicitPort = parsed.port;
    } else if (port.trim().isNotEmpty) {
      explicitPort = int.tryParse(port.trim());
      if (explicitPort == null || explicitPort <= 0 || explicitPort > 65535) {
        return const ServerAddress._(null, '埠需為 1 – 65535 的數字');
      }
    }
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    final uri = Uri(
      scheme: scheme,
      host: parsed.host,
      port: explicitPort,
      path: path,
    );
    if (scheme == 'http' && !private && !allowInsecurePublic) {
      return ServerAddress._(uri, '公開網址必須使用 https://,http:// 只能用於院內區網位址');
    }
    return ServerAddress._(uri, null);
  }

  /// 院內區網 / 本機位址:私有 IPv4 (10/8、172.16/12、192.168/16)、
  /// Tailscale / CGNAT 的 100.64/10 (RFC 6598,不會在公網路由)、loopback、
  /// link-local、IPv6 ULA / link-local、localhost、mDNS 的 `.local`,
  /// 以及沒有點的單段主機名稱 (只可能在區網 DNS 裡)。
  static bool isPrivateHost(String host) {
    var h = host.toLowerCase().trim();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.isEmpty) return false;
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) {
      return true;
    }
    final ip = InternetAddress.tryParse(h);
    if (ip == null) return !h.contains('.');
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127); // Tailscale / CGNAT
    }
    return (b[0] & 0xfe) == 0xfc; // fc00::/7
  }
}
