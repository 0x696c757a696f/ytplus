import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'app_directories.dart';
import 'decoder_status.dart';
import 'network_proxy.dart';
import 'piped_streams.dart';
import 'video_codec.dart';
import 'l10n/l10n.dart';

/// Heights offered in the quality menu; 0 means automatic.
const qualityHeights = [0, 2160, 1440, 1080, 720, 480, 360];

/// Speeds offered before the user edits the list, as in PiliNara.
const defaultSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

/// How playback picks among the codecs that are not disabled; see
/// `FormatPolicy`.
enum PlaybackStrategy {
  auto('智能自动（推荐）', '根据硬件解码能力和视频画质自动选择'),
  quality('画质优先', '优先分辨率、帧率和画质，允许软件解码'),
  lowResource('低资源占用优先', '尽可能使用硬件解码，降低 CPU 占用');

  const PlaybackStrategy(this._label, this._description);
  final String _label;
  final String _description;
  String get label => tr(_label);
  String get description => tr(_description);
}

enum AudioQuality {
  best('最高'),
  medium('中等（≤128 kbps）'),
  low('省流（≤64 kbps）');

  const AudioQuality(this._label);
  final String _label;
  String get label => tr(_label);
}

/// What happens when a video ends. Named and ordered like PiliNara's
/// `PlayRepeat`.
enum PlayOrder {
  pause('播完暂停'),
  listOrder('顺序播放'),
  singleCycle('单个循环'),
  listCycle('列表循环'),
  autoPlayRelated('自动连播');

  const PlayOrder(this._label);
  final String _label;
  String get label => tr(_label);
}

enum SubtitleMode {
  off('不自动开启'),
  manual('有人工字幕时开启'),
  always('总是开启（含自动生成字幕）');

  const SubtitleMode(this._label);
  final String _label;
  String get label => tr(_label);
}

enum SubtitleLanguage {
  /// Windows' language: simplified, traditional Chinese or English. Not the
  /// interface's, which is English for now.
  auto('跟随系统语言', '', ''),
  zh('简体中文优先', '(zh|en).*', 'zh-Hans,zh-CN,zh-SG,zh,zh-Hant,zh-TW,zh-HK,chi,zho,en,eng'),
  zhHant('繁體中文優先', '(zh|en).*', 'zh-Hant,zh-TW,zh-HK,zh,zh-Hans,zh-CN,chi,zho,en,eng'),
  en('英语优先', 'en.*', 'en,eng,en-US,en-GB'),
  ja('日语优先', '(ja|en).*', 'ja,jpn,en,eng'),
  ko('韩语优先', '(ko|en).*', 'ko,kor,en,eng'),
  fr('法语优先', '(fr|en).*', 'fr,fre,fra,en,eng'),
  de('德语优先', '(de|en).*', 'de,ger,deu,en,eng'),
  es('西班牙语优先', '(es|en).*', 'es,spa,en,eng'),
  pt('葡萄牙语优先', '(pt|en).*', 'pt,pt-BR,por,en,eng'),
  ru('俄语优先', '(ru|en).*', 'ru,rus,en,eng'),
  it('意大利语优先', '(it|en).*', 'it,ita,en,eng'),
  vi('越南语优先', '(vi|en).*', 'vi,vie,en,eng'),
  th('泰语优先', '(th|en).*', 'th,tha,en,eng'),
  id('印尼语优先', '(id|en).*', 'id,ind,en,eng'),
  ar('阿拉伯语优先', '(ar|en).*', 'ar,ara,en,eng'),
  hi('印地语优先', '(hi|en).*', 'hi,hin,en,eng');

  const SubtitleLanguage(this._label, this._ytDlpLangs, this._mpvLangs);
  final String _label;
  String get label => tr(_label);
  /// yt-dlp's `--sub-langs` value; a regex without commas so it fits in
  /// mpv's `ytdl-raw-options` list.
  final String _ytDlpLangs;
  String get ytDlpLangs => tr(resolved._ytDlpLangs);
  /// mpv's `slang`, in order of preference.
  final String _mpvLangs;
  String get mpvLangs => tr(resolved._mpvLangs);

  /// Windows' language; tests replace it.
  static Locale Function() systemLocale = () => PlatformDispatcher.instance.locale;

