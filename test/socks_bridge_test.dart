import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/network_proxy.dart';
import 'package:lumtub/socks_bridge.dart';

/// A SOCKS5 server on loopback that sends every request to [target] and
/// records what was asked for.
class FakeSocks {
  FakeSocks(this.server, this.target);
  final ServerSocket server;
  final int target;
  String? user;
  String? pass;
  int replyCode = 0;
  final asked = <String>[];

  static Future<FakeSocks> start(int target, {String? user, String? pass, int replyCode = 0}) async {
    final fake = FakeSocks(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), target)
      ..user = user
      ..pass = pass
      ..replyCode = replyCode;
    fake.server.listen(fake._serve);
    return fake;
  }

  void _serve(Socket client) {
    final buffer = <int>[];
    Socket? upstream;
    var step = 0;
    client.listen((data) {
      if (upstream != null) return upstream!.add(data);
      buffer.addAll(data);
      if (step == 0 && buffer.length >= 2 && buffer.length >= 2 + buffer[1]) {
        final methods = buffer.sublist(2, 2 + buffer[1]);
        buffer.removeRange(0, 2 + buffer[1]);
        step = user == null ? 2 : 1;
        client.add([5, user == null ? 0 : (methods.contains(2) ? 2 : 255)]);
      }
      if (step == 1 && buffer.length >= 2 && buffer.length >= 3 + buffer[1] + buffer[2 + buffer[1]]) {
        final ulen = buffer[1];
        final u = utf8.decode(buffer.sublist(2, 2 + ulen));
        final p = utf8.decode(buffer.sublist(3 + ulen, 3 + ulen + buffer[2 + ulen]));
        buffer.clear();
        step = u == user && p == pass ? 2 : 3;
        client.add([1, step == 2 ? 0 : 1]);
        if (step == 3) client.close();
      }
      if (step == 2 && buffer.length >= 7) {
        final atyp = buffer[3];
        final addrLength = atyp == 1 ? 4 : atyp == 4 ? 16 : buffer[4] + 1;
        if (buffer.length < 4 + addrLength + 2) return;
        final address = atyp == 3 ? utf8.decode(buffer.sublist(5, 4 + addrLength)) : buffer.sublist(4, 4 + addrLength).join('.');
        asked.add('$atyp:$address');
        step = 4;
        if (replyCode != 0) {
          client.add([5, replyCode, 0, 1, 0, 0, 0, 0, 0, 0]);
          client.close();
          return;
        }
        Socket.connect('127.0.0.1', target).then((socket) {
          upstream = socket;
          socket.listen(client.add, onDone: client.close);
          client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        });
      }
    }, onError: (_) {}, onDone: () => upstream?.close());
  }

  Future<void> close() => server.close();
}

/// An HTTP server standing for "the internet"; counts the requests it gets.
Future<(HttpServer, List<String>)> startTarget() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <String>[];
  server.listen((request) {
    seen.add(request.uri.toString());
    request.response.write('hello');
    request.response.close();
  });
  return (server, seen);
}

/// Sends [request] to the bridge and returns everything it answers.
Future<String> ask(SocksBridge bridge, String request, {String? thenSend}) async {
  final socket = await Socket.connect('127.0.0.1', bridge.port);
  final answer = StringBuffer();
  final done = Completer<void>();
  socket.listen((data) => answer.write(latin1.decode(data)), onDone: done.complete, onError: (_) => done.complete());
  socket.write(request);
  if (thenSend != null) {
    await Future.delayed(const Duration(milliseconds: 200));
    socket.write(thenSend);
  }
  await done.future.timeout(const Duration(seconds: 10));
  socket.destroy();
  return answer.toString();
}

