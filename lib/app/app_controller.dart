import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color, PaintingBinding;
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_directories.dart';
import '../app_log.dart';
import '../app_window.dart';
import '../app_preferences.dart';
import '../play_queue.dart';
import '../playback_failure.dart';
import '../playback_recovery.dart';
import '../library_store.dart';
import '../secure_store.dart';
import '../dearrow.dart';
import '../downloads/download_formats.dart';
import '../downloads/download_manager.dart';
import '../downloads/download_models.dart';
import '../downloads/download_selection.dart';
import '../return_dislike.dart';
import '../sponsor_block.dart';
import '../appearance_settings.dart';
import '../cache_manager.dart';
import '../decoder_status.dart';
import '../live_chat.dart';
import '../models.dart';
import '../network_proxy.dart';
import '../socks_bridge.dart';
import '../cast/cast_controller.dart';
import '../cast/cast_device.dart';
import '../cast/cast_stream.dart';
import '../invidious_streams.dart';
import '../piped_streams.dart';
import '../search_options.dart';
import '../search_suggestions.dart';
import '../youtube_comments.dart';
import '../youtube_related.dart';
import '../recommendations.dart';
import '../chunked_relay.dart';
import '../player_option_applicator.dart';
import '../player_settings.dart';
import '../ffmpeg_component.dart';
import '../thumbnail_trim.dart';
import '../tool_manager.dart';
import '../format_policy.dart';
import '../memory_trim.dart';
import '../video_codec.dart';
import '../community_posts.dart';
import '../blocked_groups.dart';
import '../explore_filters.dart';
import '../explore_topics.dart';
import '../faith_topics.dart';
import '../storyboard.dart';
import '../stream_resolver.dart';
import '../subtitle_translation.dart';
import '../translation.dart';
import 'posts_loader.dart';
import '../video_repository.dart';
import '../windows_env.dart';
import '../windows_video_info.dart';
import 'account_controller.dart';
import 'home_feed.dart';
import 'back_stack.dart';
import 'library_controller.dart';
import 'video_list_loader.dart';
import '../l10n/l10n.dart';

enum PageMode { home, explore, subscriptions, history, playlists, downloads, settings, channel, playlist, youtubePlaylist }

/// Application state and actions, kept separate from the widgets that show them.
class AppController extends ChangeNotifier {
  HistoryStore? _history;
  AppDirectories? directories;
  CacheManager? _cacheManager;
  PlayerSettingsStore? _settingsStore;
  ToolManager? _tools;
  VideoRepository? _repository;
  ToolPaths? paths;

  /// 下载: videos saved on this computer; set once ready.
  DownloadManager? downloads;

  Player? player;
  VideoController? videoController;

  int cacheBytes = 0;
  Map<String, DecoderStatus> decodeStates = const {};
  String currentCodec = tr('尚未播放视频');
  String currentHwdec = tr('尚未验证');
  WindowsVideoInfo windowsVideoInfo = const WindowsVideoInfo();
  PlayerSettings settings = const PlayerSettings();
  VideoItem? playing;
  PageMode mode = PageMode.home;
  bool ready = false;
  bool checking = false;
  bool checkingAppUpdate = false;
  String? availableAppVersion;
  String? availableAppUrl;
  String? appUpdateError;
  String status = tr('正在准备 Windows 原生播放器…');
  /// Startup failure; the setup screen shows it with a retry button.
  String? error;
  String? playbackError;

  /// Favorites, playlists, followed channels and progress; set once ready.
  LibraryController? library;

  /// The optional Google sign-in for importing subscriptions and playlists.
  AccountController? account;

  /// The open channel page and its uploads.
  ChannelRef? channel;
  VideoListLoader? channelVideos;
  /// What the channel page is searching for; null lists the uploads.
  String? channelQuery;
  /// The id of the open playlist page: a [LocalPlaylist] id, or
  /// [favoritesPlaylistId].
  String? openPlaylistId;
  static const favoritesPlaylistId = 'favorites';
  /// 稍后观看 opens on the same page as a playlist.
  static const watchLaterPlaylistId = 'watch_later';
  /// Where 返回 goes: earlier pages and videos.
  final _back = BackStack();
  /// Set while going back, so the step back is not itself remembered.
  bool _restoring = false;

  /// The open YouTube playlist and its videos.
  PlaylistResult? youtubePlaylist;
  VideoListLoader? youtubePlaylistVideos;

  /// The channel page's tab, and its posts when that tab is open.
  ChannelTab channelTab = ChannelTab.videos;
  PostsLoader? channelPosts;
  late final _posts = CommunityPosts(_http);

  /// Comments under videos and posts.
  late final comments = YoutubeComments(_http);

  /// Whether the statistics overlay is shown over the video.
  bool showStats = false;

  void toggleStats() => _update(() => showStats = !showStats);

  /// 置顶: the window stays above the others.
  bool pinned = false;
  /// 画中画: a small borderless window above the others, showing only the
  /// video in its own ratio (ui/pip_view.dart).
  bool pip = false;
  /// 应用内小窗: [playing] keeps playing in a floating card over the other
  /// pages instead of on the watch page (ui/mini_player.dart).
  bool mini = false;
  /// 听视频: mpv decodes no picture, which saves power and bandwidth.
  bool audioOnly = false;

  void togglePinned() {
    if (!AppWindow.setTopmost(!pinned || pip)) return _notice(tr('无法设置窗口置顶'));
    _update(() => pinned = !pinned);
  }

  /// Whether the watch page shows [playing].
  bool get onWatchPage => playing != null && !mini;

  /// Whether leaving the watch page now keeps the video in the mini player.
  bool get _keepsPlaying =>
      playing != null && (mini || (preferences.miniPlayer && player != null && playbackError == null));

  /// Shows [playing] on the watch page again, where it was.
  void expandMini() {
    if (mini) _update(() => mini = false);
  }

  /// Puts the video on the watch page into the mini player (the 应用内小窗
  /// button), over the page it was opened from.
  void enterMini() {
    if (playing == null || mini || player == null) return;
    setPip(false);
    _saveProgress(now: true);
    _update(() => mini = true);
  }

  void setPip(bool on) {
    if (on == pip) return;
    final ok = on ? AppWindow.enterPip(aspect: videoAspect) : AppWindow.exitPip(keepOnTop: pinned);
    if (on && !ok) return _notice(tr('无法进入画中画'));
    _update(() => pip = on);
  }

  /// The playing video's width over height, 16:9 until it is known.
  double get videoAspect {
    final state = player?.state;
    final width = state?.width ?? 0, height = state?.height ?? 0;
    return width > 0 && height > 0 ? width / height : 16 / 9;
  }

  /// The next video may have another ratio: the picture-in-picture window
  /// follows it.
  void updatePipAspect() {
    if (pip) AppWindow.setPipAspect(videoAspect);
  }

  Future<void> toggleAudioOnly() async {
    final platform = player?.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('vid', audioOnly ? 'auto' : 'no');
    _update(() => audioOnly = !audioOnly);
    _notice(audioOnly ? tr('只听声音，不解码画面') : tr('已恢复画面'));
  }

  Future<void> toggleSponsorBlock() async {
    await saveSettings(settings.copyWith(sponsorBlock: !settings.sponsorBlock));
    _notice(settings.sponsorBlock ? tr('已开启 SponsorBlock 跳过片段') : tr('已关闭 SponsorBlock'));
  }

  /// Videos like the one playing, found by searching for its title.
  VideoListLoader? related;

  /// The list the current video was opened from, shown as the play queue.
  List<VideoItem> queue = const [];
  /// Videos lined up by hand; they play before [upNext].
  final playQueue = PlayQueue();
  VideoDetails? details;
  bool loadingDetails = false;
  List<LiveChatMessage> replayChat = const [];
  bool loadingReplayChat = false;
  String? replayChatError;
  StreamSubscription<LiveChatMessage>? _currentChat;
  Timer? _currentChatFlushTimer;
  final _currentChatPending = <LiveChatMessage>[];
  final _currentChatIds = <String>{};
  /// Heights the playing video offers, highest first; empty until known.
  List<int> availableHeights = const [];
  /// Heights for the quality menu: automatic, then only what the playing
  /// video offers (just automatic until that is known).
  List<int> get qualityChoices => [0, ...({...availableHeights}.toList()..sort((a, b) => b.compareTo(a)))];

  /// The video opened from addresses resolved ahead of libmpv, if any.
  String? _openedResolved;
  /// The video last opened from a Piped or Invidious server, so a failure
  /// falls back to YouTube (or the other one) once.
  String? _openedVia;
  /// The video playing from its downloaded file, if any.
  String? _openedLocal;
  /// The servers tried for the video being opened, and the 429 YouTube
  /// answered it with, which lets both be tried whatever 播放来源 says.
  final _relaysTried = <RelayKind>{};
  PlaybackFailure? _rateLimited;
  late final _piped = PipedStreams(_http);
  late final _invidious = InvidiousStreams(_http);

  /// The TV or Chromecast the video is cast to, if any.
  final cast = CastController();

  /// What to cast of [playing]: one progressive mp4 with sound, from the
  /// yt-dlp extraction or else from a Piped or Invidious server.
  Future<CastMedia> castMedia(Duration start) async {
    final item = playing;
    if (item == null || item.isLive || _repository == null) throw CastException(tr('没有可以投屏的视频流（需要带声音的 MP4 地址）'));
    CastSource? source;
    try {
      source = castSourceFromYtDlp((await _repository!.streams.resolve(item.id, _format, formatSort: _formatSort)).info, settings: _playback);
    } catch (e) {
      logInfo('投屏：yt-dlp 解析失败：$e');
    }
    for (final kind in RelayKind.values) {
      if (source != null) break;
      try {
        source = castSourceFromRelay(await (kind == RelayKind.piped ? _piped.fetch(item.id) : _invidious.fetch(item.id)), settings: _playback);
      } catch (e) {
        logInfo('投屏：$kind 解析失败：$e');
      }
    }
    if (source == null) throw CastException(tr('没有可以投屏的视频流（需要带声音的 MP4 地址）'));
    final title = details?.title.isNotEmpty == true ? details!.title : item.title;
    return CastMedia(url: source.url, title: title, mime: source.mime, start: start);
  }

  /// The Piped servers, for 设置 › Piped 服务器.
  PipedStreams get piped => _piped;
  /// The Invidious instances, for 设置 › Invidious 实例.
  InvidiousStreams get invidious => _invidious;
  /// Serves YouTube streams to libmpv in pieces YouTube does not throttle.
  ChunkedRelay? _relay;

  AppearanceSettings appearance;
  final AppearanceSettingsStore? _appearanceStore;
  /// The Windows accent colour, once read, for [AppearanceSettings.systemAccent].
  Color? windowsAccent;

  AppPreferences preferences = const AppPreferences();
  AppPreferencesStore? _preferencesStore;

  AppController({this.appearance = const AppearanceSettings(), AppearanceSettingsStore? appearanceStore}) : _appearanceStore = appearanceStore {
    deArrow.configure(_http, titles: () => settings.deArrowTitles, thumbnails: () => settings.deArrowThumbnails);
    _applyAppearanceGlobals(appearance);
  }

  /// The seed colour the theme is built from.
  Color get accentColor => appearance.systemAccent && windowsAccent != null ? windowsAccent! : appearance.accent;

  static void _applyAppearanceGlobals(AppearanceSettings appearance) {
    VideoItem.thumbnailFile = appearance.thumbnailQuality.file;
    videoCardMinWidth = appearance.cardWidth;
  }

  int _playSerial = 0;
  String? _query;
  final _playerSubscriptions = <StreamSubscription<Object>>[];
  double _volumeBeforeMute = 100;
  bool _libmpvConfirmed = false;
  /// The video whose position is being recorded; null while switching, so
  /// positions of the previous file are not credited to the next.
  VideoItem? _tracking;
  DateTime _lastProgressSave = DateTime(0);
  List<SkipSegment> _segments = const [];
  final _skipped = <SkipSegment>{};
  final _http = http.Client();
  /// Sprite sheets of the progress bar's preview frames.
  late final storyboardSheets = StoryboardSheets(_http);
  /// Behind 翻译 buttons; called only when one is tapped.
  late Translator translator = GoogleTranslator(_http);
  /// The subtitle shown above the main one (双语字幕), if any.
  SubtitleOption? secondarySubtitle;
  bool _decoderPending = false;
  int _mpvLogLines = 0;
  /// yt-dlp and libmpv error lines for the video being opened, which name
  /// the cause libmpv's own error message usually leaves out.
  final _recentErrors = <String>[];

  /// No prefetching until then, after YouTube answered 429.
  DateTime _rateLimitedUntil = DateTime(0);
  bool _updateCheckedForChallenge = false;
  int _lastDrops = 0;
  DateTime _lastDropLog = DateTime(0);
  Timer? _dropTimer;
  Timer? _thumbnailTrimTimer;
  final _recovery = PlaybackRecovery();
  /// The last position actually played, which survives a failed stream.
  Duration _lastPosition = Duration.zero;
  Timer? _stallTimer;
  Timer? _recoveryTimer;
  bool _recovering = false;
  bool _shutDown = false;
  late final _sponsorBlock = SponsorBlock(_http);
  late final _returnDislike = ReturnDislike(_http);
  /// Return YouTube Dislike's estimate for the video playing, when on.
  DislikeCount? dislikes;
  bool _disposed = false;
  final _notices = StreamController<String>.broadcast();

  /// One-off messages the UI shows as snack bars.
  Stream<String> get notices => _notices.stream;

  List<VideoItem> get history => _history?.items ?? const [];
  @visibleForTesting
  set historyStore(HistoryStore? store) => _history = store;

  /// The text of the current or last search, if any.
  String? get query => _query;

  /// The current search's results; null before the first search.
  VideoListLoader? searchResults;
  SearchFilter searchFilter = SearchFilter.all;

  List<VideoItem> get results => searchResults?.items ?? const [];
  /// The search's channels, without blocked groups unless one is named
  /// exactly.
  List<ChannelResult> get channelResults => [
        for (final c in searchResults?.channels ?? const <ChannelResult>[])
          if (!preferences.isBlocked(c.ref.id) && !preferences.isBlockedName(c.ref.name) && (!preferences.blocksChannel(c.ref.name, id: c.ref.id, handle: c.handle) || isExactName(c.ref.name, _query) || isExactName(c.handle ?? '', _query))) c,
      ];
  List<PlaylistResult> get playlistResults => [
        for (final p in searchResults?.playlists ?? const <PlaylistResult>[])
          if (!preferences.isBlockedName(p.channel) && (!preferences.blocksChannel(p.channel) || isExactName(p.channel, _query))) p,
      ];
  bool get searching => searchResults?.loading ?? false;
  String? get searchError => searchResults?.error;

