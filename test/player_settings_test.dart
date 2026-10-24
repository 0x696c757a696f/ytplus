import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/decoder_status.dart';
import 'package:lumtub/player_settings.dart';
import 'package:lumtub/video_codec.dart';

void main() {
  test('invalid persisted values return safe defaults', () {
    final settings = PlayerSettings.fromJson({
      'hwdec': 'unsafe',
      'cacheSeconds': -4,
      'subtitleScale': 99,
      'customOptions': {'vo': 'gpu-next', 'scale': 'lanczos'},
    });
    expect(settings.hwdec, 'auto-safe');
    expect(settings.cacheSeconds, 60);
    expect(settings.subtitleScale, 3.0);
    expect(settings.customOptions, {'scale': 'lanczos'});
  });

  test('custom option validation keeps media_kit output options private', () {
    expect(PlayerSettings.isSafeCustomOption('scale', 'lanczos'), isTrue);
    expect(PlayerSettings.isSafeCustomOption('vo', 'gpu-next'), isFalse);
    expect(PlayerSettings.isSafeCustomOption('cache', 'yes; quit'), isFalse);
  });

  test('keeps only recorded results for supported codecs', () {
    final settings = PlayerSettings.fromJson({
      'decoderResults': {
        'vp9': {'kind': 'hardware', 'hwdec': 'd3d11va'},
        'av1': {'kind': 'software'},
        'hevc': {'kind': 'hardware', 'hwdec': 'd3d11va'},
      },
    });
    expect(settings.decoderResults, {'vp9': const DecoderStatus.hardware('d3d11va'), 'av1': const DecoderStatus.software()});
  });

  test('reads decoder results saved as text by earlier builds', () {
    final settings = PlayerSettings.fromJson({
      'decoderResults': {'h264': '尚未验证', 'vp9': 'd3d11va', 'av1': '软件解码已验证'},
    });
    expect(settings.decoderResults, {
      'h264': const DecoderStatus.unverified(),
      'vp9': const DecoderStatus.hardware('d3d11va'),
      'av1': const DecoderStatus.software(),
    });
  });

  test('decoder results survive a save and load round trip', () {
    const original = PlayerSettings(decoderResults: {'vp9': DecoderStatus.hardware('d3d11va-copy')});
    final restored = PlayerSettings.fromJson(jsonDecode(jsonEncode(original.toJson())));
    expect(restored.decoderResults, original.decoderResults);
  });

  test('quality limit and autoplay survive a round trip', () {
    const original = PlayerSettings(maxHeight: 720, playOrder: PlayOrder.pause);
    final restored = PlayerSettings.fromJson(jsonDecode(jsonEncode(original.toJson())));
    expect(restored.maxHeight, 720);
    expect(restored.autoplayNext, isFalse);
  });

  test('quality limits outside 0 to 4320 fall back to automatic', () {
    expect(PlayerSettings.fromJson({'maxHeight': 9999}).maxHeight, 0);
    expect(PlayerSettings.fromJson({'maxHeight': 240}).maxHeight, 240);
    expect(PlayerSettings.fromJson({'maxHeight': '720'}).maxHeight, 0);
    expect(PlayerSettings.fromJson(const {}).autoplayNext, isTrue);
  });
  test('reads the switches of earlier builds', () {
    final settings = PlayerSettings.fromJson({'autoplayNext': false, 'autoSelectCodec': false});
    expect(settings.playOrder, PlayOrder.pause);
    expect(settings.strategy, PlaybackStrategy.quality);
  });

  test('migrates the old preferred codec to a strategy', () {
    expect(PlayerSettings.fromJson({'codec': 'any'}).strategy, PlaybackStrategy.quality);
    for (final old in ['auto', 'avc1', 'vp9', 'av01']) {
      expect(PlayerSettings.fromJson({'codec': old}).strategy, PlaybackStrategy.auto);
    }
    expect(PlayerSettings.fromJson(const {}).strategy, PlaybackStrategy.auto);
    expect(PlayerSettings.fromJson(const {}).disabledCodecs, isEmpty);
    expect(PlayerSettings.fromJson({'strategy': 'bogus'}).strategy, PlaybackStrategy.auto);
  });

  test('strategy and disabled codecs survive a round trip by name', () {
    const original = PlayerSettings(strategy: PlaybackStrategy.lowResource, disabledCodecs: {VideoCodec.av1, VideoCodec.vp8});
    final json = jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    expect(json['disabledCodecs'], ['av1', 'vp8']);
    final restored = PlayerSettings.fromJson(json);
    expect(restored.strategy, PlaybackStrategy.lowResource);
    expect(restored.disabledCodecs, {VideoCodec.av1, VideoCodec.vp8});
    expect(PlayerSettings.fromJson({'disabledCodecs': ['av1', 'nope', 3]}).disabledCodecs, {VideoCodec.av1});
  });

  test('new player preferences survive a round trip', () {
    const original = PlayerSettings(
      speeds: [0.5, 1.0, 2.5],
      defaultSpeed: 1.25,
      volumeMax: 150,
      subtitleMode: SubtitleMode.always,
      subtitleLanguage: SubtitleLanguage.en,
      sponsorCategories: {'sponsor', 'intro'},
      videoSync: VideoSync.displayResample,
    );
    final restored = PlayerSettings.fromJson(jsonDecode(jsonEncode(original.toJson())));
    expect(restored.speeds, [0.5, 1.0, 2.5]);
    expect(restored.defaultSpeed, 1.25);
    expect(restored.volumeMax, 150);
    expect(restored.subtitleMode, SubtitleMode.always);
    expect(restored.subtitleLanguage, SubtitleLanguage.en);
    expect(restored.sponsorCategories, {'sponsor', 'intro'});
    expect(restored.videoSync, VideoSync.displayResample);
  });

  test('reads mpv.conf lines and refuses unsafe ones', () {
    final (options, rejected) = parseMpvConf("""
d3d11va-zero-copy=yes

# 只对这些常见编码尝试硬解
hwdec-codecs = h264,vc1,hevc,vp8,vp9,av1,prores,ffv1

# 允许直接解码到 GPU 显存
vd-lavc-dr = auto
--deband
no-interpolation
scale="ewa_lanczossharp"  # sharper
script=evil.lua
vo=gpu-next
[profile]
""");
    expect(options, {
      'd3d11va-zero-copy': 'yes',
      'hwdec-codecs': 'h264,vc1,hevc,vp8,vp9,av1,prores,ffv1',
      'vd-lavc-dr': 'auto',
      'deband': 'yes',
      'interpolation': 'no',
      'scale': 'ewa_lanczossharp',
    });
    expect(rejected.map((r) => r.$1), ['script=evil.lua', 'vo=gpu-next', '[profile]']);
  });

  test('hwdec is an ordered list of known decoders', () {
    expect(PlayerSettings.fromJson({'hwdec': 'd3d11va,nvdec,auto-safe'}).hwdec, 'd3d11va,nvdec,auto-safe');
    expect(PlayerSettings.fromJson({'hwdec': 'd3d11va,unknown'}).hwdec, 'auto-safe');
    expect(PlayerSettings.fromJson({'hwdec': 'no'}).hwdec, 'no');
  });

  test('earlier custom options become mpv.conf lines', () {
    final settings = PlayerSettings.fromJson({'customOptions': {'scale': 'lanczos', 'vo': 'gpu-next'}});
    expect(settings.mpvConf, 'scale=lanczos\nvo=gpu-next');
    expect(settings.customOptions, {'scale': 'lanczos'});
  });

  test('PiliNara mpv options survive a round trip', () {
    const original = PlayerSettings(
      hwdec: 'd3d12va,d3d11va',
      hwdecCodecs: 'h264,av1',
      d3d11vaZeroCopy: true,
      directRendering: 'yes',
      autosync: 30,
      audioFilter: 'loudnorm=I=-16:LRA=11:TP=-1.5',
      picture: {'brightness': 10, 'gamma': -5},
      audioDelayMs: -120,
      videoSync: VideoSync.displayTempo,
      mpvConf: 'deband=yes',
    );
    final restored = PlayerSettings.fromJson(jsonDecode(jsonEncode(original.toJson())));
    expect(restored.toJson(), original.toJson());
  });
}