  /// [auto] as the language it stands for.
  SubtitleLanguage get resolved => this != auto
      ? this
      : switch (systemLocale()) {
          Locale(languageCode: 'zh', scriptCode: 'Hant') => zhHant,
          Locale(languageCode: 'zh', countryCode: 'TW' || 'HK' || 'MO') => zhHant,
          Locale(languageCode: 'zh') => zh,
          _ => en,
        };
}

/// mpv's `--video-sync` modes, as PiliNara lists them.
enum VideoSync {
  audio('audio', '跟随音频（默认）'),
  displayResample('display-resample', '按显示器刷新率重采样（更平滑）'),
  displayResampleVdrop('display-resample-vdrop', '重采样，必要时丢帧'),
  displayResampleDesync('display-resample-desync', '重采样，不同步音频'),
  displayTempo('display-tempo', '按显示器刷新率变速音频'),
  displayVdrop('display-vdrop', '跟随显示器，丢弃或重复视频帧'),
  displayAdrop('display-adrop', '跟随显示器，丢弃或重复音频'),
  displayDesync('display-desync', '跟随显示器，不同步音频'),
  desync('desync', '不同步（仅调试用）');

  const VideoSync(this._mpvValue, this._label);
  final String _mpvValue;
  String get mpvValue => tr(_mpvValue);
  final String _label;
  String get label => tr(_label);
}

/// mpv's `--hwdec` decoders that exist on Windows, from PiliNara's
/// `HwDecType`. The setting is an ordered list; mpv tries them in turn.
/// Decoders without "-copy" hand frames to the renderer in GPU memory (zero
/// copy); "-copy" ones copy them back to system memory first.
final hwdecChoices = <(String, String)>[
  ('no', tr('软件解码')),
  ('auto', tr('任意可用的硬件解码器')),
  ('auto-safe', tr('最佳且稳定的硬件解码器（默认）')),
  ('auto-copy', tr('带拷贝的最佳硬件解码器')),
  ('d3d12va', tr('DirectX 12（Windows 10 及以上，零拷贝）')),
  ('d3d12va-copy', tr('DirectX 12（回拷）')),
  ('d3d11va', tr('DirectX 11（Windows 8 及以上，零拷贝）')),
  ('d3d11va-copy', tr('DirectX 11（回拷）')),
  ('dxva2', tr('DXVA2（Windows 7 及以上，零拷贝）')),
  ('dxva2-copy', tr('DXVA2（回拷）')),
  ('nvdec', tr('NVDEC（NVIDIA 独占，零拷贝）')),
  ('nvdec-copy', tr('NVDEC（NVIDIA 独占，回拷）')),
  ('vulkan', tr('Vulkan（实验性，零拷贝）')),
  ('vulkan-copy', tr('Vulkan（实验性，回拷）')),
  ('cuda', tr('CUDA（NVIDIA 独占，过时，零拷贝）')),
  ('cuda-copy', tr('CUDA（NVIDIA 独占，过时，回拷）')),
  ('amf', tr('AMF（AMD 独占，零拷贝）')),
  ('amf-copy', tr('AMF（AMD 独占，回拷）')),
  ('qsv', tr('Quick Sync Video（Intel 独占，零拷贝）')),
  ('qsv-copy', tr('Quick Sync Video（Intel 独占，回拷）')),
];

/// Codecs offered for `--hwdec-codecs`.
const hwdecCodecChoices = ['h264', 'hevc', 'vp8', 'vp9', 'av1', 'vc1', 'mpeg2video', 'mpeg4', 'wmv3', 'prores', 'prores_raw', 'ffv1', 'dpx'];
const defaultHwdecCodecs = 'h264,vc1,hevc,vp8,vp9,av1,prores,ffv1';

/// PiliNara's 音量均衡 presets, as mpv `--af` filters.
List<(String, String)> get audioFilterPresets => [
  ('', tr('关闭')),
  ('dynaudnorm=g=5:f=250:r=0.9:p=0.5', tr('预设 dynaudnorm（动态均衡）')),
  ('loudnorm=I=-16:LRA=11:TP=-1.5', tr('预设 loudnorm（响度标准化）')),
];