  @visibleForTesting
  set debugQuery(String? value) => _query = value;

  Directory? get cacheRoot => _cacheManager?.rootFor(settings);

  Directory? get thumbnailDirectory {
    final root = cacheRoot;
    return root == null ? null : Directory('${root.path}${Platform.pathSeparator}thumbnails');
  }

  void _update(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  void _notice(String message) {
    if (!_disposed) _notices.add(message);
  }

  Future<void> initialize() async {
    try {
      final directories = await AppDirectories.create();
      // yt-dlp, including the one libmpv starts, writes some temporary
      // files (format tests) to the working folder, which is the install
      // folder and read-only under Program Files.
      try {
        Directory.current = directories.cache;
      } catch (_) {}
      await AppLog.open(directories.logs);
      logInfo('Lumtub $appVersion 启动 · ${Platform.operatingSystemVersion}');
      final history = HistoryStore(directories);
      await history.initialize();
      searchHistory = SearchHistory(File('${directories.data.path}${Platform.pathSeparator}search_history.json'));
      final notInterested = NotInterested(File('${directories.data.path}${Platform.pathSeparator}not_interested.json'));
      await notInterested.load();
      homeFeed = HomeFeed(notInterested, cacheFile: File('${directories.cache.path}${Platform.pathSeparator}home_feed.json'))..addListener(notifyListeners);
      final libraryStore = LibraryStore(File('${directories.data.path}${Platform.pathSeparator}library.json'));
      await libraryStore.load();
      final settingsStore = PlayerSettingsStore(directories);
      final settings = await settingsStore.load();
      this.settings = settings;
      // Before the component downloads, which go through the proxy too.
      await _refreshProxy();
      final preferencesStore = AppPreferencesStore(directories);
      final preferences = await preferencesStore.load();
      final cacheManager = CacheManager(directories);
      await cacheManager.prepare(settings);
      final manager = ToolManager(directories, (message) {
        logInfo(message);
        _update(() => status = message);
      });
      _tools = manager;
      await manager.initialize();
      final paths = await manager.ensureReady();
      addToWindowsPath(paths.executableDirectories);
      MediaKit.ensureInitialized(libmpv: paths.mpv);
      final player = Player(configuration: PlayerConfiguration(
        bufferSize: settings.cacheMemoryMb * 1024 * 1024,
        // With libass, libmpv draws the subtitles and the Flutter subtitle
        // view is turned off on the watch page. It is off by default: the
        // build that turned it on for everyone also brought dropped frames.
        libass: settings.libassSubtitles,
        logLevel: MPVLogLevel.warn,
      ));
      final controller = VideoController(player, configuration: VideoControllerConfiguration(hwdec: settings.hwdec));
      final ignoredOptions = await PlayerOptionApplicator.apply(player, settings);
      await _applyProxy(player);
      try {
        _relay = ChunkedRelay();
        await _relay!.start();
      } catch (e) {
        _relay = null;
        logError('无法启动本地分块转发，视频流将直接连接', e);
      }
      _piped.catalogFile = File('${directories.config.path}${Platform.pathSeparator}piped_servers.json');
      // Measures the Piped servers while the app starts, not on the first click.
      _invidious.catalogFile = File('${directories.config.path}${Platform.pathSeparator}invidious_servers.json');
      switch (settings.playbackSource) {
        case PlaybackSource.pipedAuto:
          unawaited(_piped.servers());
        case PlaybackSource.invidiousAuto:
          unawaited(_invidious.servers());
        default:
      }
      await player.setVolume(settings.defaultVolume.toDouble());
      // yt-dlp and Deno are on PATH before libmpv starts, so ytdl_hook can find them.
      if (_disposed) {
        await player.dispose();
        return;
      }
      _update(() {
        this.paths = paths;
        this.directories = directories;
        _cacheManager = cacheManager;
        cacheBytes = 0;
        _settingsStore = settingsStore;
        this.settings = settings;
        _preferencesStore = preferencesStore;
        this.preferences = preferences;
        mode = PageMode.values.where((m) => m.name == preferences.startPage).firstOrNull ?? PageMode.home;
        decodeStates = {...settings.decoderResults};
        _history = history;
        _repository = _repositoryFor(paths, cacheManager, settings);
        downloads = _downloadsFor(paths, directories)..addListener(notifyListeners);
        final library = this.library = LibraryController(libraryStore, client: _http)
          ..repository = _repository
          ..addListener(notifyListeners);
        account = AccountController(
          clientFile: File('${directories.data.path}${Platform.pathSeparator}google-client.json'),
          credentials: SecureJsonFile(File('${directories.data.path}${Platform.pathSeparator}google-account.bin'), DpapiProtector()),
          client: _http,
          library: library,
          notice: _notice,
        )..addListener(notifyListeners);
        this.player = player;
        videoController = controller;
        _listenTo(player);
        _dropTimer = Timer.periodic(const Duration(seconds: 10), (_) => _checkDrops());
        _thumbnailTrimTimer?.cancel();
        _thumbnailTrimTimer = Timer.periodic(const Duration(hours: 1), (_) => _trimThumbnails());
        ready = true;
        status = ignoredOptions.isEmpty ? tr('就绪 · 解码方式将在播放时验证') : tr('就绪 · 已忽略不支持的设置：{0}', [ignoredOptions.join(', ')]);
        error = null;
      });
      if (mode == PageMode.explore) _loadExplore();
      if (mode == PageMode.home) unawaited(refreshHomeFeed());
      // Do not block the UI while checking newer releases.
      if (preferences.autoCheckUpdates) {
        unawaited(manager.checkUpdates());
        unawaited(checkAppUpdate());
      }
      unawaited(_refreshCacheSize());
      unawaited(_trimThumbnails());
      unawaited(downloads?.load());
      unawaited(account?.load());
      logInfo('组件就绪 · libmpv ${manager.libmpv.current?.label ?? '内置'} · yt-dlp ${manager.ytDlpVersion ?? '?'} · ${paths.mpv}');
    } catch (e) {
      _update(() {
        error = e.toString();
        status = tr('初始化失败');
        logError('初始化失败', e);
      });
    }
  }

  /// Checks the application's own release separately from libmpv and yt-dlp.
  /// Replacing an installed executable is left to the installer after the
  /// user opens the matching GitHub Release.
  Future<void> checkAppUpdate() async {
    if (checkingAppUpdate) return;
    _update(() {
      checkingAppUpdate = true;
      appUpdateError = null;
    });
    try {
      final response = await _http.get(
        Uri.https('api.github.com', '/repos/0x696c757a696f/lumtub/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Lumtub-Windows/$appVersion'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw HttpException('GitHub returned HTTP ${response.statusCode}');
      final json = jsonDecode(response.body);
      if (json is! Map) throw const FormatException('Invalid GitHub release response');
      final tag = json['tag_name']?.toString().replaceFirst(RegExp(r'^v', caseSensitive: false), '') ?? '';
      final url = json['html_url']?.toString() ?? '';
      _update(() {
        availableAppVersion = tag.isNotEmpty && tag != appVersion ? tag : null;
        availableAppUrl = availableAppVersion == null || url.isEmpty ? null : url;
        checkingAppUpdate = false;
      });
      logInfo(availableAppVersion == null ? 'Lumtub is up to date ($appVersion)' : 'Lumtub update available: $availableAppVersion');
    } catch (error) {
      _update(() {
        checkingAppUpdate = false;
        appUpdateError = '$error';
      });
      logInfo('Could not check Lumtub updates: $error');
    }
  }

  /// Keeps the thumbnail cache under its cap, at startup and then hourly;
  /// skipped while a video plays.
  Future<void> _refreshCacheSize() async {
    final manager = _cacheManager;
    if (manager == null) return;
    try {
      final bytes = await manager.size(settings);
      if (!_disposed) _update(() => cacheBytes = bytes);
    } on FileSystemException catch (error) {
      logInfo('Could not measure cache size: $error');
    }
  }

  Future<void> _trimThumbnails() async {
    final directory = thumbnailDirectory;
    if (_disposed || directory == null || playing != null) return;
    try {
      final freed = await trimThumbnails(directory, thumbnailCapBytes(settings.cacheLimitGb));
      if (freed > 0) {
        logInfo('缩略图缓存超出上限，已清理 ${formatBytes(freed)}');
        final manager = _cacheManager;
        if (manager != null) {
          final left = await manager.size(settings);
          _update(() => cacheBytes = left);
        }
      }
    } catch (e) {
      logInfo('清理缩略图缓存失败：$e');
    }
  }

  void retryInitialize() {
    _update(() {
      error = null;
      status = tr('重新安装组件…');
    });
    unawaited(initialize());
  }

  VideoRepository _repositoryFor(ToolPaths paths, CacheManager cacheManager, PlayerSettings settings) =>
      VideoRepository(
        paths.ytDlp,
        cacheDirectory: '${cacheManager.rootFor(settings).path}${Platform.pathSeparator}yt-dlp',
        deno: paths.deno,
        toolDirectories: paths.executableDirectories,
        proxy: () => proxy.ytDlpValue(this.settings.proxyMode),
      );

  DownloadManager _downloadsFor(ToolPaths paths, AppDirectories directories) => DownloadManager(
        file: File('${directories.data.path}${Platform.pathSeparator}downloads.json'),
        ytDlpPath: paths.ytDlp,
        defaultDirectory: DownloadManager.defaultDirectoryFor(Platform.environment, '${directories.data.path}${Platform.pathSeparator}downloads'),
        environment: () => _repository!.processEnvironment,
        ffmpegDirectory: () {
          final env = _repository!.processEnvironment;
          final path = env.entries.where((e) => e.key.toUpperCase() == 'PATH').firstOrNull?.value;
          return DownloadManager.findFfmpeg([if (_tools?.ffmpegDirectory != null) _tools!.ffmpegDirectory!, ...paths.executableDirectories, '${directories.components.path}${Platform.pathSeparator}ffmpeg'], path);
        },
        options: () => DownloadOptions(
          proxy: proxy.ytDlpValue(settings.proxyMode),
          deno: paths.deno,
          cacheDirectory: _repository?.cacheDirectory,
          subtitleLanguages: settings.subtitleLanguage.ytDlpLangs,
          autoSubtitles: settings.subtitleMode == SubtitleMode.always,
        ),
        sponsorSegments: (id) => _sponsorBlock.segments(id, settings.sponsorCategories),
      );

  /// Queues [item] for download, and says so.
  void download(VideoItem item, DownloadQuality quality, {DownloadSelection? selection}) {
    final manager = downloads;
    if (manager == null || item.isLive || item.isUpcoming) return _notice(tr('直播无法下载'));
    _notice(manager.add(item, quality, selection: selection) == null ? tr('已在下载列表中') : tr('已加入下载'));
  }

  /// The streams [videoId] can be downloaded as, from the extraction the
  /// player shares (one yt-dlp run per video).
  Future<DownloadFormats> downloadFormats(String videoId) async {
    final repository = _repository;
    if (repository == null) throw StateError(tr('组件尚未就绪'));
    return DownloadFormats.parse((await repository.streams.resolve(videoId, _format, formatSort: _formatSort)).info);
  }

  /// The proxy everything currently goes through.
  NetworkProxy proxy = NetworkProxy.direct;
  DateTime _proxyRead = DateTime(0);

  /// Reads the proxy setting again; for 跟随系统 also the Windows proxy,
  /// which a proxy tool may have turned on or off since.
  Future<void> _refreshProxy({bool ifStale = false}) async {
    final now = DateTime.now();
    if (ifStale && now.difference(_proxyRead) < const Duration(seconds: 30)) return;
    _proxyRead = now;
    final next = await NetworkProxy.resolve(settings.proxyMode, settings.proxyAddress);
    await _routeThroughBridge(next);
    appHttpOverrides.endpoint = proxyEndpoint;
    appHttpOverrides.useEnvironment = settings.proxyMode == ProxyMode.system;
    if (next.url != proxy.url) logInfo(next.url == null ? '网络：直接连接' : '网络：使用代理 ${next.redacted}');
    proxy = next;
    final player = this.player;
    if (player != null) await _applyProxy(player);
  }

  SocksBridge? _bridge;
  String? _bridgeFor;

  /// `host:port` of the HTTP proxy libmpv and dart:io use: the proxy itself,
  /// or the local bridge to a SOCKS one. A SOCKS proxy whose bridge could
  /// not start gets a dead port, so requests fail instead of going direct.
  String? proxyEndpoint;

  /// Starts, replaces or stops the bridge so it matches [next].
  Future<void> _routeThroughBridge(NetworkProxy next) async {
    final old = _bridge;
    if (next.isSocks && next.url == _bridgeFor && old != null) return;
    _bridge = null;
    _bridgeFor = next.url;
    if (next.isSocks) {
      try {
        _bridge = await SocksBridge.start(next.url!);
      } catch (e) {
        logError('无法启动本地 SOCKS 转发，网络请求将失败而不是直连', e);
      }
    }
    proxyEndpoint = next.isSocks ? (_bridge?.hostPort ?? '127.0.0.1:1') : next.isHttp ? next.hostPort : null;
    await old?.close();
  }

  /// libmpv's streams can only use an HTTP proxy.
  Future<void> _applyProxy(Player player) async {
    final platform = player.platform;
    if (platform is NativePlayer) await platform.setProperty('http-proxy', proxyEndpoint == null ? '' : 'http://$proxyEndpoint');
  }

  Future<void> search(String value, {SearchFilter? filter}) async {
    final query = value.trim();
    if (query.isEmpty || !ready) return;
    final asUrl = parseYoutubeId(query);
    if (asUrl != null) {
      await play(VideoItem(id: asUrl, title: tr('YouTube 视频 · {0}', [asUrl]), channel: 'YouTube', url: 'https://www.youtube.com/watch?v=$asUrl'));
      return;
    }
    if (query != _query || mode != PageMode.explore || onWatchPage) _remember();
    final keep = _keepsPlaying;
    if (!keep) _unload();
    final repository = _repository!;
    final chosen = filter ?? searchFilter;
    if (preferences.recordHistory) unawaited(searchHistory?.add(query));
    final sp = searchParams(type: chosen, sort: searchSort, date: searchDate, duration: searchDuration);
    _update(() {
      mode = PageMode.explore;
      if (keep) {
        mini = true;
      } else {
        playing = null;
      }
      _query = query;
      searchFilter = chosen;
      searchResults?.dispose();
      searchResults = VideoListLoader(() => sp == null ? repository.search(query) : repository.search(query, sp: sp))
        ..addListener(notifyListeners)
        ..loadMore();
    });
  }

  /// Fetches the next page of the current search. After a failed page,
  /// scrolling does not retry on its own; [retry] comes from the retry button.
  void loadMoreResults({bool retry = false}) => searchResults?.loadMore(retry: retry);

  /// Leaves search results for the explore topics.
  void clearSearch() {
    _update(() {
      _query = null;
      searchResults?.dispose();
      searchResults = null;
    });
    _loadExplore();
  }

  /// The explore page: its part, zone, sub-category (0 for all of the
  /// zone) and the sub-category's own (0 for all of it), how videos are
  /// picked, and the filters.
  ExploreSection exploreSection = ExploreSection.popular;
  int exploreTopic = 0;
  int exploreSub = 0;
  int exploreLeaf = 0;
  ExploreMode exploreMode = ExploreMode.popular;
  SearchUploadDate explorePeriod = SearchUploadDate.month;
  SearchDuration exploreDuration = SearchDuration.any;
  SearchQuality exploreQuality = SearchQuality.any;
  /// The 类型 and 视角 filters: 宗教与信仰's own lists there, general ones
  /// elsewhere ([exploreFormats], [exploreViews]).
  WordFilter exploreFormat = ContentFormat.any;
  WordFilter exploreView = ContentView.any;

  static List<WordFilter> formatsOf(ExploreSection section) => section.isFaith ? FaithFormat.values : ContentFormat.values;
  static List<WordFilter> viewsOf(ExploreSection section) => section.isFaith ? FaithView.values : ContentView.values;
  List<WordFilter> get exploreFormats => formatsOf(exploreSection);
  List<WordFilter> get exploreViews => viewsOf(exploreSection);
  /// The chosen zone's videos.
  VideoListLoader? explore;

  /// Every zone of [section], built in and the user's, in no set order.
  List<ExploreTopic> allExploreTopics(ExploreSection section) => exploreTopicsOf(section, preferences.exploreCustomTopics);

  /// The zones of [section] the strip shows, in the user's order.
  List<ExploreTopic> exploreTopicsFor(ExploreSection section) => arrangeTopics(
        allExploreTopics(section),
        preferences.exploreOrder[section.name] ?? const [],
        {...?preferences.exploreHidden[section.name]},
      );

  ExploreTopic get exploreTopicNow {
    final topics = exploreTopicsFor(exploreSection);
    return topics[exploreTopic.clamp(0, topics.length - 1)];
  }

  /// The sub-category shown, if one is.
  ExploreSub? get exploreSubNow {
    final subs = exploreTopicNow.subs;
    return exploreSub > 0 && exploreSub <= subs.length ? subs[exploreSub - 1] : null;
  }

  /// The sub-category's own sub-category shown, if one is.
  ExploreSub? get exploreLeafNow {
    final subs = exploreSubNow?.subs ?? const [];
    return exploreLeaf > 0 && exploreLeaf <= subs.length ? subs[exploreLeaf - 1] : null;
  }

  /// The words searched for: the narrowest sub-category's, or the whole
  /// zone's, with 宗教与信仰's filter words.
  String get exploreQuery => [
        (exploreLeafNow ?? exploreSubNow)?.query ?? exploreTopicNow.query,
        exploreFormat.words,
        exploreView.words,
      ].where((w) => w.isNotEmpty).join(' ');

  /// Adds a category of the user's own and shows it.
  Future<void> addExploreTopic(CustomTopic topic) async {
    final kept = preferences.exploreCustomTopics.where((t) => !(t.section == topic.section && t.label == topic.label)).toList();
    final key = topic.topic.key;
    await savePreferences(preferences.copyWith(
      exploreCustomTopics: [...kept, topic],
      exploreHidden: {...preferences.exploreHidden, topic.section.name: [...?preferences.exploreHidden[topic.section.name]]..remove(key)},
    ));
    final index = exploreTopicsFor(topic.section).indexWhere((t) => t.key == key);
    _reloadExplore(section: topic.section, topic: index);
  }

  /// Removes one of the user's categories, keeping the one shown if it stays.
  Future<void> removeExploreTopic(ExploreSection section, String label) async {
    final key = 'custom:$label';
    await _arrangeExplore(section, () => savePreferences(preferences.copyWith(
          exploreCustomTopics: preferences.exploreCustomTopics.where((t) => !(t.section == section && t.label == label)).toList(),
          exploreOrder: {...preferences.exploreOrder, section.name: [...?preferences.exploreOrder[section.name]]..remove(key)},
          exploreHidden: {...preferences.exploreHidden, section.name: [...?preferences.exploreHidden[section.name]]..remove(key)},
        )));
  }

  /// Saves the order and hidden zones of [section] from the manage dialog.
  Future<void> arrangeExploreTopics(ExploreSection section, List<String> order, Set<String> hidden) => _arrangeExplore(
        section,
        () => savePreferences(preferences.copyWith(
          exploreOrder: {...preferences.exploreOrder, section.name: order},
          exploreHidden: {...preferences.exploreHidden, section.name: hidden.toList()},
        )),
      );

  /// Runs [change] and keeps the zone shown if it is still in the strip.
  Future<void> _arrangeExplore(ExploreSection section, Future<void> Function() change) async {
    final shown = exploreTopicNow.key;
    await change();
    if (section != exploreSection) return;
    final index = exploreTopicsFor(section).indexWhere((t) => t.key == shown);
    if (index == exploreTopic) {
      notifyListeners();
    } else if (index >= 0) {
      // Same zone at another place: nothing to load again.
      _update(() => exploreTopic = index);
    } else {
      _reloadExplore(topic: 0);
    }
  }

  void _reloadExplore({ExploreSection? section, required int topic}) {
    explore?.dispose();
    explore = null;
    setExplore(section: section, topic: topic < 0 ? 0 : topic);
  }

  /// Opens the explore page on its topics.
  void openExplore() {
    _remember();
    if (_query != null) {
      _query = null;
      searchResults?.dispose();
      searchResults = null;
    }
    _go(PageMode.explore);
    _loadExplore();
  }

  (ExploreSection, int) _topicBeforeFaith = (ExploreSection.popular, 0);

  /// Leaves 宗教与信仰 for the video zones, on the zone shown before.
  /// 视频 or 直播, whichever 宗教信仰 was opened from while its tabs show.
  ExploreSection get exploreHalf => exploreSection.isFaith ? _topicBeforeFaith.$1 : exploreSection;

  void leaveFaith() {
    final (section, topic) = _topicBeforeFaith;
    final topics = exploreTopicsFor(section);
    final index = topic.clamp(0, topics.length - 1);
    // Not back into 宗教信仰 itself, say when it is pinned first.
    final back = topics[index].opens == null ? index : topics.indexWhere((t) => t.opens == null);
    if (back >= 0) setExplore(section: section, topic: back);
  }

  /// Shows another part, zone, sub-category, mode, period or filter of the
  /// explore page. A new part starts on its first zone, and on its usual
  /// mode unless the one shown also suits it; a new zone on all of it.
  void setExplore({
    ExploreSection? section,
    int? topic,
    int? sub,
    int? leaf,
    ExploreMode? mode,
    SearchUploadDate? period,
    SearchDuration? duration,
    SearchQuality? quality,
    WordFilter? format,
    WordFilter? view,
    ExploreRegion? region,
    ExploreLanguage? language,
  }) {
    if ((region != null && region != preferences.exploreRegion) || (language != null && language != preferences.exploreLanguage)) {
      unawaited(savePreferences(preferences.copyWith(exploreRegion: region, exploreLanguage: language)));
      explore?.dispose();
      explore = null;
    }
    final nextSection = section ?? exploreSection;
    final newSection = nextSection != exploreSection;
    final topics = exploreTopicsFor(nextSection);
    final nextTopic = (topic ?? (newSection ? 0 : exploreTopic)).clamp(0, topics.length - 1);
    // 宗教信仰 among the video zones opens 宗教与信仰's tabs; leaving them
    // goes back to the zone shown before.
    final opens = topics[nextTopic].opens;
    if (opens != null) {
      if (!exploreSection.isFaith) _topicBeforeFaith = (exploreSection, exploreTopic);
      setExplore(section: opens);
      return;
    }
    final nextSub = sub ?? (newSection || nextTopic != exploreTopic ? 0 : exploreSub);
    final nextLeaf = leaf ?? (newSection || nextTopic != exploreTopic || nextSub != exploreSub ? 0 : exploreLeaf);
    final modes = ExploreMode.of(nextSection);
    final sameKind = nextSection.isFaith == exploreSection.isFaith && nextSection.isLive == exploreSection.isLive;
    final nextMode = mode != null && modes.contains(mode)
        ? mode
        : !newSection || (sameKind && modes.contains(exploreMode))
            ? exploreMode
            : ExploreMode.defaultOf(nextSection);
    final nextPeriod = period ?? explorePeriod;
    final nextDuration = duration ?? exploreDuration;
    final nextQuality = quality ?? exploreQuality;
    // A filter of the other kind's list starts over at 不限.
    final formats = formatsOf(nextSection), views = viewsOf(nextSection);
    final nextFormat = format ?? (formats.contains(exploreFormat) ? exploreFormat : formats.first);
    final nextView = view ?? (views.contains(exploreView) ? exploreView : views.first);
    if (!newSection &&
        nextTopic == exploreTopic &&
        nextSub == exploreSub &&
        nextLeaf == exploreLeaf &&
        nextMode == exploreMode &&
        nextPeriod == explorePeriod &&
        nextDuration == exploreDuration &&
        nextQuality == exploreQuality &&
        nextFormat == exploreFormat &&
        nextView == exploreView &&
        explore != null) {
      return;
    }
    _update(() {
      exploreSection = nextSection;
      exploreTopic = nextTopic;
      exploreSub = nextSub;
      exploreLeaf = nextLeaf;
      exploreFormat = nextFormat;
      exploreView = nextView;
      exploreMode = nextMode;
      explorePeriod = nextPeriod;
      exploreDuration = nextDuration;
      exploreQuality = nextQuality;
      explore?.dispose();
      explore = null;
    });
    _loadExplore();
  }

  void _loadExplore() {
    final repository = _repository;
    if (repository == null || explore != null) return;
    if (exploreTopicNow.opens case final opens?) {
      setExplore(section: opens);
      return;
    }
    final query = exploreQuery;
    final mode = exploreMode;
    final mix = exploreTopicNow.mix;
    final region = preferences.exploreRegion.gl;
    final language = preferences.exploreLanguage;
    final perChannel = <String, int>{};
    final sp = exploreParams(mode, period: explorePeriod, duration: exploreDuration, quality: exploreQuality);
    // 推荐 always goes by the history, whatever order it is shown in.
    final taste = mode == ExploreMode.forYou || exploreTopicNow.personal ? _exploreTaste() : null;
    // The Home and Explore "For You" lists share these choices.  Explore has
    // its own loader, so it must apply the mix here instead of relying on
    // HomeFeed's ranking pass.
    final feedMix = mode == ExploreMode.forYou ? preferences.feedMix : null;
    final notInterested = homeFeed?.notInterested;
    final faith = exploreSection.isFaith ? faithFilter() : null;
    bool where(VideoItem item) {
      if (notInterested != null && notInterested.videos.contains(item.id)) return false;
      // Left out here too, so that hiding them still fills the page.
      if (preferences.blocksGroup(item) || preferences.isUnrecommended(item.channelId)) return false;
      // "Don't recommend" is a hard exclusion.  "Fewer" remains in the
      // list, but its score is reduced below in the ranking callback.
      if (feedMix?.penaltyOf(item) == null) return false;
      if (taste != null && taste.channelAffinity(item) < -0.3) return false;
      if (mode == ExploreMode.liveUpcoming && !item.isUpcoming) return false;
      if (mode == ExploreMode.liveReplay && item.liveStatus != 'was_live') return false;
      final seconds = item.duration;
      if (mode == ExploreMode.gems) {
        final views = item.viewCount;
        if (views == null || views > gemMaxViews || seconds == null || seconds < 240) return false;
      }
      if (mode == ExploreMode.curated && seconds != null && seconds < 240) return false;
      if (!language.matches(item.title)) return false;
      // A mix keeps any one channel from filling it.
      if (mix && (perChannel[TasteProfile.channelKey(item)] = (perChannel[TasteProfile.channelKey(item)] ?? 0) + 1) > 2) return false;
      // Last, as it counts the videos that show.
      return faith == null || faith(item);
    }

    _update(() => explore = VideoListLoader(
          () => mix ? repository.searchMix(_exploreMixQueries(exploreSection, exploreTopicNow.personal ? taste ?? _exploreTaste() : null), sp: sp, region: region) : repository.search(query, sp: sp, region: region),
          where: where,
          fill: switch (mode) {
            ExploreMode.gems || ExploreMode.liveReplay => 8,
            ExploreMode.liveUpcoming => 4,
            _ => faith != null || mix || language != ExploreLanguage.any ? 8 : 1,
          },
          rank: taste == null
              ? null
              : (item) => exploreScore(taste, item) - (feedMix?.penaltyOf(item) ?? 0),
        )
          ..addListener(notifyListeners)
          ..loadMore());
  }

  /// 推荐 and 全部's searches: zones of [section] picked at random each
  /// time, so every visit brings others, and for 推荐 a few of the
  /// history's interests ([taste]) in place of two of them.
  List<String> _exploreMixQueries(ExploreSection section, TasteProfile? taste, {Random? random}) {
    final interests = (taste?.topWords(8) ?? <String>[])..shuffle(random);
    final zones = [
      for (final topic in exploreTopicsFor(section))
        if (!topic.mix && topic.opens == null) topic.subs.isEmpty ? topic.query : (topic.subs.toList()..shuffle(random)).first.query,
    ]..shuffle(random);
    final picked = interests.take(2).toList();
    final filter = [exploreFormat.words, exploreView.words].where((w) => w.isNotEmpty).join(' ');
    return [for (final query in [...picked, ...zones.take(6 - picked.length)]) filter.isEmpty ? query : '$query $filter'];
  }

  /// Shows 推荐 or the zone shown with other videos.
  void refreshExplore() {
    explore?.dispose();
    explore = null;
    _loadExplore();
  }

  /// What the history says about taste, for 为你推荐 in explore.
  TasteProfile _exploreTaste() {
    final library = this.library;
    return TasteProfile.from(
      history: history,
      progressOf: library?.progressOf,
      favorites: [...?library?.favorites, ...?account?.likedVideos.take(50)],
      followed: {for (final c in library?.channels ?? const <ChannelRef>[]) c.id},
      decay: 0.97,
    );
  }

  /// 为你推荐 in a zone: title words and channels like the history's
  /// first, then more viewed.
  static double exploreScore(TasteProfile taste, VideoItem item) {
    final views = item.viewCount ?? 0;
    return 0.55 * taste.titleMatch(item) + 0.35 * max(0.0, taste.channelAffinity(item)) + 0.1 * min(1.0, log(views + 1) / ln10 / 7);
  }

  static String? parseYoutubeId(String input) {
    final url = Uri.tryParse(input);
    if (url == null || !url.hasScheme || url.scheme != 'https') return null;
    if (url.host == 'youtu.be') {
      final id = url.pathSegments.isNotEmpty ? url.pathSegments.first : '';
      return RegExp(r'^[\w-]{11}$').hasMatch(id) ? id : null;
    }
    if (url.host == 'youtube.com' || url.host == 'www.youtube.com' || url.host == 'm.youtube.com') {
      final id = url.queryParameters['v'] ??
          ((url.pathSegments.length >= 2 && (url.pathSegments.first == 'shorts' || url.pathSegments.first == 'live')) ? url.pathSegments[1] : '');
      return RegExp(r'^[\w-]{11}$').hasMatch(id) ? id : null;
    }
    return null;
  }

  /// Plays [item]; [from] is the list it was picked from and becomes the queue.
  /// Opens [item] on the watch page; [at] is where to start, else where
  /// it was left off. [keepMini] plays it in the mini player when that is
  /// where the last video was (the queue moving on by itself).
  Future<void> play(VideoItem item, {List<VideoItem>? from, Duration? at, bool keepMini = false}) async {
    final player = this.player;
    if (player == null) return;
    if (mini && playing?.id == item.id && at == null) return expandMini();
    if (playing?.id != item.id) {
      unawaited(cast.stop());
      if (playing case final left?) {
        _played.removeWhere((v) => v.id == left.id);
        _played.add(left);
        if (_played.length > 50) _played.removeAt(0);
      }
      _remember();
      _finishWatching();
      _watching = item;
    }
    unawaited(account?.loadRating(item.id));
    _saveProgress();
    _stopCurrentChat();
    final serial = ++_playSerial;
    _recoveryTimer?.cancel();
    _recovery.reset();
    final resume = preferences.resumePlayback ? library?.progressOf(item.id) : null;
    final start = at ?? (resume != null && resume.resumable ? resume.position : null);
    _update(() {
      playing = item;
      mini = keepMini && mini;
      if (from != null) queue = List.unmodifiable(from);
      playbackError = null;
      details = null;
      loadingDetails = true;
      replayChat = const [];
      loadingReplayChat = false;
      replayChatError = null;
      availableHeights = const [];
      related?.dispose();
      related = null;
      _segments = const [];
      _skipped.clear();
      dislikes = null;
    });
    unawaited(_loadDetails(item, serial));
    if (settings.returnDislike) unawaited(_loadDislikes(item, serial));
    if (settings.sponsorBlock) unawaited(_loadSegments(item, serial));
    if (await _open(item, serial, start: start, play: preferences.autoPlay)) {
      if (settings.defaultSpeed != player.state.rate) await player.setRate(settings.defaultSpeed);
      if (preferences.recordHistory) await _history?.record(item);
      if (start != null && at == null) _notice(tr('从 {0} 继续播放', [_clock(start)]));
      final next = upNext.firstOrNull;
      if (next != null) prefetch(next);
      if (item.isLive) {
        _startCurrentChat(item, serial);
      } else if (item.liveStatus == 'was_live') {
        unawaited(_loadReplayChat(item, serial));
      }
    }
  }

  void _startCurrentChat(VideoItem item, int serial) {
    final repository = _repository;
    if (repository == null || serial != _playSerial) return;
    _update(() {
      loadingReplayChat = true;
      replayChatError = null;
    });
    _currentChat = repository.liveChat.current(item.id).listen(
      (message) {
        if (serial != _playSerial || !_currentChatIds.add(message.id)) return;
        _currentChatPending.add(message);
        _currentChatFlushTimer ??= Timer(const Duration(milliseconds: 300), () {
          _currentChatFlushTimer = null;
          _flushCurrentChat(serial);
        });
      },
      onError: (Object error) {
        if (serial == _playSerial) {
          _update(() {
            replayChatError = '$error';
            loadingReplayChat = false;
          });
        }
      },
      onDone: () {
        _flushCurrentChat(serial);
        if (serial == _playSerial) {
          _update(() => loadingReplayChat = false);
        }
      },
    );
  }

  void _flushCurrentChat(int serial) {
    if (serial != _playSerial || _currentChatPending.isEmpty) return;
    final next = [...replayChat, ..._currentChatPending];
    _currentChatPending.clear();
    _update(() {
      replayChat = List.unmodifiable(next.length > 2000 ? next.sublist(next.length - 2000) : next);
      loadingReplayChat = false;
    });
  }

  void _stopCurrentChat() {
    _currentChatFlushTimer?.cancel();
    _currentChatFlushTimer = null;
    _currentChatPending.clear();
    _currentChatIds.clear();
    unawaited(_currentChat?.cancel());
    _currentChat = null;
  }

  Future<void> _loadReplayChat(VideoItem item, int serial) async {
    final repository = _repository;
    if (repository == null || serial != _playSerial) return;
    _update(() {
      loadingReplayChat = true;
      replayChatError = null;
    });
    try {
      final messages = await repository.liveChat.replay(item.id);
      if (serial == _playSerial) _update(() => replayChat = messages);
    } catch (error) {
      if (serial == _playSerial) _update(() => replayChatError = '$error');
    } finally {
      if (serial == _playSerial) _update(() => loadingReplayChat = false);
    }
  }

  static String _clock(Duration d) {
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds' : '${d.inMinutes}:$seconds';
  }

  /// Records where the current video is, so it can resume later.
  /// [now] writes it to disk at once, for when playback stops.
  void _saveProgress({bool now = false}) {
    final item = _tracking;
    final player = this.player;
    if (item == null || player == null || !preferences.recordProgress) return;
    final duration = player.state.duration;
    if (duration <= Duration.zero) return;
    library?.recordProgress(item.id, player.state.position, duration);
    if (now) unawaited(library?.flush());
  }

  Future<void> _loadSegments(VideoItem item, int serial) async {
    try {
      final local = downloads?.localVideo(item.id);
      final saved = [for (final s in local?.segments ?? const <SkipSegment>[]) if (settings.sponsorCategories.contains(s.category)) s];
      final segments = saved.isNotEmpty ? saved : await _sponsorBlock.segments(item.id, settings.sponsorCategories);
      if (serial == _playSerial) _update(() => _segments = segments);
    } catch (_) {
      // Playback does not depend on SponsorBlock being reachable.
    }
  }

  Future<void> _loadDislikes(VideoItem item, int serial) async {
    try {
      final count = await _returnDislike.votes(item.id);
      if (serial == _playSerial) _update(() => dislikes = count);
    } catch (_) {
      // The page shows the likes without it.
    }
  }

  void _skipSegments(Duration position) {
    for (final segment in _segments) {
      if (_skipped.contains(segment) || !segment.contains(position)) continue;
      // Each segment is skipped once, so seeking back into it plays it.
      _skipped.add(segment);
      unawaited(player?.seek(segment.end));
      if (settings.sponsorNotice) _notice(tr('已跳过{0}', [sponsorCategories[segment.category] ?? tr('片段')]));
      return;
    }
  }

  /// Opens [item] with the current format settings, from [start] if given.
  ///
  /// The video is resolved by yt-dlp first, usually already done for the
  /// watch page or while the pointer rested on its card. libmpv then plays
  /// the picked streams directly, or has its ytdl_hook pick formats and
  /// subtitles from the saved extraction without asking YouTube again.
  /// [resolved] false, or a failed resolution, leaves everything to
  /// ytdl_hook as before.
  Future<bool> _open(VideoItem item, int serial, {Duration? start, bool play = true, bool resolved = true, bool piped = true, bool allowLocal = true}) async {
    final player = this.player!;
    try {
      if (!_libmpvConfirmed) await _tools?.libmpv.markPlaying();
      if (settings.proxyMode == ProxyMode.system) await _refreshProxy(ifStale: true);
      final local = allowLocal && resolved && piped && !item.isLive ? downloads?.localVideo(item.id) : null;
      _openedLocal = null;
      // A download in a codec the playback rules disable (AV1 decoded in
      // software, say) streams instead, in a codec the rules allow.
      final localCodec = local?.videoCodec;
      if (local != null && !FormatPolicy.allows(settings, localCodec)) {
        logInfo('${item.id} 的下载文件是 ${localCodec!.label}，播放规则已禁用该编码，改为在线播放');
        _notice(tr('下载的文件是 {0} 编码，已按播放规则改为在线播放', [localCodec.label]));
      } else if (local != null) {
        return await _openLocal(item, serial, local, start: start, play: play);
      }
      final format = _format;
      final formatSort = _formatSort;
      _openedVia = null;
      if (resolved && piped) {
        _recentErrors.clear();
        _relaysTried.clear();
        _rateLimited = null;
      }
      // Piped or Invidious first, as chosen in 播放来源.
      if (piped) {
        if (await _openViaRelays(item, serial, start: start, play: play)) return true;
        if (serial != _playSerial) return false;
      }
      ResolvedVideo? video;
      if (resolved) {
        try {
          video = await _repository!.streams.resolve(item.id, format, formatSort: formatSort);
        } catch (e) {
          _recentErrors.add('$e');
          final failure = PlaybackFailure.classify(['$e']);
          if (!failure.retryable) {
            // libmpv's ytdl_hook would ask YouTube again and fail the same way.
            if (failure.kind == FailureKind.rateLimited) return await _fallBackFromRateLimit(item, serial, failure, start: start, play: play);
            if (serial == _playSerial) _fail(item, failure);
            return false;
          }
          logError('预先解析 ${item.id} 失败，改由 libmpv 解析', e);
        }
        if (serial != _playSerial) return false;
      }
      final subtitles = settings.subtitleMode != SubtitleMode.off;
      // Through the relay when the app's own connections reach YouTube the
      // way libmpv's would: directly or through an HTTP proxy.
      final relay = proxy.url == null || proxy.isHttp ? _relay : null;
      final agent = video?.userAgent;
      final direct = video != null && video.format == format && !subtitles
          ? video.directAddress(relay: relay == null ? null : (url, size) => relay.register(url, size: size, userAgent: agent))
          : null;
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('ytdl-format', format);
        await platform.setProperty('ytdl-raw-options', PlayerOptionApplicator.ytdlRawOptions(settings, infoJson: direct == null ? video?.file.path : null, proxy: proxy.ytDlpValue(settings.proxyMode)));
        if (direct != null && agent != null) await platform.setProperty('user-agent', agent);
      }
      _tracking = null;
      if (secondarySubtitle != null) {
        secondarySubtitle = null;
        if (platform is NativePlayer) unawaited(platform.setProperty('secondary-sid', 'no').catchError((_) {}));
      }
      _lastPosition = start ?? Duration.zero;
      _openedResolved = video == null ? null : item.id;
      if (video != null) _update(() => availableHeights = video!.heightsFor(settings));
      await player.open(Media(direct ?? item.url, start: start), play: play);
      if (serial == _playSerial) _tracking = item;
      _mpvLogLines = 0;
      _lastDrops = 0;
      // The decoder is known once frames are shown; resolving the video
      // can take longer than any fixed delay.
      _decoderPending = true;
      _update(() {});
      return true;
    } catch (e) {
      logError('无法打开视频 ${item.id}', e);
      if (serial == _playSerial) _fail(item, PlaybackFailure.classify(['$e', ..._recentErrors]));
      return false;
    }
  }

  /// Plays the downloaded file of [item] instead of asking YouTube.
  Future<bool> _openLocal(VideoItem item, int serial, LocalVideo local, {Duration? start, bool play = true}) async {
    final player = this.player!;
    _recentErrors.clear();
    _openedVia = null;
    _openedResolved = null;
    _tracking = null;
    if (secondarySubtitle != null) {
      secondarySubtitle = null;
      final platform = player.platform;
      if (platform is NativePlayer) unawaited(platform.setProperty('secondary-sid', 'no').catchError((_) {}));
    }
    _lastPosition = start ?? Duration.zero;
    _openedLocal = item.id;
    await player.open(Media(local.file.path, start: start), play: play);
    if (serial == _playSerial) _tracking = item;
    _mpvLogLines = 0;
    _lastDrops = 0;
    _decoderPending = true;
    _update(() {});
    unawaited(_addLocalSubtitles(local, serial));
    return true;
  }

  /// Adds the subtitle files saved next to a downloaded video, the one in
  /// the preferred language selected, unless subtitles are set to stay off.
  Future<void> _addLocalSubtitles(LocalVideo local, int serial) async {
    final player = this.player;
    final platform = player?.platform;
    if (player == null || platform is! NativePlayer || local.subtitles.isEmpty || settings.subtitleMode == SubtitleMode.off) return;
    try {
      await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 15));
      if (serial != _playSerial) return;
      final first = local.preferredSubtitle(settings.subtitleLanguage.mpvLangs.split(','));
      await platform.command(['sub-add', first.path, 'select']);
      for (final other in local.subtitles.where((f) => f != first)) {
        await platform.command(['sub-add', other.path, 'auto']);
      }
    } catch (e) {
      logError('无法加载离线字幕', e);
    }
  }

