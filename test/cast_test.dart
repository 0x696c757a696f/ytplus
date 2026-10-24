import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/cast/cast_controller.dart';
import 'package:lumtub/cast/cast_device.dart';
import 'package:lumtub/cast/cast_stream.dart';
import 'package:lumtub/cast/chromecast.dart';
import 'package:lumtub/cast/dlna.dart';
import 'package:lumtub/cast/mdns.dart';
import 'package:lumtub/invidious_streams.dart';
import 'package:lumtub/piped_streams.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/video_codec.dart';

const _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
<URLBase>http://192.168.1.20:8080/</URLBase>
<device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>Living Room &amp; TV</friendlyName><UDN>uuid:1234-abcd</UDN>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/rc/control</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/upnp/control/AVTransport</controlURL></service>
</serviceList></device></root>''';

Uint8List _mdnsPacket() {
  final out = BytesBuilder();
  out.add([0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0]);
  final ptrName = <int>[];
  for (final label in ['_googlecast', '_tcp', 'local']) {
    ptrName
      ..add(label.length)
      ..addAll(utf8.encode(label));
  }
  ptrName.add(0);
  // Record 1: name at offset 12.
  out.add(ptrName);
  out.add([0, 12, 0x00, 1, 0, 0, 0, 120]);
  final ptrData = [14, ...utf8.encode('Chromecast-abc'), 0xC0, 12];
  out.add([0, ptrData.length]);
  out.add(ptrData);
  // Record 2: SRV for the instance name (written out in full).
  final srvName = BytesBuilder()
    ..addByte(14)
    ..add(utf8.encode('Chromecast-abc'))
    ..add([0xC0, 12]);
  out.add(srvName.toBytes());
  final target = [6, ...utf8.encode('abc123'), 5, ...utf8.encode('local'), 0];
  out.add([0, 33, 0x80, 1, 0, 0, 0, 120, 0, 6 + target.length, 0, 0, 0, 0, 0x1F, 0x49]);
  out.add(target);
  // Record 3: TXT.
  out.add(srvName.toBytes());
  final txt = <int>[];
  for (final entry in ['id=0f1e2d', 'fn=Bedroom TV', 'md=Chromecast']) {
    txt
      ..add(entry.length)
      ..addAll(utf8.encode(entry));
  }
  out.add([0, 16, 0x80, 1, 0, 0, 0, 120, 0, txt.length]);
  out.add(txt);
  // Record 4: A record for the target.
  out.add(target);
  out.add([0, 1, 0x80, 1, 0, 0, 0, 120, 0, 4, 192, 168, 1, 77]);
  return out.toBytes();
}

class _FakeCastDevice implements CastDevice {
  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  CastProtocol get protocol => CastProtocol.dlna;
  final calls = <String>[];
  CastStatus? next;
  @override
  Future<void> load(CastMedia media) async => calls.add('load ${media.url}');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> seek(Duration position) async => calls.add('seek ${position.inSeconds}');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<CastStatus?> status() async => next;
  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  group('DLNA parsing', () {
    test('reads an SSDP reply', () {
      final found = parseSsdpResponse('HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.20:8080/desc.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:1234::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n');
      expect(found?.location.toString(), 'http://192.168.1.20:8080/desc.xml');
      expect(found?.st, contains('MediaRenderer'));
      expect(found?.usn, startsWith('uuid:1234'));
      expect(parseSsdpResponse('HTTP/1.1 500 Error\r\n\r\n'), isNull);
      expect(parseSsdpResponse('HTTP/1.1 200 OK\r\nST: x\r\n\r\n'), isNull);
      expect(ssdpSearchRequest(), allOf(contains('M-SEARCH * HTTP/1.1'), contains('ST: $mediaRendererType'), endsWith('\r\n\r\n')));
    });

    test('reads a device description', () {
      final d = parseDeviceDescription(_description, Uri.parse('http://192.168.1.20:8080/desc.xml'));
      expect(d.name, 'Living Room & TV');
      expect(d.udn, 'uuid:1234-abcd');
      expect(d.services, hasLength(2));
      expect(d.avTransport?.type, 'urn:schemas-upnp-org:service:AVTransport:1');
      expect(d.avTransport?.controlUrl.toString(), 'http://192.168.1.20:8080/upnp/control/AVTransport');
      // Without URLBase the description's own address is the base.
      final relative = parseDeviceDescription(_description.replaceAll(RegExp(r'<URLBase>.*</URLBase>'), ''), Uri.parse('http://10.0.0.5:49152/dev/desc.xml'));
      expect(relative.avTransport?.controlUrl.toString(), 'http://10.0.0.5:49152/upnp/control/AVTransport');
    });

    test('builds a SOAP envelope with escaped arguments', () {
      final body = soapEnvelope('urn:schemas-upnp-org:service:AVTransport:1', 'SetAVTransportURI', {'InstanceID': '0', 'CurrentURI': 'http://x/v?a=1&b=2'});
      expect(body, contains('<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'));
      expect(body, contains('<InstanceID>0</InstanceID>'));
      expect(body, contains('<CurrentURI>http://x/v?a=1&amp;b=2</CurrentURI>'));
      expect(body, endsWith('</s:Envelope>'));
    });

    test('parses SOAP responses and faults', () {
      const ok = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
          '<u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><Track>1</Track><TrackDuration>0:03:25</TrackDuration>'
          '<TrackMetaData>&lt;DIDL-Lite&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><RelTime>0:01:02</RelTime><AbsTime/></u:GetPositionInfoResponse></s:Body></s:Envelope>';
      final map = parseSoapResponse(ok);
      expect(map['RelTime'], '0:01:02');
      expect(map['TrackDuration'], '0:03:25');
      expect(map['TrackMetaData'], '<DIDL-Lite></DIDL-Lite>');
      expect(map['AbsTime'], '');
      const fault = '<s:Envelope xmlns:s="x"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>'
          '<detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>';
      expect(() => parseSoapResponse(fault), throwsA(isA<CastException>().having((e) => e.message, 'message', 'UPnP 701: Transition not available')));
    });

    test('formats DIDL-Lite and times', () {
      final didl = didlLite(title: 'A <b> & c', url: 'http://x/v?a=1&b=2', mime: 'video/mp4');
      expect(didl, contains('<dc:title>A &lt;b&gt; &amp; c</dc:title>'));
      expect(didl, contains('http-get:*:video/mp4:'));
      expect(didl, contains('>http://x/v?a=1&amp;b=2</res>'));
      expect(formatUpnpTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
      expect(parseUpnpTime('00:01:23.500'), const Duration(minutes: 1, seconds: 23, milliseconds: 500));
      expect(parseUpnpTime('NOT_IMPLEMENTED'), isNull);
      expect(dlnaState('PAUSED_PLAYBACK'), CastState.paused);
      expect(dlnaState('NO_MEDIA_PRESENT'), CastState.stopped);
    });
  });

  test('DlnaDevice talks SOAP to a renderer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final actions = <String>[];
    final bodies = <String>[];
    server.listen((request) async {
      final action = request.headers.value('soapaction')!;
      actions.add(action);
      bodies.add(await utf8.decodeStream(request));
      final name = action.split('#').last.replaceAll('"', '');
      final out = switch (name) {
        'GetTransportInfo' => '<CurrentTransportState>PLAYING</CurrentTransportState>',
        'GetPositionInfo' => '<RelTime>0:00:42</RelTime><TrackDuration>0:10:00</TrackDuration>',
        _ => '',
      };
      request.response
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write('<s:Envelope xmlns:s="x"><s:Body><u:${name}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$out</u:${name}Response></s:Body></s:Envelope>');
      await request.response.close();
    });
    final device = DlnaDevice(name: 'TV', id: 'uuid:1', serviceType: 'urn:schemas-upnp-org:service:AVTransport:1', controlUrl: Uri.parse('http://127.0.0.1:${server.port}/ctl'));
    await device.load(const CastMedia(url: 'http://v/x.mp4', title: 'Title'));
    expect(actions, ['"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"', '"urn:schemas-upnp-org:service:AVTransport:1#Play"']);
    expect(bodies.first, contains('<CurrentURI>http://v/x.mp4</CurrentURI>'));
    expect(bodies.first, contains('&lt;dc:title&gt;Title&lt;/dc:title&gt;'));
    await device.pause();
    await device.seek(const Duration(seconds: 90));
    expect(bodies.last, allOf(contains('<Unit>REL_TIME</Unit>'), contains('<Target>0:01:30</Target>')));
    final status = await device.status();
    expect(status?.state, CastState.playing);
    expect(status?.position, const Duration(seconds: 42));
    expect(status?.duration, const Duration(minutes: 10));
    await device.stop();
    expect(actions.last, endsWith('#Stop"'));
  });

  group('mDNS', () {
    test('asks for the Cast service', () {
      final q = mdnsQuery(googleCastService);
      expect(q.sublist(0, 12), [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      expect(utf8.decode(q.sublist(13, 24)), '_googlecast');
      expect(q.sublist(q.length - 5), [0, 0, 12, 0, 1]);
    });

    test('reads a reply with compressed names', () {
      final collector = MdnsCollector()..add(_mdnsPacket());
      final services = collector.services;
      expect(services, hasLength(1));
      expect(services.single.name, 'Bedroom TV');
      expect(services.single.id, '0f1e2d');
      expect(services.single.port, 8009);
      expect(services.single.host.address, '192.168.1.77');
    });

    test('ignores truncated packets', () {
      final packet = _mdnsPacket();
      final collector = MdnsCollector()..add(Uint8List.sublistView(packet, 0, packet.length - 20));
      expect(collector.services, isEmpty);
      collector.add(Uint8List.fromList([1, 2, 3]));
      expect(collector.services, isEmpty);
    });
  });

  group('CastMessage', () {
    const message = CastMessage(source: 'sender-0', destination: 'receiver-0', namespace: castConnectionNamespace, payload: '{"type":"CONNECT"}');

    test('encodes the fields in protobuf order', () {
      final bytes = encodeCastMessage(message);
      expect(bytes.sublist(0, 4), [0x08, 0x00, 0x12, 8]);
      expect(utf8.decode(bytes.sublist(4, 12)), 'sender-0');
      expect(bytes.sublist(12, 14), [0x1A, 10]);
      // payload_type STRING then payload_utf8 (field 6) last.
      expect(bytes.sublist(bytes.length - 18 - 4, bytes.length - 18), [0x28, 0x00, 0x32, 18]);
      expect(utf8.decode(bytes.sublist(bytes.length - 18)), '{"type":"CONNECT"}');
    });

    test('round-trips, including long payloads', () {
      final decoded = decodeCastMessage(encodeCastMessage(message));
      expect(decoded.source, 'sender-0');
      expect(decoded.destination, 'receiver-0');
      expect(decoded.namespace, castConnectionNamespace);
      expect(decoded.json, {'type': 'CONNECT'});
      final long = CastMessage(source: 'a', destination: 'b', namespace: 'c', payload: jsonEncode({'t': 'é' * 300}));
      expect(decodeCastMessage(encodeCastMessage(long)).payload, long.payload);
    });

    test('frames with a big-endian length and reassembles split chunks', () {
      final one = frameCastMessage(message);
      final body = encodeCastMessage(message);
      expect(one.sublist(0, 4), [0, 0, 0, body.length]);
      final reader = CastFrameReader();
      final both = [...one, ...one];
      expect(reader.add(both.sublist(0, 3)), isEmpty);
      expect(reader.add(both.sublist(3, one.length + 5)), hasLength(1));
      expect(reader.add(both.sublist(one.length + 5)), hasLength(1));
      expect(() => CastFrameReader().add([0xFF, 0xFF, 0xFF, 0xFF]), throwsFormatException);
    });

    test('reads receiver and media status', () {
      final app = parseReceiverApp({
        'type': 'RECEIVER_STATUS',
        'status': {
          'applications': [
            {'appId': 'CC1AD845', 'transportId': 'web-5', 'sessionId': 'abc'},
          ],
        },
      }, defaultMediaReceiverId);
      expect(app?.transportId, 'web-5');
      expect(app?.sessionId, 'abc');
      expect(parseReceiverApp({'status': {'applications': []}}, defaultMediaReceiverId), isNull);
      final media = parseMediaStatus({
        'type': 'MEDIA_STATUS',
        'status': [
          {'mediaSessionId': 3, 'playerState': 'PAUSED', 'currentTime': 12.5, 'media': {'duration': 200.0}},
        ],
      });
      expect(media?.sessionId, 3);
      expect(media?.status.state, CastState.paused);
      expect(media?.status.position, const Duration(milliseconds: 12500));
      expect(media?.status.duration, const Duration(seconds: 200));
      expect(parseMediaStatus({'status': []}), isNull);
    });
  });

  test('ChromecastDevice launches the receiver, loads and controls media', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = <CastMessage>[];
    server.listen((socket) {
      final reader = CastFrameReader();
      void reply(String namespace, String source, Map<String, Object?> payload) =>
          socket.add(frameCastMessage(CastMessage(source: source, destination: 'sender-0', namespace: namespace, payload: jsonEncode(payload))));
      socket.listen((data) {
        for (final m in reader.add(data)) {
          received.add(m);
          final json = m.json!;
          final id = json['requestId'];
          switch (json['type']) {
            case 'LAUNCH':
              reply(castReceiverNamespace, 'receiver-0', {
                'type': 'RECEIVER_STATUS',
                'requestId': id,
                'status': {
                  'applications': [
                    {'appId': defaultMediaReceiverId, 'transportId': 'web-1', 'sessionId': 'sess-1'},
                  ],
                },
              });
            case 'LOAD':
              reply(castMediaNamespace, 'web-1', {
                'type': 'MEDIA_STATUS',
                'requestId': id,
                'status': [
                  {'mediaSessionId': 7, 'playerState': 'BUFFERING', 'currentTime': 5.0, 'media': {'duration': 100.0}},
                ],
              });
            case 'GET_STATUS':
              reply(castMediaNamespace, 'web-1', {
                'type': 'MEDIA_STATUS',
                'requestId': id,
                'status': [
                  {'mediaSessionId': 7, 'playerState': 'PLAYING', 'currentTime': 9.0},
                ],
              });
            case 'PLAY' || 'PAUSE' || 'SEEK':
              reply(castMediaNamespace, 'web-1', {'type': 'MEDIA_STATUS', 'requestId': id, 'status': []});
            case 'STOP':
              reply(castReceiverNamespace, 'receiver-0', {'type': 'RECEIVER_STATUS', 'requestId': id, 'status': {}});
          }
        }
      });
    });
    final device = ChromecastDevice(
      id: 'c1',
      name: 'Cast',
      host: InternetAddress.loopbackIPv4,
      port: server.port,
      connector: (host, port) => Socket.connect(host, port),
    );
    await device.load(const CastMedia(url: 'http://v/x.mp4', title: 'My video', start: Duration(seconds: 5)));
    final load = received.firstWhere((m) => m.json!['type'] == 'LOAD');
    expect(load.destination, 'web-1');
    expect(load.namespace, castMediaNamespace);
    expect(load.json!['media'], {
      'contentId': 'http://v/x.mp4',
      'contentType': 'video/mp4',
      'streamType': 'BUFFERED',
      'metadata': {'metadataType': 0, 'title': 'My video'},
    });
    expect(load.json!['currentTime'], 5.0);
    expect(received.first.json, {'type': 'CONNECT'});
    expect(received.first.destination, 'receiver-0');
    final status = await device.status();
    expect(status?.state, CastState.playing);
    expect(status?.position, const Duration(seconds: 9));
    expect(status?.duration, const Duration(seconds: 100));
    await device.pause();
    await device.seek(const Duration(seconds: 30));
    await device.play();
    final seek = received.firstWhere((m) => m.json!['type'] == 'SEEK');
    expect(seek.json!['mediaSessionId'], 7);
    expect(seek.json!['currentTime'], 30.0);
    await device.stop();
    expect(received.any((m) => m.json!['type'] == 'STOP' && m.json!['sessionId'] == 'sess-1'), isTrue);
    await expectLater(device.pause(), throwsA(isA<CastException>()));
  });

  group('what to cast', () {
    Map<String, dynamic> format(String id, {int? height, String v = 'avc1.4d401e', String a = 'mp4a.40.2', String ext = 'mp4', Object? fragments, String protocol = 'https', num tbr = 500}) =>
        {'format_id': id, 'url': 'https://v/$id', 'height': height, 'vcodec': v, 'acodec': a, 'ext': ext, 'protocol': protocol, 'tbr': tbr, 'fragments': fragments};

    test('picks the best progressive mp4 with sound from yt-dlp', () {
      final info = {
        'formats': [
          format('137', height: 1080, a: 'none'),
          format('140', v: 'none'),
          format('18', height: 360),
          format('22', height: 720),
          format('hls', height: 1080, protocol: 'm3u8_native'),
          format('webm', height: 1080, v: 'vp9', ext: 'webm'),
          format('frag', height: 1080, fragments: <Object>[1]),
          format('4k', height: 2160, v: 'av01.0.12M.08'),
        ],
      };
      expect(castSourceFromYtDlp(info)?.url, 'https://v/22');
      expect(castSourceFromYtDlp(info)?.height, 720);
      expect(castSourceFromYtDlp({'formats': [format('webm', height: 720, ext: 'webm')]}), isNull);
      expect(castSourceFromYtDlp({}), isNull);
    });

    test('skips muxed streams in a disabled codec', () {
      final info = {'formats': [format('22', height: 720), format('av1mux', height: 1080, v: 'av01.0.08M.08')]};
      expect(castSourceFromYtDlp(info)?.url, 'https://v/22');
      expect(castSourceFromYtDlp(info, settings: const PlayerSettings(disabledCodecs: {VideoCodec.h264}))?.url, 'https://v/av1mux');
      expect(castSourceFromYtDlp({'formats': [format('22', height: 720)]}, settings: const PlayerSettings(disabledCodecs: {VideoCodec.h264})), isNull);
    });

    test('picks a muxed stream from Piped and Invidious answers', () {
      final piped = PipedVideo.fromJson('https://p', {
        'videoStreams': [
          {'url': 'https://p/v1080', 'codec': 'avc1.640028', 'height': 1080, 'videoOnly': true, 'mimeType': 'video/mp4'},
          {'url': 'https://p/m360', 'codec': 'avc1.42001E', 'height': 360, 'videoOnly': false, 'mimeType': 'video/mp4', 'bitrate': 500000},
          {'url': 'https://p/m720', 'codec': 'avc1.64001F', 'height': 720, 'videoOnly': false, 'mimeType': 'video/mp4', 'bitrate': 900000},
          {'url': 'https://p/mwebm', 'codec': 'vp9', 'height': 1080, 'videoOnly': false, 'mimeType': 'video/webm'},
        ],
        'audioStreams': [],
      });
      expect(piped.muxed.map((s) => s.url), ['https://p/m360', 'https://p/m720']);
      expect(castSourceFromRelay(piped)?.url, 'https://p/m720');
      final invidious = parseInvidiousVideo('https://inv.example', {
        'adaptiveFormats': [],
        'formatStreams': [
          {'url': '/videoplayback?id=1', 'type': 'video/mp4; codecs="avc1.64001F, mp4a.40.2"', 'size': '1280x720', 'qualityLabel': '720p'},
        ],
      });
      expect(castSourceFromRelay(invidious)?.url, 'https://inv.example/videoplayback?id=1');
      expect(castSourceFromRelay(const PipedVideo(server: 's', video: [], audio: [])), isNull);
    });
  });

  group('CastController', () {
    test('starts, controls and ends a session', () async {
      final device = _FakeCastDevice();
      final controller = CastController();
      addTearDown(controller.dispose);
      await controller.start(device, const CastMedia(url: 'http://v', title: 'T', start: Duration(seconds: 3)), videoId: 'abc');
      expect(controller.active, isTrue);
      expect(controller.status?.position, const Duration(seconds: 3));
      await controller.togglePlay();
      expect(device.calls, ['load http://v', 'play']);
      await controller.togglePlay();
      expect(device.calls.last, 'pause');
      await controller.seek(const Duration(seconds: 20));
      expect(controller.status?.position, const Duration(seconds: 20));
      final at = await controller.stop();
      expect(at, const Duration(seconds: 20));
      expect(device.calls.last, 'stop');
      expect(controller.active, isFalse);
      expect(await controller.stop(), isNull);
    });

    test('polls less often while the window is hidden', () async {
      final controller = CastController();
      addTearDown(controller.dispose);
      expect(controller.pollInterval, const Duration(seconds: 1));
      controller.windowHidden = true;
      expect(controller.pollInterval, const Duration(seconds: 5));
      await controller.start(_FakeCastDevice(), const CastMedia(url: 'http://v', title: 'T'));
      controller.windowHidden = false;
      expect(controller.pollInterval, const Duration(seconds: 1));
      await controller.stop();
      expect(controller.active, isFalse);
    });

    test('a failed load leaves no session and reports the message', () async {
      final controller = CastController();
      addTearDown(controller.dispose);
      await expectLater(controller.start(_FailingDevice(), const CastMedia(url: 'u', title: 't')), throwsA(isA<CastException>()));
      expect(controller.active, isFalse);
    });
  });
}

class _FailingDevice extends _FakeCastDevice {
  @override
  Future<void> load(CastMedia media) => Future.error(const CastException('refused'));
}