/// Picture adjustments PiliNara offers in its player, as mpv properties.
List<(String, String)> get pictureProperties => [
      ('brightness', tr('亮度')),
      ('contrast', tr('对比度')),
      ('saturation', tr('饱和度')),
      ('gamma', tr('伽马')),
      ('hue', tr('色调')),
    ];

/// Options a custom line may not set: ones that load code or files, write
/// files, or would break media_kit's rendering and playback control.
const _blockedOptions = {
  'vo', 'wid', 'include', 'config', 'config-dir', 'ytdl', 'ytdl-path', 'idle', 'keep-open', 'force-window',
  'log-file', 'o', 'of', 'ofopts', 'ovc', 'ovcopts', 'oac', 'oacopts', 'stream-record', 'record-file',
  'input-conf', 'use-filedir-conf', 'watch-later-dir', 'watch-later-directory', 'screenshot-directory', 'screenshot-dir',
};
const _blockedPrefixes = ['script', 'load-', 'input-ipc', 'dump-', 'glsl-shader', 'lua'];

/// One line of a custom mpv.conf that was not applied, and why.
typedef RejectedOption = (String line, String reason);

/// Reads mpv.conf syntax: `key=value`, `key = value`, `--key=value`, a bare
/// `key` for yes and `no-key` for no, with `#` comments.
(Map<String, String>, List<RejectedOption>) parseMpvConf(String text) {
  final options = <String, String>{};
  final rejected = <RejectedOption>[];
  for (final raw in const LineSplitter().convert(text)) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final comment = line.indexOf(RegExp(r'\s#'));
    if (comment >= 0) line = line.substring(0, comment).trim();
    if (line.startsWith('[')) {
      rejected.add((raw.trim(), tr('不支持配置组（profile）')));
      continue;
    }
    if (line.startsWith('--')) line = line.substring(2);
    final eq = line.indexOf('=');
    var key = (eq < 0 ? line : line.substring(0, eq)).trim().toLowerCase();
    var value = eq < 0 ? 'yes' : line.substring(eq + 1).trim();
    if (eq < 0 && key.startsWith('no-') && key.length > 3) {
      key = key.substring(3);
      value = 'no';
    }
    if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    final reason = PlayerSettings.customOptionProblem(key, value);
    if (reason == null) {
      options[key] = value;
    } else {
      rejected.add((raw.trim(), reason));
    }
  }
  return (options, rejected);
}

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((value) => value.name == name).firstOrNull ?? fallback;

class PlayerSettings {
  final String hwdec;
  final String scale;
  final bool deband;
  final bool interpolation;
  final double subtitleScale;
  final int subtitlePosition;
  final String cacheMode;
  final int cacheSeconds;
  final int cacheMemoryMb;
  final PlaybackStrategy strategy;
  /// Codecs no strategy may pick, whatever the video offers.
  final Set<VideoCodec> disabledCodecs;
  final AudioQuality audioQuality;
  /// mpv's `audio-device` name, or `auto` for the Windows default.
  final String audioDevice;
  final VideoSync videoSync;
  /// Highest video height to request, or 0 for no limit.
  final int maxHeight;
  final PlayOrder playOrder;
  final double defaultSpeed;
  final List<double> speeds;
  /// Volume when Lumtub starts, 0–100.
  final int defaultVolume;
  /// Highest volume allowed; above 100 boosts quiet videos.
  final int volumeMax;
  final SubtitleMode subtitleMode;
  final SubtitleLanguage subtitleLanguage;
  final double subtitleBorder;
  final bool subtitleBackground;
  final bool subtitleBold;
  /// Skip segments marked on SponsorBlock. Off by default because it asks a
  /// third-party server, even if only by an anonymous hash prefix.
  final bool sponsorBlock;
  /// Shows Return YouTube Dislike's estimate of the dislikes.
  final bool returnDislike;
  /// DeArrow's titles and thumbnails in place of YouTube's.
  final bool deArrowTitles;
  final bool deArrowThumbnails;
  final Set<String> sponsorCategories;
  final bool sponsorNotice;
  final String? cachePath;
  final int? cacheLimitGb;
  /// Extra libmpv options in mpv.conf syntax, applied after all others.
  final String mpvConf;
  final Map<String, DecoderStatus> decoderResults;
  /// `--hwdec-codecs`: codecs hardware decoding is tried for.
  final String hwdecCodecs;
  /// `--d3d11va-zero-copy`.
  final bool d3d11vaZeroCopy;
  /// libmpv draws subtitles itself (libass), so the mpv subtitle options
  /// apply; off, Flutter draws them over the video. Takes effect on restart.
  final bool libassSubtitles;
  /// How yt-dlp, libmpv and the app reach YouTube.
  final ProxyMode proxyMode;
  /// The proxy for [ProxyMode.custom], such as `127.0.0.1:7890`.
  final String proxyAddress;
  /// Where playback streams come from; Piped by default, the user's choice.
  final PlaybackSource playbackSource;
  /// The Piped API server for [PlaybackSource.pipedCustom].
  final String pipedServer;
  /// The Invidious instance for [PlaybackSource.invidiousCustom].
  final String invidiousServer;
  /// `--vd-lavc-dr`: auto, yes or no.
  final String directRendering;
  /// `--autosync`; 0 turns it off.
  final int autosync;
  /// `--af`, such as a loudness filter; empty for none.
  final String audioFilter;
  /// Brightness, contrast, saturation, gamma and hue, -100 to 100.
  final Map<String, int> picture;
  final int audioDelayMs;

