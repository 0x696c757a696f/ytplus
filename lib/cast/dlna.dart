import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log.dart';
import 'cast_device.dart';
import 'cast_net.dart';

// DLNA / UPnP AV casting: SSDP search for MediaRenderers, then SOAP calls to
// their AVTransport service. Only dart:io; the XML involved is small and
// regular enough to read with a few patterns.

const mediaRendererType = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const avTransportPrefix = 'urn:schemas-upnp-org:service:AVTransport:';

/// The SSDP search for UPnP media renderers.
String ssdpSearchRequest({int mx = 2}) => 'M-SEARCH * HTTP/1.1\r\n'
    'HOST: 239.255.255.250:1900\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: $mx\r\n'
    'ST: $mediaRendererType\r\n'
    'USER-AGENT: Lumtub UPnP/1.1\r\n\r\n';

/// The fields of an SSDP reply that matter here.
class SsdpResponse {
  const SsdpResponse({required this.location, this.usn = '', this.st = ''});
  final Uri location;
  final String usn;
  final String st;
}

/// An SSDP search reply (or NOTIFY), or null when it names no http location.
SsdpResponse? parseSsdpResponse(String text) {
  final lines = const LineSplitter().convert(text);
  if (lines.isEmpty || !(lines.first.startsWith('HTTP/1.1 200') || lines.first.startsWith('NOTIFY'))) return null;
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0) headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
  }
  final location = Uri.tryParse(headers['location'] ?? '');
  if (location == null || !location.hasScheme || !location.scheme.startsWith('http') || location.host.isEmpty) return null;
  return SsdpResponse(location: location, usn: headers['usn'] ?? '', st: headers['st'] ?? headers['nt'] ?? '');
}

String xmlEscape(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');

String xmlUnescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
      return code == null ? m[0]! : String.fromCharCode(code);
    })
    .replaceAll('&amp;', '&');

/// The text of the first `<name>` element in [xml], ignoring namespace prefixes.
String? xmlText(String xml, String name) {
  final match = RegExp('<(?:\\w+:)?$name(?:\\s[^>]*)?>([\\s\\S]*?)</(?:\\w+:)?$name\\s*>').firstMatch(xml);
  return match == null ? null : xmlUnescape(match[1]!.trim());
}

/// One service of a UPnP device.
class UpnpService {
  const UpnpService(this.type, this.controlUrl);
  final String type;
  final Uri controlUrl;
}

/// A UPnP device description, as far as casting needs it.
class DlnaDescription {
  const DlnaDescription({required this.name, required this.udn, required this.services});
  final String name;
  final String udn;
  final List<UpnpService> services;

  UpnpService? get avTransport => services.where((s) => s.type.startsWith(avTransportPrefix)).firstOrNull;
}

/// Reads the description at [location]; control addresses are made absolute
/// against `URLBase` or [location].
DlnaDescription parseDeviceDescription(String xml, Uri location) {
  final baseText = xmlText(xml, 'URLBase');
  final base = baseText != null && Uri.tryParse(baseText)?.hasScheme == true ? Uri.parse(baseText) : location;
  final services = <UpnpService>[];
  for (final block in RegExp(r'<service(?:\s[^>]*)?>([\s\S]*?)</service>').allMatches(xml)) {
    final type = xmlText(block[1]!, 'serviceType');
    final control = xmlText(block[1]!, 'controlURL');
    if (type == null || control == null || control.isEmpty) continue;
    services.add(UpnpService(type, base.resolve(control)));
  }
  final name = xmlText(xml, 'friendlyName');
  return DlnaDescription(name: name == null || name.isEmpty ? location.host : name, udn: xmlText(xml, 'UDN') ?? location.toString(), services: services);
}

/// The SOAP request body for [action] of [serviceType].
String soapEnvelope(String serviceType, String action, Map<String, String> arguments) => '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body><u:$action xmlns:u="$serviceType">'
    '${arguments.entries.map((e) => '<${e.key}>${xmlEscape(e.value)}</${e.key}>').join()}'
    '</u:$action></s:Body></s:Envelope>';