  /// The server network to try next for [item], or null for YouTube.
  /// Normally the one 播放来源 names, and only without subtitles, which
  /// these servers do not give libmpv. After YouTube answered 429 both are
  /// tried (that one first), subtitles or not, since playing beats failing.
  RelayKind? _nextRelay(VideoItem item) {
    if (item.isLive) return null;
    final preferred = settings.playbackSource.relay;
    final candidates = _rateLimited != null
        ? [if (preferred != null) preferred, ...RelayKind.values.where((k) => k != preferred)]
        : [if (preferred != null && settings.subtitleMode == SubtitleMode.off) preferred];
    return candidates.where((k) => !_relaysTried.contains(k)).firstOrNull;
  }

  /// Opens [item] from the next server [_nextRelay] names, moving on to the
  /// one after when a server cannot resolve it; false when none plays it.
  Future<bool> _openViaRelays(VideoItem item, int serial, {Duration? start, bool play = true}) async {
    final player = this.player!;
    while (true) {
      final kind = _nextRelay(item);
      if (kind == null) return false;
      _relaysTried.add(kind);
      final address = await _relayAddress(item, kind);
      if (serial != _playSerial) return false;
      if (address == null) continue;
      _tracking = null;
      _lastPosition = start ?? Duration.zero;
      _openedResolved = null;
      _openedVia = item.id;
      await player.open(Media(address, start: start), play: play);
      if (serial == _playSerial) _tracking = item;
      _mpvLogLines = 0;
      _lastDrops = 0;
      _decoderPending = true;
      _update(() {});
      return true;
    }
  }