  /// The usable lines of [mpvConf].
  Map<String, String> get customOptions => parseMpvConf(mpvConf).$1;

  static const defaultSponsorCategories = {'sponsor', 'selfpromo', 'interaction'};

  const PlayerSettings({
    this.hwdec = 'auto-safe',
    this.scale = 'spline36',
    this.deband = false,
    this.interpolation = false,
    this.subtitleScale = 1.0,
    this.subtitlePosition = 100,
    this.cacheMode = 'auto',
    this.cacheSeconds = 60,
    this.cacheMemoryMb = 150,
    this.strategy = PlaybackStrategy.auto,
    this.disabledCodecs = const {},
    this.audioQuality = AudioQuality.best,
    this.audioDevice = 'auto',
    this.videoSync = VideoSync.audio,
    this.maxHeight = 0,
    this.playOrder = PlayOrder.autoPlayRelated,
    this.defaultSpeed = 1.0,
    this.speeds = defaultSpeeds,
    this.defaultVolume = 100,
    this.volumeMax = 100,
    this.subtitleMode = SubtitleMode.off,
    this.subtitleLanguage = SubtitleLanguage.auto,
    this.subtitleBorder = 3,
    this.subtitleBackground = false,
    this.subtitleBold = false,
    this.sponsorBlock = false,
    this.returnDislike = false,
    this.deArrowTitles = false,
    this.deArrowThumbnails = false,
    this.sponsorCategories = defaultSponsorCategories,
    this.sponsorNotice = true,
    this.cachePath,
    this.cacheLimitGb,
    this.mpvConf = '',
    this.decoderResults = const {},
    this.hwdecCodecs = defaultHwdecCodecs,
    this.d3d11vaZeroCopy = false,
    this.libassSubtitles = false,
    this.proxyMode = ProxyMode.system,
    this.proxyAddress = '',
    this.playbackSource = PlaybackSource.youtube,
    this.pipedServer = '',
    this.invidiousServer = '',
    this.directRendering = 'auto',
    this.autosync = 0,
    this.audioFilter = '',
    this.picture = const {},
    this.audioDelayMs = 0,
  });

  /// Whether a finished video is followed by another one.
  bool get autoplayNext => playOrder != PlayOrder.pause && playOrder != PlayOrder.singleCycle;