/// The output arguments of a SOAP response, or throws [CastException] with
/// the UPnP error when the body is a fault.
Map<String, String> parseSoapResponse(String xml) {
  if (xml.contains('Fault>')) {
    final code = xmlText(xml, 'errorCode');
    final description = xmlText(xml, 'errorDescription') ?? xmlText(xml, 'faultstring') ?? '';
    throw CastException('UPnP ${code ?? 'error'}${description.isEmpty ? '' : ': $description'}');
  }
  final response = RegExp(r'<(?:\w+:)?\w+Response(?:\s[^>]*)?>([\s\S]*?)</(?:\w+:)?\w+Response\s*>').firstMatch(xml);
  final out = <String, String>{};
  if (response == null) return out;
  for (final m in RegExp(r'<(\w+)(?:\s[^>]*)?>([\s\S]*?)</\1>|<(\w+)\s*/>').allMatches(response[1]!)) {
    if (m[3] != null) {
      out[m[3]!] = '';
    } else {
      out[m[1]!] = xmlUnescape(m[2]!.trim());
    }
  }
  return out;
}

/// DIDL-Lite metadata naming the video, which many renderers want.
String didlLite({required String title, required String url, required String mime}) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '<item id="0" parentID="-1" restricted="1"><dc:title>${xmlEscape(title)}</dc:title>'
    '<upnp:class>object.item.videoItem</upnp:class>'
    '<res protocolInfo="http-get:*:$mime:DLNA.ORG_OP=01;DLNA.ORG_FLAGS=01700000000000000000000000000000">${xmlEscape(url)}</res>'
    '</item></DIDL-Lite>';

