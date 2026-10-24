import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/player_option_applicator.dart';
import 'package:lumtub/player_settings.dart';

void main() {
  test('maps supported UI settings to libmpv options', () {
    const settings = PlayerSettings(
      hwdec: 'd3d11va',
      scale: 'lanczos',
      deband: true,
      cacheMode: 'yes',
      cacheSeconds: 45,
      cacheMemoryMb: 128,
    );
    final options = PlayerOptionApplicator.optionsFor(settings);
    expect(options['hwdec'], 'd3d11va');
    expect(options['scale'], 'lanczos');
    expect(options['deband'], 'yes');
    expect(options['cache-secs'], '45');
    expect(options['demuxer-max-bytes'], '128MiB');
  });
  test('subtitle preferences become slang and yt-dlp options', () {
    expect(PlayerOptionApplicator.optionsFor(const PlayerSettings())['slang'], '');
    expect(PlayerOptionApplicator.optionsFor(const PlayerSettings())['ytdl-raw-options'], '');
    final options = PlayerOptionApplicator.optionsFor(const PlayerSettings(subtitleMode: SubtitleMode.always, subtitleLanguage: SubtitleLanguage.en));
    expect(options['slang'], startsWith('en,'));
    expect(options['ytdl-raw-options'], 'sub-langs=en.*,write-auto-subs=');
    expect(
      PlayerOptionApplicator.ytdlRawOptions(const PlayerSettings(), infoJson: r'C:\Users\A,B\info\dQw4w9WgXcQ.json'),
      r'load-info-json=%34%C:\Users\A,B\info\dQw4w9WgXcQ.json',
    );
    expect(PlayerOptionApplicator.ytdlRawOptions(const PlayerSettings(), infoJson: '/tmp/x.json'), 'load-info-json=/tmp/x.json');
  });

  test('single cycle loops the file in mpv', () {
    expect(PlayerOptionApplicator.optionsFor(const PlayerSettings(playOrder: PlayOrder.singleCycle))['loop-file'], 'inf');
    expect(PlayerOptionApplicator.optionsFor(const PlayerSettings())['loop-file'], 'no');
  });

  test('autosync off is 0, not no, which mpv reads as -1', () {
    expect(PlayerOptionApplicator.optionsFor(const PlayerSettings())['autosync'], '0');
  });

  test('PiliNara mpv options and custom lines reach libmpv, custom lines win', () {
    const settings = PlayerSettings(
      d3d11vaZeroCopy: true,
      autosync: 30,
      audioFilter: 'dynaudnorm=g=5:f=250:r=0.9:p=0.5',
      picture: {'contrast': 12},
      audioDelayMs: 250,
      mpvConf: 'vd-lavc-dr=yes\nhwdec-codecs=h264,av1',
    );
    final options = PlayerOptionApplicator.optionsFor(settings);
    expect(options['d3d11va-zero-copy'], 'yes');
    expect(options['autosync'], '30');
    expect(options['af'], 'dynaudnorm=g=5:f=250:r=0.9:p=0.5');
    expect(options['contrast'], '12');
    expect(options['brightness'], '0');
    expect(options['audio-delay'], '0.25');
    expect(options['vd-lavc-dr'], 'yes');
    expect(options['hwdec-codecs'], 'h264,av1');
  });

  test('low resource use scales the cheapest way, other strategies keep the user scaler', () {
    final fast = PlayerOptionApplicator.optionsFor(const PlayerSettings(strategy: PlaybackStrategy.lowResource));
    expect(fast['dscale'], 'bilinear');
    expect(fast['scale'], 'bilinear');
    final normal = PlayerOptionApplicator.optionsFor(const PlayerSettings());
    expect(normal['scale'], 'spline36');
    expect(normal.containsKey('dscale'), isFalse);
  });
}