  /// YouTube answered 429 for [item]: plays it from the Piped or Invidious
  /// server not yet tried, and only when there is none shows the error.
  Future<bool> _fallBackFromRateLimit(VideoItem item, int serial, PlaybackFailure failure, {Duration? start, bool play = true}) async {
    _rateLimitedUntil = DateTime.now().add(const Duration(minutes: 10));
    _rateLimited = failure;
    if (await _openViaRelays(item, serial, start: start, play: play)) return true;
    if (serial == _playSerial) _fail(item, PlaybackFailure(failure.kind, failure.detail, tried: [for (final k in _relaysTried) k == RelayKind.piped ? 'Piped' : 'Invidious']));
    return false;
  }

  /// The play address for [item] from a [kind] server, or null to go on.
  Future<String?> _relayAddress(VideoItem item, RelayKind kind) async {
    final watch = Stopwatch()..start();
    final name = kind == RelayKind.piped ? 'Piped' : 'Invidious';
    try {
      final source = settings.playbackSource;
      final named = source.relay == kind && source.isCustom ? (kind == RelayKind.piped ? settings.pipedServer : settings.invidiousServer) : '';
      final server = named.isEmpty ? null : named;
      final video = await (kind == RelayKind.piped ? _piped.fetch(item.id, server: server) : _invidious.fetch(item.id, server: server));
      final address = video.edl(_playback);
      if (address == null) return null;
      _update(() => availableHeights = video.heightsFor(settings));
      logInfo('从 $name ${video.server} 播放 ${item.id}，用时 ${watch.elapsedMilliseconds} ms');
      return address;
    } catch (e) {
      logInfo('$e，不使用 $name');
      return null;
    }
  }