/// `H:MM:SS` as UPnP writes positions.
String formatUpnpTime(Duration time) {
  final s = time.inSeconds;
  return '${s ~/ 3600}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// A UPnP time such as `0:01:23` or `00:01:23.500`; null for `NOT_IMPLEMENTED`
/// and the like.
Duration? parseUpnpTime(String? text) {
  final m = RegExp(r'^\+?(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d+))?').firstMatch(text?.trim() ?? '');
  if (m == null) return null;
  return Duration(hours: int.parse(m[1]!), minutes: int.parse(m[2]!), seconds: int.parse(m[3]!), milliseconds: m[4] == null ? 0 : (double.parse('0.${m[4]}') * 1000).round());
}

CastState dlnaState(String? transportState) => switch (transportState) {
      'PLAYING' => CastState.playing,
      'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => CastState.paused,
      'TRANSITIONING' => CastState.loading,
      _ => CastState.stopped,
    };

/// A UPnP media renderer, driven through its AVTransport service.
class DlnaDevice implements CastDevice {
  DlnaDevice({required this.name, required this.id, required this.serviceType, required this.controlUrl, HttpClient? client})
      : _client = (client ?? HttpClient())..connectionTimeout = const Duration(seconds: 5);

  @override
  final String name;
  @override
  final String id;
  @override
  CastProtocol get protocol => CastProtocol.dlna;
  final String serviceType;
  final Uri controlUrl;
  final HttpClient _client;

  Future<Map<String, String>> _soap(String action, [Map<String, String> arguments = const {}]) async {
    final body = utf8.encode(soapEnvelope(serviceType, action, {'InstanceID': '0', ...arguments}));
    try {
      final request = await _client.postUrl(controlUrl);
      request.headers
        ..set('Content-Type', 'text/xml; charset="utf-8"')
        ..set('SOAPACTION', '"$serviceType#$action"', preserveHeaderCase: true);
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decodeStream(response).timeout(const Duration(seconds: 8));
      if (response.statusCode >= 400 && !text.contains('Fault>')) throw CastException('HTTP ${response.statusCode}');
      return parseSoapResponse(text);
    } on SocketException catch (e) {
      throw CastException(e.message);
    } on TimeoutException {
      throw const CastException('timed out');
    } on HttpException catch (e) {
      throw CastException(e.message);
    }
  }

  @override
  Future<void> load(CastMedia media) async {
    await _soap('SetAVTransportURI', {
      'CurrentURI': media.url,
      'CurrentURIMetaData': didlLite(title: media.title, url: media.url, mime: media.mime),
    });
    await _soap('Play', {'Speed': '1'});
    if (media.start > const Duration(seconds: 1)) unawaited(_seekWhenReady(media.start));
  }

  /// Renderers refuse to seek before they play; tries until they do.
  Future<void> _seekWhenReady(Duration position) async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        final s = await status();
        if (s?.state == CastState.playing || s?.state == CastState.paused) {
          await seek(position);
          return;
        }
      } on CastException catch (e) {
        logInfo('DLNA 投屏跳转失败：$e');
      }
    }
  }

  @override
  Future<void> play() => _soap('Play', {'Speed': '1'});
  @override
  Future<void> pause() => _soap('Pause');
  @override
  Future<void> seek(Duration position) => _soap('Seek', {'Unit': 'REL_TIME', 'Target': formatUpnpTime(position)});

  @override
  Future<void> stop() async {
    try {
      await _soap('Stop');
    } finally {
      await close();
    }
  }

  @override
  Future<CastStatus?> status() async {
    try {
      final transport = await _soap('GetTransportInfo');
      final position = await _soap('GetPositionInfo');
      return CastStatus(
        state: dlnaState(transport['CurrentTransportState']),
        position: parseUpnpTime(position['RelTime']) ?? Duration.zero,
        duration: parseUpnpTime(position['TrackDuration']) ?? Duration.zero,
      );
    } on CastException {
      return null;
    }
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

/// Searches the LAN for media renderers for [timeout], emitting each once.
Stream<CastDevice> discoverDlna({Duration timeout = const Duration(seconds: 6)}) {
  final controller = StreamController<CastDevice>();
  final sockets = <RawDatagramSocket>[];
  final seen = <String>{};
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  Timer? finish;
  Timer? repeat;

  Future<void> describe(SsdpResponse found) async {
    try {
      final request = await http.getUrl(found.location);
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return;
      final xml = await utf8.decodeStream(response).timeout(const Duration(seconds: 4));
      final description = parseDeviceDescription(xml, found.location);
      final service = description.avTransport;
      if (service == null || !seen.add(description.udn) || controller.isClosed) return;
      controller.add(DlnaDevice(name: description.name, id: description.udn, serviceType: service.type, controlUrl: service.controlUrl));
    } catch (e) {
      logInfo('读取 DLNA 设备描述 ${found.location} 失败：$e');
    }
  }

  Future<void> close() async {
    finish?.cancel();
    repeat?.cancel();
    for (final s in sockets) {
      s.close();
    }
    http.close(force: true);
    if (!controller.isClosed) await controller.close();
  }

  controller.onListen = () async {
    final target = InternetAddress('239.255.255.250');
    final data = utf8.encode(ssdpSearchRequest());
    final locations = <String>{};
    for (final address in await localIPv4Addresses()) {
      try {
        final socket = await RawDatagramSocket.bind(address, 0);
        sockets.add(socket);
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = socket.receive();
          final found = packet == null ? null : parseSsdpResponse(utf8.decode(packet.data, allowMalformed: true));
          if (found != null && locations.add(found.location.toString())) unawaited(describe(found));
        });
      } on SocketException catch (e) {
        logInfo('DLNA 搜索无法使用 $address：${e.message}');
      }
    }
    void search() {
      for (final s in sockets) {
        try {
          s.send(data, target, 1900);
        } on SocketException {
          // That interface is not usable now.
        }
      }
    }

    search();
    repeat = Timer.periodic(const Duration(seconds: 2), (_) => search());
    finish = Timer(timeout, close);
  };
  controller.onCancel = close;
  return controller.stream;
}