void main() {
  const get = 'GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n';

  test('CONNECT tunnels through SOCKS5, sending the name for socks5h', () async {
    final (target, seen) = await startTarget();
    final socks = await FakeSocks.start(target.port);
    final bridge = await SocksBridge.start('socks5h://127.0.0.1:${socks.server.port}');
    final answer = await ask(bridge, 'CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n', thenSend: get);
    expect(answer, startsWith('HTTP/1.1 200'));
    expect(answer, contains('hello'));
    expect(socks.asked, ['3:example.test']);
    expect(seen, ['/']);
    await bridge.close();
    await socks.close();
    await target.close(force: true);
  });

  test('socks5 resolves names itself and sends the address', () async {
    final (target, _) = await startTarget();
    final socks = await FakeSocks.start(target.port);
    final bridge = await SocksBridge.start('socks5://127.0.0.1:${socks.server.port}');
    final answer = await ask(bridge, 'CONNECT 127.0.0.1:80 HTTP/1.1\r\n\r\n', thenSend: get);
    expect(answer, startsWith('HTTP/1.1 200'));
    expect(socks.asked, ['1:127.0.0.1']);
    await bridge.close();
    await socks.close();
    await target.close(force: true);
  });

  test('a plain HTTP request is forwarded as an origin-form request', () async {
    final (target, seen) = await startTarget();
    final socks = await FakeSocks.start(target.port);
    final bridge = await SocksBridge.start('socks5h://127.0.0.1:${socks.server.port}');
    final client = HttpClient()..findProxy = (_) => 'PROXY ${bridge.hostPort}';
    final response = await client.getUrl(Uri.parse('http://example.test:8080/a/b?q=1')).then((r) => r.close());
    expect(await response.transform(utf8.decoder).join(), 'hello');
    expect(seen, ['/a/b?q=1']);
    expect(socks.asked, ['3:example.test']);
    client.close(force: true);
    await bridge.close();
    await socks.close();
    await target.close(force: true);
  });

  test('username and password go to the SOCKS server, and a wrong one fails', () async {
    final (target, seen) = await startTarget();
    final socks = await FakeSocks.start(target.port, user: 'me', pass: 'p@ss');
    final good = await SocksBridge.start('socks5h://me:p%40ss@127.0.0.1:${socks.server.port}');
    expect(await ask(good, 'CONNECT a.test:80 HTTP/1.1\r\n\r\n', thenSend: get), contains('hello'));
    final bad = await SocksBridge.start('socks5h://me:nope@127.0.0.1:${socks.server.port}');
    expect(await ask(bad, 'CONNECT a.test:80 HTTP/1.1\r\n\r\n'), startsWith('HTTP/1.1 502'));
    final anonymous = await SocksBridge.start('socks5h://127.0.0.1:${socks.server.port}');
    expect(await ask(anonymous, 'CONNECT a.test:80 HTTP/1.1\r\n\r\n'), startsWith('HTTP/1.1 502'));
    expect(seen, ['/']);
    for (final bridge in [good, bad, anonymous]) {
      await bridge.close();
    }
    await socks.close();
    await target.close(force: true);
  });

  test('when the SOCKS proxy refuses or is down the request fails and never goes direct', () async {
    final (target, seen) = await startTarget();
    final connect = 'CONNECT 127.0.0.1:${target.port} HTTP/1.1\r\n\r\n';
    final refusing = await FakeSocks.start(target.port, replyCode: 5);
    var bridge = await SocksBridge.start('socks5://127.0.0.1:${refusing.server.port}');
    expect(await ask(bridge, connect), startsWith('HTTP/1.1 502'));
    await bridge.close();
    await refusing.close();
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();
    bridge = await SocksBridge.start('socks5://127.0.0.1:$deadPort');
    expect(await ask(bridge, connect), startsWith('HTTP/1.1 502'));
    expect(await ask(bridge, 'GET http://127.0.0.1:${target.port}/ HTTP/1.1\r\n\r\n'), startsWith('HTTP/1.1 502'));
    expect(await ask(bridge, 'nonsense\r\n\r\n'), startsWith('HTTP/1.1 400'));
    expect(seen, isEmpty);
    await bridge.close();
    await target.close(force: true);
  });

  test('the bridge listens on loopback only and stops on close', () async {
    final bridge = await SocksBridge.start('socks5://127.0.0.1:1');
    expect(bridge.hostPort, startsWith('127.0.0.1:'));
    await bridge.close();
    await expectLater(Socket.connect('127.0.0.1', bridge.port), throwsA(isA<SocketException>()));
  });

  test('mode 不使用代理 ignores proxy environment variables', () {
    final env = {'https_proxy': 'http://evil:1', 'http_proxy': 'http://evil:1'};
    final overrides = ProxyHttpOverrides();
    expect(overrides.route(Uri.parse('https://youtube.com/'), environment: env), 'DIRECT');
    overrides.useEnvironment = true;
    expect(overrides.route(Uri.parse('https://youtube.com/'), environment: env), 'PROXY evil:1');
    overrides.endpoint = '127.0.0.1:9';
    expect(overrides.route(Uri.parse('https://youtube.com/'), environment: env), 'PROXY 127.0.0.1:9');
    expect(overrides.route(Uri.parse('http://localhost:5/'), environment: env), 'DIRECT');
    // Cast devices on the home network.
    for (final host in ['192.168.1.20', '10.0.0.5', '172.20.1.1', 'tv.local', '[fe80::1]']) {
      expect(overrides.route(Uri.parse('http://$host:8008/'), environment: env), 'DIRECT', reason: host);
    }
    expect(overrides.route(Uri.parse('http://172.32.0.1/'), environment: env), 'PROXY 127.0.0.1:9');
  });

  test('SOCKS settings keep their login and are recognised', () {
    expect(NetworkProxy.normalize('socks5h://me:p%40ss@h:1080'), 'socks5h://me:p%40ss@h:1080');
    expect(NetworkProxy.normalize('http://me:x@h:1'), 'http://h:1');
    expect(const NetworkProxy('socks5://me:x@h:1').isSocks, isTrue);
    expect(const NetworkProxy('socks5://me:x@h:1').redacted, 'socks5://h:1');
    expect(const NetworkProxy('http://h:1').isSocks, isFalse);
    expect(NetworkProxy.direct.isSocks, isFalse);
  });
}
