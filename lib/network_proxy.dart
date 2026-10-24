import 'dart:io';
import 'l10n/l10n.dart';

/// Where Lumtub sends its network traffic: yt-dlp, libmpv's video streams
/// and the app's own requests all go the same way.
enum ProxyMode {
  /// The proxy set in Windows (as Clash, v2rayN and similar tools set it),
  /// or none when Windows has none.
  system('跟随系统（推荐）'),
  off('不使用代理'),
  custom('手动填写');

  const ProxyMode(this._label);
  final String _label;
  String get label => tr(_label);
}

/// A proxy address as `http://host:port` or `socks5://[user:pass@]host:port`,
/// or null for a direct connection. yt-dlp takes either kind itself; libmpv
/// and dart:io only speak HTTP proxies, so a SOCKS one reaches them through
/// the local `SocksBridge`.
class NetworkProxy {
  const NetworkProxy(this.url);
  final String? url;

  static const direct = NetworkProxy(null);

  bool get isHttp => url != null && url!.startsWith('http://');
  bool get isSocks => url != null && !isHttp;

  /// [url] without the password, for logs.
  String? get redacted => url?.replaceFirst(RegExp(r'//[^@/]*@'), '//');

  /// yt-dlp's `--proxy` value for [mode]: an empty string forces a direct
  /// connection, null leaves yt-dlp to find the Windows proxy itself.
  String? ytDlpValue(ProxyMode mode) => mode == ProxyMode.off ? '' : url;

  /// `host:port` for dart:io's `PROXY` rule.
  String? get hostPort {
    final uri = url == null ? null : Uri.tryParse(url!);
    return uri == null || uri.host.isEmpty || !uri.hasPort ? null : '${uri.host}:${uri.port}';
  }

  /// Normalises what a person typed, such as `127.0.0.1:7890` or
  /// `socks5://127.0.0.1:7891`, or returns null when it is not an address.
  static String? normalize(String text) {
    var value = text.trim();
    if (value.isEmpty) return null;
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || !uri.hasPort || uri.port <= 0) return null;
    if (!{'http', 'socks5', 'socks5h', 'socks4', 'socks4a'}.contains(uri.scheme)) return null;
    final login = uri.scheme.startsWith('socks') && uri.userInfo.isNotEmpty ? '${uri.userInfo}@' : '';
    return '${uri.scheme}://$login${uri.host.contains(':') ? '[${uri.host}]' : uri.host}:${uri.port}';
  }

  /// The proxy in Windows' `ProxyServer` value: either one address for
  /// every protocol or `http=…;https=…;socks=…`.
  static String? parseWindows(String server) {
    final parts = server.split(';').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    if (!parts.any((p) => p.contains('='))) return normalize(parts.first);
    final byScheme = {
      for (final part in parts)
        if (part.contains('=')) part.substring(0, part.indexOf('=')).toLowerCase(): part.substring(part.indexOf('=') + 1),
    };
    final http = byScheme['https'] ?? byScheme['http'];
    if (http != null) return normalize(http.contains('://') ? http : 'http://$http');
    final socks = byScheme['socks'];
    return socks == null ? null : normalize(socks.contains('://') ? socks : 'socks5://$socks');
  }

  /// The Windows proxy, read from the registry as the browsers read it.
  static Future<NetworkProxy> windows() async {
    if (!Platform.isWindows) return direct;
    try {
      const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enabled = await Process.run('reg', ['query', key, '/v', 'ProxyEnable']).timeout(const Duration(seconds: 5));
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b').hasMatch(enabled.stdout.toString())) return direct;
      final server = await Process.run('reg', ['query', key, '/v', 'ProxyServer']).timeout(const Duration(seconds: 5));
      final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)').firstMatch(server.stdout.toString());
      return NetworkProxy(match == null ? null : parseWindows(match.group(1)!.trim()));
    } catch (_) {
      return direct;
    }
  }

  static Future<NetworkProxy> resolve(ProxyMode mode, String address) async => switch (mode) {
        ProxyMode.system => await windows(),
        ProxyMode.off => direct,
        ProxyMode.custom => NetworkProxy(normalize(address)),
      };
}

/// The overrides main installs; the controller updates their route.
final appHttpOverrides = ProxyHttpOverrides();

/// Sends every dart:io connection the app makes (thumbnails, feeds, posts,
/// updates) through [endpoint], an HTTP proxy that is either the user's own
/// or the local `SocksBridge`. Without one the connection is direct, and the
/// proxy environment variables are read only when [useEnvironment] is set.
class ProxyHttpOverrides extends HttpOverrides {
  /// `host:port` of the HTTP proxy, or null for direct.
  String? endpoint;
  bool useEnvironment = false;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = route;
    return client;
  }

  /// dart:io's proxy rule for [uri]; [environment] is for tests.
  String route(Uri uri, {Map<String, String>? environment}) {
    // This PC and devices on the home network (DLNA, Chromecast) are never
    // behind the proxy.
    if (isLocalHost(uri.host)) return 'DIRECT';
    if (endpoint != null) return 'PROXY $endpoint';
    return useEnvironment ? HttpClient.findProxyFromEnvironment(uri, environment: environment) : 'DIRECT';
  }
}

/// Whether [host] is this PC or an address on the local network: loopback,
/// private (10/8, 172.16/12, 192.168/16, fc00::/7), link-local or `.local`.
bool isLocalHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.local')) return true;
  final ip = InternetAddress.tryParse(h.startsWith('[') ? h.substring(1, h.length - 1) : h);
  if (ip == null) return false;
  if (ip.isLoopback || ip.isLinkLocal) return true;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xfe) == 0xfc;
}