  /// Shows why [item] cannot play and acts on the cause.
  void _fail(VideoItem item, PlaybackFailure failure) {
    _recoveryTimer?.cancel();
    _recovery.cancelPending();
    logError('播放失败 ${item.id}（${failure.kind.name}）：${failure.detail}');
    if (failure.kind == FailureKind.noFormat) failure = PlaybackFailure(failure.kind, failure.detail, disabled: FormatPolicy.disabledNames(settings));
    switch (failure.kind) {
      case FailureKind.rateLimited:
        _rateLimitedUntil = DateTime.now().add(const Duration(minutes: 10));
      case FailureKind.challenge:
        if (!_updateCheckedForChallenge) {
          _updateCheckedForChallenge = true;
          unawaited(checkUpdates());
        }
      default:
    }
    _update(() => playbackError = failure.message);
  }

  /// Reopens the current video where it stopped after the network failed,
  /// or shows [message] once the attempts are used up.
  Future<void> _recover(String message) async {
    final item = _tracking;
    if (item == null || _recovering) return;
    final position = _lastPosition;
    if (!_recovery.tryAttempt(position: position)) {
      logError('播放中断，已放弃自动重连 ${item.id}：$message');
      _fail(item, PlaybackFailure.classify([message, ..._recentErrors]));
      return;
    }
    logInfo('播放中断，从 ${_clock(position)} 重新连接 ${item.id}：$message');
    _notice(tr('网络中断，正在从 {0} 重新连接…', [_clock(position)]));
    _recovering = true;
    _recoveryTimer?.cancel();
    final serial = _playSerial;
    try {
      // A new open also asks yt-dlp again, which replaces stream addresses
      // that expired while the video sat paused.
      _repository?.streams.forget(item.id);
      final opened = await _open(item, serial, start: position);
      if (!opened || serial != _playSerial) return;
      _recoveryTimer = Timer.periodic(PlaybackRecovery.stallTimeout, (_) {
        if (serial != _playSerial || !_recovery.awaitingProgress) {
          _recoveryTimer?.cancel();
        } else if (_recovery.stalled && player!.state.playing) {
          unawaited(_recover('Playback did not advance after reopening'));
        }
      });
    } finally {
      _recovering = false;
    }
  }

  /// Shows [option], adding it to the player first if it is not loaded.
  Future<void> showSubtitle(SubtitleOption option) async {
    final player = this.player;
    final platform = player?.platform;
    if (player == null || platform is! NativePlayer) return;
    final loaded = player.state.tracks.subtitle.where((t) => t.title == option.label).firstOrNull;
    try {
      if (loaded != null) {
        await player.setSubtitleTrack(loaded);
      } else {
        await platform.command(['sub-add', option.url, 'select', option.label, option.language]);
      }
    } catch (e) {
      logError('无法加载字幕 ${option.language}', e);
      _notice(tr('无法加载这条字幕'));
    }
  }

  /// Shows [option] (null: none) above the main subtitle.
  Future<void> setSecondarySubtitle(SubtitleOption? option) async {
    final player = this.player;
    if (player == null) return;
    try {
      if (!await SecondarySubtitle.set(player, option)) throw StateError('字幕未加载');
      _update(() => secondarySubtitle = option);
    } catch (e) {
      logError('无法设置副字幕 ${option?.language}', e);
      _notice(tr('无法加载这条字幕'));
    }
  }

  Future<void> retryPlayback() async {
    final item = playing;
    if (item != null) await play(item);
  }

  void _listenTo(Player player) {
    _playerSubscriptions.addAll([
      // A second of playback proves a downloaded libmpv works on this PC.
      player.stream.position.listen((position) {
        if (_tracking == null) return;
        if (position > Duration.zero) {
          if (_recovery.observeProgress(position,
            playing: player.state.playing,
            buffering: player.state.buffering,
            decoded: audioOnly || _backgroundAudioOnly || (player.state.width ?? 0) > 0,
            rate: player.state.rate,
          )) {
            _recoveryTimer?.cancel();
            logInfo('Playback recovered after ten seconds of decoded progress');
          }
          _lastPosition = position;
        }
        if (_decoderPending && position > const Duration(milliseconds: 500) && (player.state.width ?? 0) > 0) {
          _decoderPending = false;
          unawaited(inspectCurrentDecoder(delay: const Duration(milliseconds: 500)));
        }
        if (_segments.isNotEmpty) _skipSegments(position);
        final now = DateTime.now();
        if (now.difference(_lastProgressSave) > const Duration(seconds: 5)) {
          _lastProgressSave = now;
          _saveProgress();
        }
        if (_libmpvConfirmed || position < const Duration(seconds: 1)) return;
        _libmpvConfirmed = true;
        unawaited(_tools?.libmpv.confirm());
      }),
      player.stream.completed.listen((done) {
        if (!done || playing == null) return;
        if (_tracking != null && PlaybackRecovery.endedEarly(_lastPosition, player.state.duration)) {
          unawaited(_recover(tr('视频在 {0} 意外结束', [_clock(_lastPosition)])));
          return;
        }
        _saveProgress();
        unawaited(_playAfterEnd());
      }),
      // libmpv reports failures that happen after open() returned, such as
      // yt-dlp finding no playable format, only through this stream. Errors
      // once the video has loaded (a broken subtitle track) are not fatal.
      player.stream.error.listen((message) {
        if (playing == null || message.isEmpty) return;
        if (isSubtitleError(message)) {
          logInfo('字幕加载失败，视频继续播放：$message');
          return;
        }
        // FFmpeg may log the HTTP status before naming the request. Keep
        // it diagnostic-only; media URL failures, EOF and stalls drive recovery.
        if (isUnattributedHttpError(message)) return;
        _onPlayerError(player, message, loaded: player.state.duration > Duration.zero);
      }),
      // libmpv's warnings go to the log, a limited number per video, so
      // problems such as dropped frames can be read after the fact.
      player.stream.log.listen((log) {
        final text = log.text.trim();
        final subtitle = isSubtitleError(text) || log.prefix == 'sub' || log.prefix.startsWith('sub/');
        if ((log.level == 'error' || log.prefix == 'ytdl_hook') && _recentErrors.length < 20 && !subtitle && !isUnattributedHttpError(text)) _recentErrors.add(text);
        if (_mpvLogLines >= 200) return;
        _mpvLogLines++;
        logInfo('mpv [${log.prefix}] ${log.level}: $text');
      }),
      // A stream that stops delivering data leaves mpv buffering forever.
      player.stream.buffering.listen((buffering) {
        _stallTimer?.cancel();
        if (!buffering || _tracking == null) return;
        _stallTimer = Timer(PlaybackRecovery.stallTimeout, () {
          if (player.state.buffering && player.state.playing) unawaited(_recover(tr('缓冲超过 {0} 秒没有进展', [PlaybackRecovery.stallTimeout.inSeconds])));
        });
      }),
    ]);
  }

  /// An mpv error that was not about a subtitle.
  void _onPlayerError(Player player, String message, {required bool loaded}) {
    if (!loaded) {
      final item = playing!;
      final viaRelay = _openedVia == item.id;
      _openedVia = null;
      // What a server's address says is not what YouTube said earlier.
      final failure = PlaybackFailure.classify(viaRelay ? [message] : [message, ..._recentErrors]);
      final position = _lastPosition > Duration.zero ? _lastPosition : null;
      if (viaRelay) {
        if (!failure.retryable && failure.kind != FailureKind.rateLimited) {
          _fail(item, failure);
          return;
        }
        final limited = _rateLimited;
        logInfo('Piped 或 Invidious 的地址无法播放（$message），改${limited != null ? '用下一个服务器' : '为直接连接 YouTube'}');
        unawaited(limited != null ? _fallBackFromRateLimit(item, _playSerial, limited, start: position) : _open(item, _playSerial, start: position, piped: false));
        return;
      }
      if (failure.kind == FailureKind.rateLimited) {
        unawaited(_fallBackFromRateLimit(item, _playSerial, failure, start: position));
        return;
      }
      if (!failure.retryable) {
        _fail(item, failure);
        return;
      }
      if (_openedResolved == item.id) {
        // Addresses resolved ahead may have gone stale; let libmpv's
        // ytdl_hook resolve the video itself once.
        _openedResolved = null;
        _repository?.streams.forget(item.id);
        logInfo('预先解析的地址无法播放（$message），改由 libmpv 重新解析 ${item.id}');
        unawaited(_open(item, _playSerial, start: _lastPosition > Duration.zero ? _lastPosition : null, resolved: false));
        return;
      }
      _fail(item, failure);
    } else if (PlaybackRecovery.isNetworkError(message)) {
      final failure = PlaybackFailure.classify([message, ..._recentErrors]);
      if (failure.retryable) {
        unawaited(_recover(message));
      } else {
        _fail(playing!, failure);
      }
    }
  }

  /// Follows [PlayerSettings.playOrder] once a video ends. Single cycle is
  /// mpv's loop-file, so a looping video never ends.
  Future<void> _playAfterEnd() async {
    final done = playing;
    if (done != null && preferences.watchLaterAutoRemove) library?.removeWatchLater(done.id);
    if (sleepAfterCurrent) {
      _update(() => sleepAfterCurrent = false);
      _notice(tr('定时关闭：当前视频已播完'));
      return;
    }
    if (await playQueued()) return;
    switch (settings.playOrder) {
      case PlayOrder.pause || PlayOrder.singleCycle:
        return;
      case PlayOrder.listOrder:
        if (upNext.isNotEmpty) await play(upNext.first, keepMini: true);
      case PlayOrder.listCycle:
        if (upNext.isNotEmpty) {
          await play(upNext.first, keepMini: true);
        } else if (queue.isNotEmpty) {
          await play(queue.first, keepMini: true, at: mini && queue.first.id == playing?.id ? Duration.zero : null);
        } else if (playing != null) {
          await play(playing!, keepMini: true, at: Duration.zero);
        }
      case PlayOrder.autoPlayRelated:
        await playNext(keepMini: true);
    }
  }

  /// Plays the next video in the queue, if there is one.
  Future<void> playNext({bool keepMini = false}) async {
    if (await playQueued(null, keepMini)) return;
    final next = upNext;
    final suggestions = relatedItems;
    if (next.isNotEmpty) {
      await play(next.first, keepMini: keepMini);
    } else if (suggestions.isNotEmpty) {
      await play(suggestions.first, from: suggestions, keepMini: keepMini);
    }
  }

  @visibleForTesting
  Future<void> playAfterEndForTest() => _playAfterEnd();

  /// 下一个播放: [item] goes to the front of [playQueue].
  void queueNext(VideoItem item) {
    _update(() => playQueue.addNext(item));
    _notice(tr('将在当前视频之后播放'));
  }

  /// 加入播放队列: [item] goes to the end of [playQueue].
  void queueLast(VideoItem item) {
    final added = playQueue.addLast(item);
    _update(() {});
    _notice(added ? tr('已加入播放队列') : tr('播放队列里已经有这个视频'));
  }

  void removeQueued(String id) => _update(() => playQueue.remove(id));

  void clearQueue() => _update(playQueue.clear);

  void moveQueued(int from, int to) => _update(() => playQueue.move(from, to));