  PlayerSettings copyWith({
    String? hwdec,
    String? scale,
    bool? deband,
    bool? interpolation,
    double? subtitleScale,
    int? subtitlePosition,
    String? cacheMode,
    int? cacheSeconds,
    int? cacheMemoryMb,
    PlaybackStrategy? strategy,
    Set<VideoCodec>? disabledCodecs,
    AudioQuality? audioQuality,
    String? audioDevice,
    VideoSync? videoSync,
    int? maxHeight,
    PlayOrder? playOrder,
    double? defaultSpeed,
    List<double>? speeds,
    int? defaultVolume,
    int? volumeMax,
    SubtitleMode? subtitleMode,
    SubtitleLanguage? subtitleLanguage,
    double? subtitleBorder,
    bool? subtitleBackground,
    bool? subtitleBold,
    bool? sponsorBlock,
    bool? returnDislike,
    bool? deArrowTitles,
    bool? deArrowThumbnails,
    Set<String>? sponsorCategories,
    bool? sponsorNotice,
    String? cachePath,
    bool clearCachePath = false,
    int? cacheLimitGb,
    bool clearCacheLimit = false,
    String? mpvConf,
    Map<String, DecoderStatus>? decoderResults,
    String? hwdecCodecs,
    bool? d3d11vaZeroCopy,
    bool? libassSubtitles,
    ProxyMode? proxyMode,
    String? proxyAddress,
    PlaybackSource? playbackSource,
    String? pipedServer,
    String? invidiousServer,
    String? directRendering,
    int? autosync,
    String? audioFilter,
    Map<String, int>? picture,
    int? audioDelayMs,
  }) => PlayerSettings(
        hwdec: hwdec ?? this.hwdec,
        scale: scale ?? this.scale,
        deband: deband ?? this.deband,
        interpolation: interpolation ?? this.interpolation,
        subtitleScale: subtitleScale ?? this.subtitleScale,
        subtitlePosition: subtitlePosition ?? this.subtitlePosition,
        cacheMode: cacheMode ?? this.cacheMode,
        cacheSeconds: cacheSeconds ?? this.cacheSeconds,
        cacheMemoryMb: cacheMemoryMb ?? this.cacheMemoryMb,
        strategy: strategy ?? this.strategy,
        disabledCodecs: disabledCodecs ?? this.disabledCodecs,
        audioQuality: audioQuality ?? this.audioQuality,
        audioDevice: audioDevice ?? this.audioDevice,
        videoSync: videoSync ?? this.videoSync,
        maxHeight: maxHeight ?? this.maxHeight,
        playOrder: playOrder ?? this.playOrder,
        defaultSpeed: defaultSpeed ?? this.defaultSpeed,
        speeds: speeds ?? this.speeds,
        defaultVolume: defaultVolume ?? this.defaultVolume,
        volumeMax: volumeMax ?? this.volumeMax,
        subtitleMode: subtitleMode ?? this.subtitleMode,
        subtitleLanguage: subtitleLanguage ?? this.subtitleLanguage,
        subtitleBorder: subtitleBorder ?? this.subtitleBorder,
        subtitleBackground: subtitleBackground ?? this.subtitleBackground,
        subtitleBold: subtitleBold ?? this.subtitleBold,
        sponsorBlock: sponsorBlock ?? this.sponsorBlock,
        returnDislike: returnDislike ?? this.returnDislike,
        deArrowTitles: deArrowTitles ?? this.deArrowTitles,
        deArrowThumbnails: deArrowThumbnails ?? this.deArrowThumbnails,
        sponsorCategories: sponsorCategories ?? this.sponsorCategories,
        sponsorNotice: sponsorNotice ?? this.sponsorNotice,
        cachePath: clearCachePath ? null : cachePath ?? this.cachePath,
        cacheLimitGb: clearCacheLimit ? null : cacheLimitGb ?? this.cacheLimitGb,
        mpvConf: mpvConf ?? this.mpvConf,
        decoderResults: decoderResults ?? this.decoderResults,
        hwdecCodecs: hwdecCodecs ?? this.hwdecCodecs,
        d3d11vaZeroCopy: d3d11vaZeroCopy ?? this.d3d11vaZeroCopy,
        libassSubtitles: libassSubtitles ?? this.libassSubtitles,
        proxyMode: proxyMode ?? this.proxyMode,
        proxyAddress: proxyAddress ?? this.proxyAddress,
        playbackSource: playbackSource ?? this.playbackSource,
        pipedServer: pipedServer ?? this.pipedServer,
        invidiousServer: invidiousServer ?? this.invidiousServer,
        directRendering: directRendering ?? this.directRendering,
        autosync: autosync ?? this.autosync,
        audioFilter: audioFilter ?? this.audioFilter,
        picture: picture ?? this.picture,
        audioDelayMs: audioDelayMs ?? this.audioDelayMs,
      );

