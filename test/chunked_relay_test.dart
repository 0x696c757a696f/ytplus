import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/chunked_relay.dart';

void main() {
  late HttpServer upstream;
  late ChunkedRelay relay;
  final data = Uint8List.fromList(List.generate(1000, (i) => i % 251));
  final ranges = <String>[];
  var fail403 = false;

  setUp(() async {
    ranges.clear();
    fail403 = false;
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      final range = request.uri.queryParameters['range']!;
      ranges.add(range);
      if (fail403) {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final [from, to] = range.split('-').map(int.parse).toList();
      request.response.add(data.sublist(from, to + 1));
      await request.response.close();
    });
    relay = ChunkedRelay(chunkSize: 300);
    await relay.start();
  });

  tearDown(() async {
    await relay.close();
    await upstream.close(force: true);
  });

  Future<(int, List<int>, HttpHeaders)> get(String url, {String? range}) async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    client.close();
    return (response.statusCode, bytes, response.headers);
  }

  String source() => 'http://127.0.0.1:${upstream.port}/videoplayback?itag=137&clen=${data.length}&mime=video%2Fmp4&sig=a%2Bb';

  test('serves a whole stream in small upstream pieces', () async {
    final address = relay.register(source())!;
    final (status, bytes, headers) = await get(address);
    expect(status, 200);
    expect(bytes, data);
    expect(headers.contentType?.mimeType, 'video/mp4');
    expect(ranges, ['0-299', '300-599', '600-899', '900-999']);
  });

  test('answers range requests for seeking', () async {
    final address = relay.register(source())!;
    final (status, bytes, headers) = await get(address, range: 'bytes=550-');
    expect(status, 206);
    expect(headers.value(HttpHeaders.contentRangeHeader), 'bytes 550-999/1000');
    expect(bytes, data.sublist(550));
    expect(ranges, ['550-849', '850-999']);
    final (tail, end, _) = await get(address, range: 'bytes=-10');
    expect(tail, 206);
    expect(end, data.sublist(990));
    final (beyond, _, _) = await get(address, range: 'bytes=5000-');
    expect(beyond, 416);
  });

  test('serves only registered addresses and needs a known size', () async {
    expect(relay.register('http://127.0.0.1:1/videoplayback?itag=1'), isNull);
    final address = relay.register(source())!;
    final (status, _, _) = await get('$address-other');
    expect(status, 404);
  });

  test('stops at an expired address instead of retrying', () async {
    fail403 = true;
    final address = relay.register(source())!;
    var received = 0;
    try {
      received = (await get(address)).$2.length;
    } catch (_) {
      // The relay drops the connection mid-stream.
    }
    expect(received, lessThan(data.length));
    expect(ranges, ['0-299']);
  });
}