  /// Plays [item], or the first of [playQueue], and takes it off the queue.
  /// The list the current video came from carries on after the queued ones.
  /// False when there was nothing to play.
  Future<bool> playQueued([VideoItem? item, bool keepMini = false]) async {
    final next = item ?? playQueue.items.firstOrNull;
    if (next == null) return false;
    _update(() => playQueue.remove(next.id));
    final at = playing == null ? -1 : queue.indexWhere((other) => other.id == playing!.id);
    final rest = [for (final other in queue) if (other.id != next.id) other];
    final from = at < 0 ? null : [...rest.take(at + 1), next, ...rest.skip(at + 1)];
    await play(next, from: from, keepMini: keepMini);
    return true;
  }

  /// The video before the current one in the queue, if it was opened from one.
  VideoItem? get previousInQueue {
    final current = playing;
    if (current == null) return null;
    final index = queue.indexWhere((item) => item.id == current.id);
    return index > 0 ? queue[index - 1] : null;
  }

  bool _backgroundAudioOnly = false;

  /// While the window is minimised or in the tray with the setting on, mpv
  /// decodes no picture; [hidden] false brings it back. A user's own 听视频
  /// choice is left alone.
  Future<void> setBackgroundAudioOnly(bool hidden) async {
    final platform = player?.platform;
    if (platform is! NativePlayer) return;
    if (hidden) {
      if (!preferences.audioOnlyInBackground || audioOnly || _backgroundAudioOnly || !player!.state.playing) return;
      _backgroundAudioOnly = true;
      await platform.setProperty('vid', 'no');
    } else if (_backgroundAudioOnly) {
      _backgroundAudioOnly = false;
      if (!audioOnly) await platform.setProperty('vid', 'auto');
    }
  }

  /// Whether nothing will play once the current video ends.
  bool get stopsAfterEnd =>
      sleepAfterCurrent ||
      playQueue.isEmpty &&
      switch (settings.playOrder) {
        PlayOrder.pause => true,
        PlayOrder.singleCycle || PlayOrder.listCycle => false,
        PlayOrder.listOrder => upNext.isEmpty,
        PlayOrder.autoPlayRelated => !hasNext,
      };

  /// SponsorBlock segments of the playing video, for the progress bar.
  List<SkipSegment> get segments => _segments;

  /// When the sleep timer pauses playback; null when it is off.
  DateTime? sleepAt;
  /// Pause once the current video ends instead of at [sleepAt].
  bool sleepAfterCurrent = false;
  Timer? _sleepTimer;

  /// Pauses playback after [after], or at the end of the current video when
  /// [afterCurrent]; null turns the timer off. From PiliNara's 定时关闭.
  void setSleepTimer(Duration? after, {bool afterCurrent = false}) {
    _sleepTimer?.cancel();
    _sleepTimer = after == null ? null : Timer(after, () {
      unawaited(player?.pause());
      _update(() => sleepAt = null);
      _notice(tr('定时关闭：已暂停播放'));
    });
    _update(() {
      sleepAt = after == null ? null : DateTime.now().add(after);
      sleepAfterCurrent = afterCurrent;
    });
  }

  bool get hasNext => playQueue.isNotEmpty || upNext.isNotEmpty || relatedItems.isNotEmpty;

  /// Videos played before the current one, the latest last.
  final _played = <VideoItem>[];

  bool get hasPrevious => _played.isNotEmpty || previousInQueue != null;

  /// Plays the video that was playing before this one, or else the one
  /// before it in the list it was opened from.
  Future<void> playPrevious() async {
    if (_played.isEmpty) {
      if (previousInQueue case final previous?) await play(previous);
      return;
    }
    final item = _played.removeLast();
    await play(item);
    // play() noted the video left behind; going back is not a new step.
    if (_played.isNotEmpty && _played.last.id == item.id) _played.removeLast();
  }

  /// yt-dlp's result for the playing video, when it was extracted already
  /// (storyboards and the replay heatmap come from it); null otherwise,
  /// for example when Piped or Invidious played it.
  Future<Map<String, dynamic>?> playingInfo() async {
    final id = playing?.id;
    final cached = id == null ? null : _repository?.streams.cached(id);
    if (cached == null) return null;
    try {
      return (await cached).info;
    } catch (_) {
      return null;
    }
  }

  /// Related videos that pass the content filters.
  List<VideoItem> get relatedItems => visible(related?.items ?? const []);

  /// Seeks by [offset], staying inside the video.
  Future<void> seekBy(Duration offset) async {
    final player = this.player;
    if (player == null) return;
    var target = player.state.position + offset;
    final duration = player.state.duration;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await player.seek(target);
  }

  Future<void> changeVolume(double delta) async {
    final player = this.player;
    if (player != null) await player.setVolume((player.state.volume + delta).clamp(0.0, settings.volumeMax.toDouble()).toDouble());
  }

  Future<void> toggleMute() async {
    final player = this.player;
    if (player == null) return;
    final volume = player.state.volume;
    if (volume > 0) {
      _volumeBeforeMute = volume;
      await player.setVolume(0);
    } else {
      await player.setVolume(_volumeBeforeMute);
    }
  }

  /// Saves the quality limit and reloads the current video where it was.
  Future<void> setMaxHeight(int height) async {
    if (height == settings.maxHeight) return;
    await reloadVideo(settings.copyWith(maxHeight: height));
  }

  /// Saves [next], if given, and reopens the current video where it was,
  /// so format choices take effect at once.
  Future<void> reloadVideo([PlayerSettings? next]) async {
    if (next != null) await saveSettings(next);
    final item = playing;
    final player = this.player;
    if (item == null || player == null) return;
    final position = player.state.position;
    final wasPlaying = player.state.playing;
    _update(() => playbackError = null);
    if (await _open(item, _playSerial, start: position) && !wasPlaying) await player.pause();
  }

  Future<void> setAutoplayNext(bool value) => setPlayOrder(value ? PlayOrder.autoPlayRelated : PlayOrder.pause);

  Future<void> setPlayOrder(PlayOrder order) => saveSettings(settings.copyWith(playOrder: order));

  /// The audio outputs libmpv reports, "auto" first.
  List<AudioDevice> get audioDevices => player?.state.audioDevices ?? const [];

  String get _format => FormatPolicy.expression(_playback);

  String? get _formatSort => FormatPolicy.formatSort(_playback);

  /// [settings] as playback picks streams with them: automatic quality is
  /// capped at the tallest display.
  PlayerSettings get _playback => FormatPolicy.forDisplay(settings, _displayHeight);

  int get _displayHeight {
    var tallest = 0.0;
    for (final display in PlatformDispatcher.instance.displays) {
      tallest = max(tallest, display.size.height);
    }
    return tallest.round();
  }

  /// Starts resolving [item] before it is opened, such as when the pointer
  /// rests on its card.
  void prefetch(VideoItem item) {
    if (ready && playing?.id != item.id && DateTime.now().isAfter(_rateLimitedUntil)) _repository?.streams.prefetch(item.id, _format, formatSort: _formatSort);
  }

  Future<void> _loadDetails(VideoItem item, int serial) async {
    try {
      VideoDetails loaded;
      final local = downloads?.localVideo(item.id);
      if (local != null && local.info['title'] != null) {
        // Saved with the download, so the page works offline.
        loaded = VideoDetails.fromJson(local.info);
      } else {
        try {
          // The extraction playback uses carries the details too.
          final resolved = await _repository!.streams.resolve(item.id, _format, formatSort: _formatSort);
          loaded = resolved.details;
          if (serial == _playSerial) _update(() => availableHeights = resolved.heightsFor(settings));
        } catch (_) {
          loaded = await _repository!.details(item.id);
        }
      }
      if (serial == _playSerial) {
        _update(() {
          details = loaded;
          if (preferences.showRelated) related = _relatedTo(item, loaded.title.isNotEmpty ? loaded.title : item.title);
        });
        unawaited(_localizeDetails(item.id, serial));
      }
    } catch (_) {
      // The page still shows what the list already knew about the video.
    } finally {
      if (serial == _playSerial) _update(() => loadingDetails = false);
    }
  }

  /// yt-dlp asks YouTube in English, as it reads view counts and dates
  /// only in English; the title, description and chapter names are then
  /// fetched again in the interface language.
  Future<void> _localizeDetails(String videoId, int serial) async {
    final text = await relatedVideos.textFor(videoId);
    final current = details;
    if (text == null || current == null || serial != _playSerial) return;
    _update(() => details = current.localized(text.title, text.description, likes: text.likes));
  }

  VideoListLoader _relatedTo(VideoItem item, String title) {
    final repository = _repository!;
    // Long titles make poor queries; the first words carry the topic.
    final query = title.length > 60 ? title.substring(0, 60) : title;
    final loader = VideoListLoader(
      () => repository.search(query, filter: SearchFilter.videos),
      pageSize: 13,
      limit: 12,
      where: (other) => other.id != item.id && !preferences.blocksGroup(other) && !preferences.isUnrecommended(other.channelId),
    )..addListener(notifyListeners);
    loader.loadMore();
    return loader;
  }

  /// The channel of the playing video, once known.
  ChannelRef? get playingChannel {
    final item = playing;
    if (item == null) return null;
    final id = details?.channelId;
    if (id != null) return ChannelRef(id, details!.channel.isNotEmpty ? details!.channel : item.channel);
    return item.channelRef;
  }

  /// Videos after the current one in the queue, or the whole queue when the
  /// current video was opened from elsewhere.
  List<VideoItem> get upNext {
    final current = playing;
    if (current == null) return const [];
    final index = queue.indexWhere((item) => item.id == current.id);
    return index < 0 ? queue : queue.sublist(index + 1);
  }

  /// Stops the video and closes the watch page or the mini player.
  void stopWatching() {
    _stopCurrentChat();
    setPip(false);
    _finishWatching();
    _saveProgress(now: true);
    _tracking = null;
    _recoveryTimer?.cancel();
    _recovery.reset();
    ++_playSerial;
    _update(() {
      playing = null;
      mini = false;
      playbackError = null;
    });
    _unload();
  }

  /// Closes the video in libmpv rather than pausing it, so its cache,
  /// decoded frames and textures are freed, then hands the freed memory back
  /// to Windows. Coming back to the video opens it again where it was left.
  void _unload() {
    final player = this.player;
    if (player == null) return;
    unawaited(player.stop().then((_) => releaseMemory()));
  }

  /// Hands memory freed by closed videos back to Windows.
  void releaseMemory() {
    if (!Platform.isWindows) return;
    final before = ProcessInfo.currentRss;
    releaseFreedMemory();
    logInfo('已释放空闲内存：${before >> 20} MB → ${ProcessInfo.currentRss >> 20} MB');
  }

  /// Opens [target]; 返回 comes back to where this was.
  void navigate(PageMode target) {
    if (target != mode || onWatchPage) _remember();
    _go(target);
  }

  void _go(PageMode target) {
    setPip(false);
    final keep = _keepsPlaying;
    if (!keep) {
      if (playing != null) _finishWatching();
      _tracking = null;
      _recoveryTimer?.cancel();
      _recovery.reset();
      ++_playSerial;
    }
    if (target == PageMode.home) unawaited(refreshHomeFeed());
    _saveProgress(now: true);
    if (target == PageMode.subscriptions && preferences.feedAutoRefresh) {
      unawaited(library?.refreshFeed(interval: Duration(minutes: preferences.feedRefreshMinutes)));
    }
    _update(() {
      mode = target;
      if (keep) {
        mini = true;
      } else {
        playing = null;
        playbackError = null;
      }
    });
    if (!keep) _unload();
  }

  /// What is on screen now, as 返回 would come back to it.
  BackEntry get _here {
    final video = playing;
    if (video != null && !mini) {
      final state = player?.state;
      // A video that had finished starts over rather than ending again.
      final ended = state == null || (state.duration > Duration.zero && state.position > state.duration - const Duration(seconds: 5));
      return BackEntry.video(video, mode: mode, position: ended ? null : state.position, queue: queue);
    }
    return BackEntry.page(mode, query: _query, channel: channel, channelTab: channelTab, playlistId: openPlaylistId, youtubePlaylist: youtubePlaylist);
  }

  void _remember() {
    if (!_restoring && ready) _back.push(_here);
  }

  /// Whether 返回 has somewhere to go.
  bool get canGoBack => !_back.isEmpty || onWatchPage || _query != null || mode != PageMode.home || channelQuery != null;

  /// Goes back to the previous page or video: a search inside a channel is
  /// cleared first; with nothing earlier it closes the video, then the
  /// search, then goes home.
  void goBack() {
    if (!onWatchPage && mode == PageMode.channel && channelQuery != null) return searchChannel('');
    BackEntry? entry;
    do {
      entry = _back.pop();
    } while (entry != null && !onWatchPage && entry.same(_here));
    _restoring = true;
    try {
      if (entry != null) {
        _restore(entry);
      } else if (onWatchPage) {
        // Nothing earlier: leave the watch page for the page under it.
        _go(mode);
      } else if (_query != null) {
        clearSearch();
      } else if (mode != PageMode.home) {
        _go(PageMode.home);
      }
    } finally {
      _restoring = false;
    }
  }

  void _restore(BackEntry entry) {
    final video = entry.video;
    if (video != null) {
      if (mini && playing?.id == video.id) return expandMini();
      unawaited(play(video, from: entry.queue.isEmpty ? null : entry.queue, at: entry.position));
      return;
    }
    switch (entry.mode) {
      case PageMode.explore:
        final query = entry.query;
        if (query == null) {
          openExplore();
        } else if (query == _query) {
          _go(PageMode.explore);
        } else {
          unawaited(search(query));
        }
      case PageMode.channel:
        final ref = entry.channel;
        if (ref == null) return _go(PageMode.home);
        if (ref.id != channel?.id) {
          openChannel(ref);
        } else {
          _go(PageMode.channel);
        }
        if (entry.channelTab != channelTab) setChannelTab(entry.channelTab);
      case PageMode.youtubePlaylist:
        final playlist = entry.youtubePlaylist;
        if (playlist == null) return _go(PageMode.home);
        if (playlist.id != youtubePlaylist?.id) {
          openYoutubePlaylist(playlist);
        } else {
          _go(PageMode.youtubePlaylist);
        }
      case PageMode.playlist:
        final id = entry.playlistId;
        if (id == null) return _go(PageMode.home);
        openPlaylist(id);
      case final mode:
        _go(mode);
    }
  }