  Map<String, dynamic> toJson() => {
        'hwdec': hwdec,
        'scale': scale,
        'deband': deband,
        'interpolation': interpolation,
        'subtitleScale': subtitleScale,
        'subtitlePosition': subtitlePosition,
        'cacheMode': cacheMode,
        'cacheSeconds': cacheSeconds,
        'cacheMemoryMb': cacheMemoryMb,
        'bufferDefaults': 2,
        'strategy': strategy.name,
        'disabledCodecs': [for (final c in VideoCodec.values) if (disabledCodecs.contains(c)) c.name],
        'audioQuality': audioQuality.name,
        'audioDevice': audioDevice,
        'videoSync': videoSync.name,
        'maxHeight': maxHeight,
        'playOrder': playOrder.name,
        'defaultSpeed': defaultSpeed,
        'speeds': speeds,
        'defaultVolume': defaultVolume,
        'volumeMax': volumeMax,
        'subtitleMode': subtitleMode.name,
        'subtitleLanguageV2': subtitleLanguage.name,
        'subtitleBorder': subtitleBorder,
        'subtitleBackground': subtitleBackground,
        'subtitleBold': subtitleBold,
        'sponsorBlock': sponsorBlock,
        'returnDislike': returnDislike,
        'deArrowTitles': deArrowTitles,
        'deArrowThumbnails': deArrowThumbnails,
        'sponsorCategories': sponsorCategories.toList(),
        'sponsorNotice': sponsorNotice,
        if (cachePath != null) 'cachePath': cachePath,
        if (cacheLimitGb != null) 'cacheLimitGb': cacheLimitGb,
        'mpvConf': mpvConf,
        'hwdecCodecs': hwdecCodecs,
        'd3d11vaZeroCopy': d3d11vaZeroCopy,
        'libassSubtitles': libassSubtitles,
        'proxyMode': proxyMode.name,
        'proxyAddress': proxyAddress,
        'playbackSourceV2': playbackSource.name,
        'pipedServer': pipedServer,
        'invidiousServer': invidiousServer,
        'directRendering': directRendering,
        'autosync': autosync,
        'audioFilter': audioFilter,
        'picture': picture,
        'audioDelayMs': audioDelayMs,
        'decoderResults': decoderResults.map((codec, status) => MapEntry(codec, status.toJson())),
      };

