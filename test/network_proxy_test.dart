import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/network_proxy.dart';
import 'package:lumtub/player_option_applicator.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/stream_resolver.dart';

void main() {
  test('reads the Windows proxy as proxy tools write it', () {
    expect(NetworkProxy.parseWindows('127.0.0.1:7890'), 'http://127.0.0.1:7890');
    expect(NetworkProxy.parseWindows('http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891'), 'http://127.0.0.1:7890');
    expect(NetworkProxy.parseWindows('socks=127.0.0.1:7891'), 'socks5://127.0.0.1:7891');
    expect(NetworkProxy.parseWindows(''), isNull);
  });

  test('accepts typed addresses and rejects others', () {
    expect(NetworkProxy.normalize(' 127.0.0.1:7890 '), 'http://127.0.0.1:7890');
    expect(NetworkProxy.normalize('socks5://localhost:1080'), 'socks5://localhost:1080');
    expect(NetworkProxy.normalize('127.0.0.1'), isNull);
    expect(NetworkProxy.normalize('ftp://a:21'), isNull);
    expect(const NetworkProxy('http://127.0.0.1:7890').hostPort, '127.0.0.1:7890');
    expect(const NetworkProxy('socks5://127.0.0.1:7891').isHttp, isFalse);
  });

  test('tells yt-dlp to connect directly only when the proxy is off', () {
    expect(NetworkProxy.direct.ytDlpValue(ProxyMode.off), '');
    expect(NetworkProxy.direct.ytDlpValue(ProxyMode.system), isNull);
    expect(const NetworkProxy('http://h:1').ytDlpValue(ProxyMode.custom), 'http://h:1');
    final resolver = StreamResolver('yt-dlp', proxy: () => 'socks5://h:2', infoDirectory: Directory('x'));
    expect(resolver.arguments('dQw4w9WgXcQ', 'ytdl'), containsAllInOrder(['--proxy', 'socks5://h:2']));
    expect(PlayerOptionApplicator.ytdlRawOptions(const PlayerSettings(), proxy: 'http://h:1'), 'proxy=http://h:1');
  });

  test('the proxy setting is saved and moves old buffer defaults', () {
    final saved = PlayerSettings.fromJson(const PlayerSettings(proxyMode: ProxyMode.custom, proxyAddress: 'http://127.0.0.1:7890').toJson());
    expect(saved.proxyMode, ProxyMode.custom);
    expect(saved.proxyAddress, 'http://127.0.0.1:7890');
    expect(PlayerSettings.fromJson({}).proxyMode, ProxyMode.system);
    final old = PlayerSettings.fromJson({'cacheSeconds': 30, 'cacheMemoryMb': 64});
    expect((old.cacheSeconds, old.cacheMemoryMb), (60, 150));
    final chosen = PlayerSettings.fromJson({'cacheSeconds': 30, 'cacheMemoryMb': 64, 'bufferDefaults': 2});
    expect((chosen.cacheSeconds, chosen.cacheMemoryMb), (30, 64));
  });
}