  /// Opens [ref]'s page with its uploads.
  void openChannel(ChannelRef ref) {
    final repository = _repository;
    if (repository == null) return;
    _remember();
    channelVideos?.dispose();
    channelPosts?.dispose();
    channelPosts = null;
    channel = ref;
    channelQuery = null;
    channelTab = ChannelTab.videos;
    channelVideos = VideoListLoader(() => repository.channelVideos(ref))
      ..addListener(notifyListeners)
      ..loadMore();
    _go(PageMode.channel);
  }

  /// Shows another tab of the open channel.
  void setChannelTab(ChannelTab tab) {
    final repository = _repository;
    final ref = channel;
    if (repository == null || ref == null) return;
    _update(() {
      channelTab = tab;
      channelQuery = null;
      channelVideos?.dispose();
      channelVideos = null;
      channelPosts?.dispose();
      channelPosts = null;
      if (tab == ChannelTab.posts) {
        channelPosts = PostsLoader(_posts, ref)..addListener(notifyListeners);
        unawaited(channelPosts!.loadMore());
      } else {
        channelVideos = VideoListLoader(() => repository.channelTab(ref, tab))
          ..addListener(notifyListeners)
          ..loadMore();
      }
    });
  }

  /// Opens a YouTube playlist's page.
  void openYoutubePlaylist(PlaylistResult playlist) {
    final repository = _repository;
    if (repository == null) return;
    _remember();
    youtubePlaylistVideos?.dispose();
    youtubePlaylist = playlist;
    youtubePlaylistVideos = VideoListLoader(() => repository.playlist(playlist.id), pageSize: 50)
      ..addListener(notifyListeners)
      ..loadMore();
    _go(PageMode.youtubePlaylist);
  }

  /// Searches the open channel's videos for [query]; an empty query lists
  /// the uploads again.
  /// What a search inside the channel covers: null for YouTube's own
  /// channel search, else one tab whose titles are filtered.
  ChannelTab? channelSearchTab;

  /// Searches the open channel; an empty [query] lists the tab again.
  void searchChannel(String query, {ChannelTab? within}) {
    final repository = _repository;
    final ref = channel;
    if (repository == null || ref == null) return;
    final text = query.trim();
    _update(() {
      channelVideos?.dispose();
      channelVideos = null;
      channelPosts?.dispose();
      channelPosts = null;
      channelQuery = text.isEmpty ? null : text;
      channelSearchTab = text.isEmpty ? null : within;
      if (text.isEmpty) {
        // Back to the tab that was open.
        if (channelTab == ChannelTab.posts) {
          channelPosts = PostsLoader(_posts, ref)..addListener(notifyListeners);
          unawaited(channelPosts!.loadMore());
        } else {
          final tab = channelTab;
          channelVideos = VideoListLoader(() => repository.channelTab(ref, tab))
            ..addListener(notifyListeners)
            ..loadMore();
        }
        return;
      }
      final words = text.toLowerCase().split(RegExp(r'\s+'));
      bool matches(String title) {
        final lower = title.toLowerCase();
        return words.every(lower.contains);
      }

      if (within == ChannelTab.posts) {
        channelPosts = PostsLoader(_posts, ref, matches: matches)..addListener(notifyListeners);
        unawaited(channelPosts!.loadMore());
      } else {
        channelVideos = (within == null
            ? VideoListLoader(() => repository.channelSearch(ref, text))
            : VideoListLoader(() => repository.channelTab(ref, within), matches: matches))
          ..addListener(notifyListeners)
          ..loadMore();
      }
    });
  }

  void openPlaylist(String id) {
    _remember();
    openPlaylistId = id;
    _go(PageMode.playlist);
  }

  void retrySearch() {
    final last = _query;
    if (last != null) unawaited(search(last));
  }

  SearchSort searchSort = SearchSort.relevance;
  SearchUploadDate searchDate = SearchUploadDate.any;
  SearchDuration searchDuration = SearchDuration.any;

  /// Searches again with another order, upload date or length.
  void setSearchOptions({SearchSort? sort, SearchUploadDate? date, SearchDuration? duration}) {
    searchSort = sort ?? searchSort;
    searchDate = date ?? searchDate;
    searchDuration = duration ?? searchDuration;
    retrySearch();
  }

  /// 为你推荐 on the home page.
  HomeFeed? homeFeed;
  late final relatedVideos = YoutubeRelated(_http);

  /// Gathers recommendations again when they are old, or when [force]d.
  Future<void> refreshHomeFeed({bool force = false}) async {
    final feed = homeFeed;
    final repository = _repository;
    final library = this.library;
    if (feed == null || repository == null || !preferences.homeShowRecommended || feed.loading) return;
    if (!force && !feed.stale && feed.items.isNotEmpty) return;
    // The last launch's feed shows while a new one is gathered.
    await feed.restore(filter: visible);
    if (library != null && library.channels.isNotEmpty && library.feed.isEmpty) {
      await library.refreshFeed().timeout(const Duration(seconds: 20), onTimeout: () {});
    }
    feed.mix = preferences.feedMix;
    await feed.refresh(await _homeSources(repository), filter: visible);
  }

  /// The next page of 为你推荐, as the home page scrolls to its end.
  Future<void> loadMoreHomeFeed() async => homeFeed?.loadMore();

  /// The video being watched, to learn from once it is left.
  VideoItem? _watching;

  /// Tells 为你推荐 about the video just left: watched a while, it steers
  /// what comes next; left within seconds, it counts against its channel.
  void _finishWatching() {
    final item = _watching;
    _watching = null;
    final feed = homeFeed;
    final repository = _repository;
    final player = this.player;
    if (item == null || feed == null || repository == null || player == null || !preferences.homeShowRecommended) return;
    final position = player.state.position;
    final duration = player.state.duration;
    final fraction = duration > Duration.zero ? position.inMilliseconds / duration.inMilliseconds : 0.0;
    final skipped = position < const Duration(seconds: 15) && fraction < 0.1;
    if (!skipped && position < const Duration(seconds: 30) && fraction < 0.3) return;
    unawaited(() async {
      await feed.learn(item, await _homeSources(repository), skipped: skipped);
    }());
  }

  Future<HomeFeedSources> _homeSources(VideoRepository repository) async {
    final library = this.library;
    final weekly = searchParams(type: SearchFilter.videos, sort: SearchSort.views, date: SearchUploadDate.week);
    return HomeFeedSources(
        history: history,
        progressOf: library?.progressOf,
        favorites: [...?library?.favorites, ...?account?.likedVideos.take(50)],
        followed: library?.channels ?? const [],
        subscriptions: library?.feed ?? const [],
        searches: preferences.recordHistory ? await searchHistory?.items() ?? const [] : const [],
        related: relatedVideos.forVideo,
        channelUploads: library?.uploadsOf ?? (_) async => const [],
        search: (query) async {
          final listing = repository.search(query, sp: weekly);
          try {
            return (await listing.next(10).toList()).whereType<VideoItem>().toList();
          } finally {
            listing.close();
          }
        },
      );
  }

  /// Follows or unfollows [channel] here, and on YouTube when signed in
  /// and [AppPreferences.syncFollowToYoutube]. Returns whether it is
  /// followed now.
  bool toggleFollow(ChannelRef channel) {
    final library = this.library;
    if (library == null) return false;
    final following = library.toggleFollow(channel);
    final account = this.account;
    if (account != null && account.canWrite && preferences.syncFollowToYoutube) unawaited(account.setSubscribed(channel, following));
    return following;
  }

  /// 换一批.
  void shuffleHomeFeed() {
    homeFeed?.mix = preferences.feedMix;
    homeFeed?.shuffle(filter: visible);
  }

  /// 不感兴趣: hides [item] and shows less from its channel.
  Future<void> dismissRecommendation(VideoItem item) async {
    await homeFeed?.dismiss(item);
    _notice(tr('将减少推荐类似内容'));
  }

  Future<void> clearNotInterested() async {
    await homeFeed?.notInterested.clear();
    _notice(tr('已清空“不感兴趣”记录'));
  }

  /// Words typed before, newest first, and YouTube's suggestions.
  SearchHistory? searchHistory;
  late final searchSuggestions = SearchSuggestions(_http);

  /// Shows the current search's results of another kind.
  void setSearchFilter(SearchFilter filter) {
    final last = _query;
    if (last != null && filter != searchFilter) unawaited(search(last, filter: filter));
  }

  Future<void> clearSearchHistory() async {
    await searchHistory?.clear();
    _notice(tr('搜索记录已清空。'));
  }

  /// Forgets the videos with these [ids] from the watch history.
  Future<void> removeFromHistory(Set<String> ids) async {
    await _history?.remove(ids);
    _update(() {});
  }

  Future<void> clearHistory() async {
    await _history?.clear();
    _update(() {});
    _notice(tr('观看历史已清空。'));
  }

  /// Videos of [items] that pass the privacy and content filters. The
  /// subscriptions feed is filtered only when [AppPreferences.filterSubscriptions].
  List<VideoItem> visible(List<VideoItem> items, {bool subscriptions = false, bool search = false}) {
    final prefs = preferences;
    if (subscriptions && !prefs.filterSubscriptions) return items.where((item) => !prefs.isBlocked(item.channelId)).toList();
    final library = this.library;
    // Blocked groups show in a search only for their channel's exact name,
    // channels not to recommend in any search; followed channels are the
    // user's choice and stay.
    bool hidden(VideoItem item) =>
        !subscriptions &&
        ((prefs.blocksGroup(item) && !(search && isExactName(item.channel, _query))) || (!search && prefs.isUnrecommended(item.channelId)));
    return items.where((item) => !hidden(item) && prefs.shows(item, watched: library?.progressOf(item.id)?.finished ?? false)).toList();
  }

  Future<void> savePreferences(AppPreferences next) async {
    _update(() => preferences = next);
    try {
      await _preferencesStore?.save(next);
    } on FileSystemException {
      _notice(tr('设置未能保存，本次运行仍然生效。'));
    }
  }

  void blockChannel(ChannelRef channel) {
    if (preferences.isBlocked(channel.id)) return;
    unawaited(savePreferences(preferences.copyWith(blockedChannels: [...preferences.blockedChannels, channel])));
    _notice(tr('已屏蔽“{0}”，可在 设置 › 隐私设置 中解除', [channel.name.isEmpty ? channel.id : channel.name]));
  }

  /// Blocks a channel the user typed in: a link or id with its `UC…` id,
  /// else its exact name. Returns what was blocked, or null if nothing.
  String? blockChannelTyped(String text) {
    final typed = text.trim();
    if (typed.isEmpty) return null;
    final id = RegExp(r'UC[\w-]{22}').firstMatch(typed)?[0];
    if (id != null) {
      if (!preferences.isBlocked(id)) unawaited(savePreferences(preferences.copyWith(blockedChannels: [...preferences.blockedChannels, ChannelRef(id, '')])));
      return id;
    }
    if (!preferences.isBlockedName(typed)) unawaited(savePreferences(preferences.copyWith(blockedChannelNames: [...preferences.blockedChannelNames, typed])));
    return typed;
  }

  void unblockChannelName(String name) =>
      unawaited(savePreferences(preferences.copyWith(blockedChannelNames: preferences.blockedChannelNames.where((n) => n != name).toList())));

  /// Stops or resumes recommending [channel]'s videos.
  void setRecommendChannel(ChannelRef channel, bool recommend) {
    final rest = preferences.unrecommendedChannels.where((c) => c.id != channel.id).toList();
    unawaited(savePreferences(preferences.copyWith(unrecommendedChannels: recommend ? rest : [...rest, channel])));
    final name = channel.name.isEmpty ? channel.id : channel.name;
    _notice(recommend ? tr('已恢复推荐“{0}”', [name]) : tr('不再推荐“{0}”的视频，搜索和关注不受影响', [name]));
  }

  void unblockChannel(String id) =>
      unawaited(savePreferences(preferences.copyWith(blockedChannels: preferences.blockedChannels.where((c) => c.id != id).toList())));

  void clearProgress() {
    library?.clearProgress();
    _notice(tr('播放进度已清空。'));
  }

  /// Reads the Windows accent colour for [AppearanceSettings.systemAccent].
  Future<void> refreshWindowsAccent() async {
    final color = await readWindowsAccent();
    if (color != null && color != windowsAccent) _update(() => windowsAccent = color);
  }

  /// Settings as one JSON document, for backup. Values that belong to this
  /// computer (cache folder, audio output, decoder results) are left out.
  String exportSettings() => const JsonEncoder.withIndent('  ').convert({
        'app': 'Lumtub',
        'version': 1,
        'exported': DateTime.now().toIso8601String(),
        'player': settings.toJson()
          ..remove('cachePath')
          ..remove('cacheLimitGb')
          ..remove('audioDevice')
          ..remove('decoderResults'),
        'appearance': appearance.toJson(),
        'preferences': preferences.toJson(),
      });