  factory PlayerSettings.fromJson(Object? raw) {
    if (raw is! Map) return const PlayerSettings();
    String choice(String key, Set<String> allowed, String fallback) {
      final value = raw[key]?.toString();
      return allowed.contains(value) ? value! : fallback;
    }
    int number(String key, int fallback, int min, int max) {
      final value = raw[key];
      final parsed = value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
      if (parsed == null || parsed < min) return fallback;
      return parsed.clamp(min, max).toInt();
    }
    double decimal(String key, double fallback, double min, double max) {
      final value = raw[key];
      final parsed = value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
      return parsed == null ? fallback : parsed.clamp(min, max).toDouble();
    }
    final results = <String, DecoderStatus>{};
    // Earlier builds kept custom options as a map.
    var conf = raw['mpvConf'] is String ? raw['mpvConf'] as String : '';
    if (conf.isEmpty && raw['customOptions'] is Map) {
      conf = [for (final entry in (raw['customOptions'] as Map).entries) '${entry.key}=${entry.value}'].join('\n');
    }
    if (conf.length > 20000) conf = '';
    final picture = <String, int>{};
    if (raw['picture'] is Map) {
      for (final (key, _) in pictureProperties) {
        final value = (raw['picture'] as Map)[key];
        if (value is num && value != 0) picture[key] = value.toInt().clamp(-100, 100);
      }
    }
    final codecs = (raw['hwdecCodecs']?.toString() ?? defaultHwdecCodecs).split(',').map((c) => c.trim()).where(hwdecCodecChoices.contains).toList();
    final filter = raw['audioFilter']?.toString() ?? '';
    if (raw['decoderResults'] is Map) {
      for (final entry in (raw['decoderResults'] as Map).entries) {
        final codec = entry.key.toString().toLowerCase();
        final status = DecoderStatus.fromJson(entry.value);
        if (DecoderStatus.codecs.contains(codec) && status != null) results[codec] = status;
      }
    }
    final speeds = raw['speeds'] is List
        ? ((raw['speeds'] as List).whereType<num>().map((s) => s.toDouble()).where((s) => s >= 0.1 && s <= 8).toSet().toList()..sort())
        : defaultSpeeds;
    final categories = raw['sponsorCategories'] is List
        ? (raw['sponsorCategories'] as List).map((c) => c.toString()).where(sponsorCategoryNames.containsKey).toSet()
        : defaultSponsorCategories;
    // Builds before the format policy saved a preferred `codec`: "any" and a
    // switched-off codec selection meant best quality, the rest automatic.
    final strategy = raw.containsKey('strategy')
        ? _enumByName(PlaybackStrategy.values, raw['strategy'], PlaybackStrategy.auto)
        : raw['codec'] == 'any' || raw['autoSelectCodec'] == false ? PlaybackStrategy.quality : PlaybackStrategy.auto;
    final disabled = raw['disabledCodecs'] is List
        ? {for (final name in raw['disabledCodecs'] as List) VideoCodec.byName(name)}.whereType<VideoCodec>().toSet()
        : <VideoCodec>{};
    // Builds before the play order menu had an autoplay switch.
    final playOrder = raw.containsKey('playOrder')
        ? _enumByName(PlayOrder.values, raw['playOrder'], PlayOrder.autoPlayRelated)
        : raw['autoplayNext'] == false ? PlayOrder.pause : PlayOrder.autoPlayRelated;
    final path = raw['cachePath']?.toString();
    final device = raw['audioDevice']?.toString() ?? 'auto';
    final oldBuffer = raw['bufferDefaults'] != 2;
    return PlayerSettings(
      hwdec: validHwdec(raw['hwdec']?.toString()) ?? 'auto-safe',
      scale: choice('scale', {'spline36', 'bilinear', 'lanczos', 'ewa_lanczossharp'}, 'spline36'),
      deband: raw['deband'] == true,
      interpolation: raw['interpolation'] == true,
      subtitleScale: decimal('subtitleScale', 1.0, 0.5, 3.0),
      subtitlePosition: number('subtitlePosition', 100, 0, 100),
      cacheMode: choice('cacheMode', {'auto', 'yes', 'no'}, 'auto'),
      // Builds before bufferDefaults 2 saved 30 s / 64 MB even when untouched;
      // those move to the larger defaults that ride out network hiccups.
      cacheSeconds: oldBuffer && raw['cacheSeconds'] == 30 ? 60 : number('cacheSeconds', 60, 1, 600),
      cacheMemoryMb: oldBuffer && raw['cacheMemoryMb'] == 64 ? 150 : number('cacheMemoryMb', 150, 16, 1024),
      strategy: strategy,
      disabledCodecs: disabled,
      audioQuality: _enumByName(AudioQuality.values, raw['audioQuality'], AudioQuality.best),
      audioDevice: device.isEmpty || device.length > 200 || device.contains(RegExp(r'[\r\n]')) ? 'auto' : device,
      videoSync: _enumByName(VideoSync.values, raw['videoSync'], VideoSync.audio),
      maxHeight: raw['maxHeight'] is int && (raw['maxHeight'] as int) >= 0 && (raw['maxHeight'] as int) <= 4320 ? raw['maxHeight'] as int : 0,
      playOrder: playOrder,
      defaultSpeed: decimal('defaultSpeed', 1.0, 0.1, 8),
      speeds: speeds.isEmpty ? defaultSpeeds : speeds,
      defaultVolume: number('defaultVolume', 100, 0, 100),
      volumeMax: number('volumeMax', 100, 100, 200),
      subtitleMode: _enumByName(SubtitleMode.values, raw['subtitleMode'], SubtitleMode.off),
      // Saved under a new key since 跟随界面语言 came; 简体中文优先, the
      // default before it, saved under the old one now follows too.
      subtitleLanguage: raw.containsKey('subtitleLanguageV2') || raw['subtitleLanguage'] != 'zh'
          ? _enumByName(SubtitleLanguage.values, raw['subtitleLanguageV2'] ?? raw['subtitleLanguage'], SubtitleLanguage.auto)
          : SubtitleLanguage.auto,
      subtitleBorder: decimal('subtitleBorder', 3, 0, 8),
      subtitleBackground: raw['subtitleBackground'] == true,
      subtitleBold: raw['subtitleBold'] == true,
      sponsorBlock: raw['sponsorBlock'] == true,
      returnDislike: raw['returnDislike'] == true,
      deArrowTitles: raw['deArrowTitles'] == true,
      deArrowThumbnails: raw['deArrowThumbnails'] == true,
      sponsorCategories: categories,
      sponsorNotice: raw['sponsorNotice'] != false,
      cachePath: path != null && path.trim().isNotEmpty ? path : null,
      cacheLimitGb: raw['cacheLimitGb'] == null ? null : number('cacheLimitGb', 1, 1, 100),
      mpvConf: conf,
      decoderResults: results,
      hwdecCodecs: codecs.isEmpty ? defaultHwdecCodecs : codecs.join(','),
      d3d11vaZeroCopy: raw['d3d11vaZeroCopy'] == true,
      libassSubtitles: raw['libassSubtitles'] == true,
      proxyMode: _enumByName(ProxyMode.values, raw['proxyMode'], ProxyMode.system),
      proxyAddress: NetworkProxy.normalize(raw['proxyAddress']?.toString() ?? '') ?? '',
      // V2: the default became direct YouTube (2026-10-21); the old key held
      // the old default for everyone who never chose.
      playbackSource: _enumByName(PlaybackSource.values, raw['playbackSourceV2'], PlaybackSource.youtube),
      pipedServer: normalizePipedServer(raw['pipedServer']?.toString() ?? '') ?? '',
      invidiousServer: normalizePipedServer(raw['invidiousServer']?.toString() ?? '') ?? '',
      directRendering: choice('directRendering', {'auto', 'yes', 'no'}, 'auto'),
      autosync: number('autosync', 0, 0, 100),
      audioFilter: filter.length > 300 || filter.contains(RegExp(r'[\r\n]')) ? '' : filter,
      picture: picture,
      audioDelayMs: number('audioDelayMs', 0, -5000, 5000),
    );
  }

