import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/video_codec.dart';

void main() {
  test('reads the codec names yt-dlp and relays report', () {
    expect(VideoCodec.of('av01.0.12M.08'), VideoCodec.av1);
    expect(VideoCodec.of('vp09.00.51.08'), VideoCodec.vp9);
    expect(VideoCodec.of('vp9'), VideoCodec.vp9);
    expect(VideoCodec.of('vp09.02.51.10.01.09.16.09.00'), VideoCodec.vp9);
    expect(VideoCodec.of('avc1.640028'), VideoCodec.h264);
    expect(VideoCodec.of('VP8'), VideoCodec.vp8);
    expect(VideoCodec.of('none'), isNull);
    expect(VideoCodec.of(null), isNull);
    expect(VideoCodec.of('hev1'), isNull);
  });

  test('builds yt-dlp filters that cover every spelling', () {
    expect(VideoCodec.vp9.onlyFilter, "[vcodec~='^(vp09|vp9)']");
    expect(VideoCodec.av1.excludeFilter, '[vcodec!^=av01][vcodec!^=av1]');
  });
}