  /// Applies settings exported by [exportSettings]; false when [text] is not
  /// such a file. This computer's own values are kept.
  Future<bool> importSettings(String text) async {
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      return false;
    }
    if (data is! Map || (data['app'] != 'Lumtub' && data['app'] != 'YTPlus')) return false;
    final player = PlayerSettings.fromJson(data['player']).copyWith(
      cachePath: settings.cachePath,
      clearCachePath: settings.cachePath == null,
      cacheLimitGb: settings.cacheLimitGb,
      clearCacheLimit: settings.cacheLimitGb == null,
      audioDevice: settings.audioDevice,
      decoderResults: settings.decoderResults,
    );
    await saveSettings(player);
    await saveAppearance(AppearanceSettings.fromJson(data['appearance']));
    await savePreferences(AppPreferences.fromJson(data['preferences']));
    logInfo('已导入设置');
    return true;
  }

  /// Restores every default except this computer's cache folder and
  /// decoder results.
  Future<void> resetSettings() async {
    await saveSettings(PlayerSettings(cachePath: settings.cachePath, cacheLimitGb: settings.cacheLimitGb, decoderResults: settings.decoderResults));
    await saveAppearance(const AppearanceSettings());
    await savePreferences(const AppPreferences());
    _notice(tr('已恢复默认设置。'));
  }

  Future<void> saveAppearance(AppearanceSettings next) async {
    _applyAppearanceGlobals(next);
    if (next.systemAccent && windowsAccent == null) unawaited(refreshWindowsAccent());
    _update(() => appearance = next);
    // The text size slider saves at every step; only the last one is written.
    _appearanceSaveTimer?.cancel();
    _appearanceSaveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_writeAppearance()));
  }

  Timer? _appearanceSaveTimer;

  /// Writes the appearance now if a save is still waiting for its delay.
  Future<void> _flushAppearance() async {
    if (!(_appearanceSaveTimer?.isActive ?? false)) return;
    _appearanceSaveTimer!.cancel();
    await _writeAppearance();
  }

  Future<void> _writeAppearance() async {
    try {
      await _appearanceStore?.save(appearance);
    } on FileSystemException {
      _notice(tr('外观设置未能保存，本次运行仍然生效。'));
    }
  }

  ToolManager? get tools => _tools;

  /// Goes back to the libmpv shipped with Lumtub from the next launch on.
  Future<void> rollBackLibmpv() async {
    await _tools?.libmpv.rollBack();
    _update(() {});
    _notice(tr('已改回内置 libmpv，重启 Lumtub 后生效。'));
  }

  Future<void> rollBackYtDlp() async {
    await _tools?.rollBackYtDlp();
    _update(() {});
    _notice(tr('已改回上一个 yt-dlp，重启 Lumtub 后生效。'));
  }

  /// Download progress (0..1, null when unknown) while ffmpeg installs.
  double? ffmpegProgress;
  bool installingFfmpeg = false;

  /// Whether ffmpeg is there, so downloads can merge video and audio.
  bool get ffmpegInstalled => downloads?.canMerge ?? false;

  /// Whether starting a download in [quality] merges, goes single-file or
  /// needs to ask about installing ffmpeg first.
  FfmpegChoice ffmpegChoice(DownloadQuality quality) =>
      ffmpegChoiceFor(quality, installed: ffmpegInstalled, declined: preferences.skipFfmpegPrompt);

  /// Remembers that the user wants single-file downloads without being asked.
  Future<void> declineFfmpegPrompt() => savePreferences(preferences.copyWith(skipFfmpegPrompt: true));

  /// The size of the ffmpeg download in bytes, or null when unknown.
  Future<int?> ffmpegDownloadSize() async {
    try {
      return await _tools?.ffmpegDownloadSize();
    } catch (_) {
      return null;
    }
  }

  /// Installs or updates ffmpeg; true when it is usable afterwards.
  Future<bool> installFfmpeg() async {
    final tools = _tools;
    if (tools == null || installingFfmpeg) return false;
    _update(() {
      installingFfmpeg = true;
      ffmpegProgress = null;
    });
    try {
      await tools.installFfmpeg(onProgress: (received, total) {
        final fraction = total == null || total == 0 ? null : received / total;
        if (fraction == null || fraction - (ffmpegProgress ?? 0) >= 0.01) _update(() => ffmpegProgress = fraction);
      });
      if (preferences.skipFfmpegPrompt) await savePreferences(preferences.copyWith(skipFfmpegPrompt: false));
      return true;
    } catch (e) {
      logError('ffmpeg 安装失败', e);
      _notice(tr('ffmpeg 安装失败：{0}', [e]));
      return false;
    } finally {
      _update(() => installingFfmpeg = false);
    }
  }

  Future<void> removeFfmpeg() async {
    try {
      await _tools?.removeFfmpeg();
    } on FileSystemException catch (e) {
      _notice(tr('无法删除 ffmpeg（可能正在使用）：{0}', [e.message]));
    }
    _update(() {});
  }

  Future<void> checkUpdates() async {
    if (checking || _tools == null) return;
    _update(() => checking = true);
    try {
      await _tools!.checkUpdates(force: true);
    } finally {
      _update(() => checking = false);
    }
  }

  Future<void> saveSettings(PlayerSettings next) async {
    final store = _settingsStore;
    final player = this.player;
    if (store == null || player == null) return;
    final oldSettings = settings;
    final requiresNextVideo = next.hwdec != oldSettings.hwdec || next.interpolation != oldSettings.interpolation;
    final ignoredOptions = await PlayerOptionApplicator.apply(player, next);
    await store.save(next);
    _update(() => settings = next);
    if (next.proxyMode != oldSettings.proxyMode || next.proxyAddress != oldSettings.proxyAddress) await _refreshProxy();
    _update(() {
      final paths = this.paths;
      final cacheManager = _cacheManager;
      if (paths != null && cacheManager != null && next.cachePath != oldSettings.cachePath) {
        _repository = _repositoryFor(paths, cacheManager, next);
        library?.repository = _repository;
      }
      status = ignoredOptions.isEmpty
          ? tr('播放器设置已保存{0}', [requiresNextVideo ? tr('；硬件解码和帧插值在下一段视频生效。') : '。'])
          : tr('已保存；此 libmpv 不支持：{0}。', [ignoredOptions.join(', ')]);
    });
  }

  /// Sets one libmpv property without saving, for live previews such as
  /// the picture sliders.
  Future<void> previewProperty(String name, String value) async {
    final platform = player?.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(name, value);
    } catch (_) {
      // A preview that libmpv rejects changes nothing.
    }
  }

  Future<void> inspectCurrentDecoder({Duration delay = Duration.zero}) async {
    final platform = player?.platform;
    if (platform is! NativePlayer) {
      _notice(tr('当前播放器无法读取 libmpv 解码状态。'));
      return;
    }
    try {
      await Future<void>.delayed(delay);
      final codec = (await platform.getProperty('video-codec')).trim().toLowerCase();
      final decoder = DecoderStatus.fromMpv(await platform.getProperty('hwdec-current'));
      final normalized = DecoderStatus.codecKey(codec);
      _update(() {
        currentCodec = codec.isEmpty ? tr('尚未验证') : codec;
        currentHwdec = decoder.label;
        if (normalized != null) decodeStates = {...decodeStates, normalized: decoder};
      });
      if (normalized != null) {
        settings = settings.copyWith(decoderResults: decodeStates);
        unawaited(_settingsStore?.save(settings));
      }
      // A download older than its codec in the sidecar: only libmpv can
      // tell it is in a codec the playback rules disable.
      final item = playing;
      final fileCodec = VideoCodec.of(normalized);
      if (item != null && _openedLocal == item.id && !FormatPolicy.allows(settings, fileCodec)) {
        logInfo('${item.id} 的下载文件是 ${fileCodec!.label}，播放规则已禁用该编码，改为在线播放');
        _notice(tr('下载的文件是 {0} 编码，已按播放规则改为在线播放', [fileCodec.label]));
        unawaited(_open(item, _playSerial, start: player?.state.position, allowLocal: false));
      }
    } catch (_) {
      _update(() => currentHwdec = tr('尚未验证'));
    }
  }

  /// Logs playback timing when frames are being dropped, at most once a
  /// minute, so the log shows why a video stutters.
  Future<void> _checkDrops() async {
    final platform = player?.platform;
    if (platform is! NativePlayer || _tracking == null || !(player?.state.playing ?? false)) return;
    await _logMemory(platform);
    try {
      final drops = int.tryParse(await platform.getProperty('frame-drop-count')) ?? 0;
      final added = drops - _lastDrops;
      _lastDrops = drops;
      if (added < 20 || DateTime.now().difference(_lastDropLog) < const Duration(minutes: 1)) return;
      _lastDropLog = DateTime.now();
      final values = <String>[];
      for (final name in ['avsync', 'estimated-vf-fps', 'container-fps', 'display-fps', 'vo-delayed-frame-count', 'mistimed-frame-count', 'decoder-frame-drop-count', 'hwdec-current', 'video-sync', 'speed', 'video-params/w', 'video-params/h', 'time-pos', 'audio-pts', 'audio-params/samplerate', 'audio-out-params/samplerate', 'current-ao', 'd3d11va-zero-copy', 'vd-lavc-dr', 'video-codec', 'video-out-params/pixelformat']) {
        values.add('$name=${await platform.getProperty(name)}');
      }
      logInfo('10 秒内丢帧 $added（共 $drops）：${values.join(' ')}');
    } catch (_) {
      // Statistics are best effort.
    }
  }

  DateTime _lastMemoryLog = DateTime(0);

  /// Logs the app's memory and what libmpv's cache holds every two minutes
  /// while a video plays, so the log shows where memory goes.
  Future<void> _logMemory(NativePlayer platform) async {
    if (DateTime.now().difference(_lastMemoryLog) < const Duration(minutes: 2)) return;
    _lastMemoryLog = DateTime.now();
    try {
      String mb(Object? bytes) => bytes is num ? '${(bytes / (1 << 20)).round()} MB' : '?';
      final cache = jsonDecode(await platform.getProperty('demuxer-cache-state'));
      final ahead = cache is Map ? cache['fw-bytes'] : null;
      final total = cache is Map ? cache['total-bytes'] : null;
      final values = <String>[];
      for (final name in ['video-params/w', 'video-params/h', 'video-codec', 'hwdec-current', 'video-out-params/pixelformat']) {
        values.add('$name=${await platform.getProperty(name)}');
      }
      logInfo('内存：进程 ${mb(ProcessInfo.currentRss)}（峰值 ${mb(ProcessInfo.maxRss)}）· 播放缓存 ${mb(total)}（前方 ${mb(ahead)}）· 图片缓存 ${mb(PaintingBinding.instance.imageCache.currentSizeBytes)} · ${values.join(' ')}');
    } catch (_) {
      // Statistics are best effort.
    }
  }

  Future<void> _readWindowsVideoInfo() async {
    final info = await WindowsVideoInfo.read();
    _update(() => windowsVideoInfo = info);
  }

  /// Reads optional Windows Media Foundation codec extensions only when the
  /// decoder-status settings section is opened. libmpv itself does not use
  /// these extensions.
  void refreshWindowsVideoInfo() => unawaited(_readWindowsVideoInfo());

  Future<void> openStore(String url) async {
    try {
      await Process.start('explorer.exe', [url]);
    } catch (_) {
      _notice(tr('无法打开 Microsoft Store 链接。'));
    }
  }

  /// Moves the managed cache under [selectedFolder]. [confirmMigrate] asks
  /// whether existing cache folders should move with it.
  Future<void> changeCacheLocation(String selectedFolder, Future<bool?> Function(String targetPath) confirmMigrate) async {
    final manager = _cacheManager;
    if (directories == null || manager == null) return;
    final target = Directory('$selectedFolder${Platform.pathSeparator}LumtubCache');
    final next = settings.copyWith(cachePath: target.path);
    try {
      await manager.prepare(next);
      final migrate = await confirmMigrate(target.path);
      // The old folders are deleted only after the new location is saved.
      if (migrate == true) {
        await manager.migrate(settings, next, commit: () => saveSettings(next));
      } else {
        await saveSettings(next);
      }
      _update(() => cacheBytes = 0);
      _notice(tr('缓存位置已保存。yt-dlp 缓存在下一次搜索时使用新位置。'));
    } on FileSystemException catch (error) {
      _notice(tr('新缓存位置不可用，继续使用原位置：{0}', [error.message]));
    }
  }

  bool ensureNotPlaying(String message) {
    if (playing == null) return true;
    _notice(message);
    return false;
  }

  Future<void> clearCache() async {
    final manager = _cacheManager;
    if (manager == null) return;
    if (!ensureNotPlaying(tr('正在播放时不会清理缓存。请先返回列表。'))) return;
    try {
      final (:freed, :skipped) = await manager.clear(settings);
      final left = await manager.size(settings);
      _update(() => cacheBytes = left);
      _notice(skipped == 0
          ? tr('已清理 {0} 缓存。', [formatBytes(freed)])
          : tr('已清理 {0} 缓存；{1} 个文件正被使用，留到下次。', [formatBytes(freed), skipped]));
    } on FileSystemException catch (error) {
      logError('清理缓存失败', error);
      _notice(tr('清理缓存失败：{0}', [error.message]));
    }
  }

  /// Saves everything and releases the player before the window closes;
  /// dispose() alone does not run when Windows ends the process.
  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    _saveProgress();
    await library?.flush();
    await downloads?.flush();
    await _flushAppearance();
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    _playerSubscriptions.clear();
    _stallTimer?.cancel();
    _recoveryTimer?.cancel();
    await player?.pause();
    await player?.dispose();
    logInfo('Lumtub 正常退出');
    await AppLog.current?.flush();
  }

  /// A summary for bug reports; it names no account, video or file
  /// contents, only versions and settings.
  String diagnostics() {
    final tools = _tools;
    return [
      'Lumtub $appVersion',
      'Windows ${Platform.operatingSystemVersion}',
      tr('CPU 核心 {0}', [Platform.numberOfProcessors]),
      'GPU ${windowsVideoInfo.gpuNames.isEmpty ? '未知' : windowsVideoInfo.gpuNames.join(' / ')}',
      'libmpv ${tools?.libmpv.current?.label ?? '内置'}',
      'yt-dlp ${tools?.ytDlpVersion ?? '未安装'}',
      'Deno ${tools?.denoVersion ?? '未安装'}',
      tr('硬件解码设置 {0} · 当前 {1} · {2}', [settings.hwdec, currentCodec, currentHwdec]),
      tr('画质上限 {0} · 播放策略 {1} · 禁用编码 {2} · 音质 {3}', [settings.maxHeight == 0 ? tr('自动') : '${settings.maxHeight}p', settings.strategy.label, FormatPolicy.disabledNames(settings).isEmpty ? tr('无') : FormatPolicy.disabledNames(settings), settings.audioQuality.label]),
      tr('缓存 {0} · {1} 秒 · {2} MB', [settings.cacheMode, settings.cacheSeconds, settings.cacheMemoryMb]),
      tr('数据目录 {0}', [directories?.root.path ?? tr('未知')]),
    ].join('\n');
  }

  @override
  void dispose() {
    _disposed = true;
    _stopCurrentChat();
    _stallTimer?.cancel();
    _recoveryTimer?.cancel();
    _sleepTimer?.cancel();
    _dropTimer?.cancel();
    unawaited(_flushAppearance());
    _thumbnailTrimTimer?.cancel();
    for (final subscription in _playerSubscriptions) {
      unawaited(subscription.cancel());
    }
    _saveProgress();
    unawaited(_relay?.close());
    unawaited(_bridge?.close());
    cast.dispose();
    account?.dispose();
    downloads?.dispose();
    library?.dispose();
    channelVideos?.dispose();
    searchResults?.dispose();
    explore?.dispose();
    channelPosts?.dispose();
    youtubePlaylistVideos?.dispose();
    related?.dispose();
    _http.close();
    if (!_shutDown) unawaited(player?.dispose());
    _tools?.dispose();
    unawaited(_notices.close());
    super.dispose();
  }
}