  /// [value] if it is a comma list of known decoders, else null.
  static String? validHwdec(String? value) {
    if (value == null) return null;
    final known = {for (final (name, _) in hwdecChoices) name};
    final parts = value.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty || parts.any((p) => !known.contains(p)) || parts.toSet().length != parts.length) return null;
    return parts.join(',');
  }

  /// Why a custom option cannot be applied, or null when it can.
  static String? customOptionProblem(String key, String value) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_\-/]*$').hasMatch(key)) return tr('参数名无效');
    if (_blockedOptions.contains(key) || _blockedPrefixes.any(key.startsWith)) return tr('Lumtub 不允许设置此参数');
    if (value.length > 500 || value.contains(RegExp(r'[\r\n;]'))) return tr('参数值无效');
    return null;
  }

  static bool isSafeCustomOption(String key, String value) => customOptionProblem(key, value) == null;
}

/// SponsorBlock's categories with the names PiliNara shows for them.
final sponsorCategoryNames = {
  'sponsor': (tr('赞助广告'), tr('付费推广、付费推荐和直接广告')),
  'selfpromo': (tr('自我推广'), tr('无偿推广：周边、捐赠或合作者的信息')),
  'interaction': (tr('求赞求订阅'), tr('提醒点赞、订阅或关注')),
  'intro': (tr('片头'), tr('没有实际内容的开场动画、暂停画面')),
  'outro': (tr('片尾'), tr('结尾致谢、片尾动画和下期预告')),
  'preview': (tr('回顾与预告'), tr('本集精彩片段或上期回顾')),
  'music_offtopic': (tr('音乐：非音乐部分'), tr('音乐视频中的非音乐片段')),
  'filler': (tr('离题闲聊'), tr('与主题无关、只为娱乐的片段')),
};

class PlayerSettingsStore {
  final File file;
  PlayerSettingsStore(AppDirectories directories) : file = File('${directories.config.path}${Platform.pathSeparator}player_settings.json');

  Future<PlayerSettings> load() async {
    try {
      return PlayerSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const PlayerSettings();
    }
  }

  Future<void> save(PlayerSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}
