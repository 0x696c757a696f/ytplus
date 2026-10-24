import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_directories.dart';
import 'live_chat_repository.dart';
import 'models.dart';
import 'process_priority.dart';
import 'process_runner.dart';
import 'stream_resolver.dart';
import 'l10n/l10n.dart';
import 'native_core.dart';

enum SearchFilter {
  all('全部', null),
  videos('视频', 'EgIQAQ%253D%253D'),
  shorts('Shorts', 'EgIQCQ%253D%253D'),
  live('直播', 'EgJAAQ%253D%253D'),
  channels('频道', 'EgIQAg%253D%253D'),
  playlists('播放列表', 'EgIQAw%253D%253D');

  const SearchFilter(this._label, this.sp);
  final String _label;
  String get label => tr(_label);
  /// YouTube's own filter parameter, as its results page URL carries it.
  final String? sp;
}

/// The tabs of a channel page; [path] is the channel URL's tab, null for
/// posts, which yt-dlp does not list.
enum ChannelTab {
  videos('视频', '/videos'),
  shorts('Shorts', '/shorts'),
  live('直播', '/streams'),
  playlists('播放列表', '/playlists'),
  podcasts('播客', '/podcasts'),
  posts('社区', null);

  const ChannelTab(this._label, this.path);
  final String _label;
  String get label => tr(_label);
  final String? path;
}

/// A listing read a page at a time from one source, such as one yt-dlp
/// process. Each page continues where the last stopped, so scrolling through
/// n results costs O(n) instead of re-fetching earlier pages.
class Listing {
  Listing(this._open, {this.channel, this.timeout = const Duration(seconds: 60), this.idleTimeout = const Duration(seconds: 20)});

  final Stream<String> Function() _open;
  /// Filled in on videos, for listings that leave the channel out.
  final ChannelRef? channel;
  final Duration timeout;
  /// How long the source may sit unread before it is closed. A yt-dlp
  /// process waiting for the next page holds ~40 MB, and every list the
  /// user has looked at would keep one; the next page then starts a new
  /// one and skips what was already read.
  final Duration idleTimeout;

  StreamIterator<String>? _lines;
  Timer? _idle;
  /// Lines read from the source so far, kept or not.
  int _read = 0;
  int _found = 0;
  bool _done = false;

  bool get done => _done;

  /// Up to [count] more entries, each a [VideoItem] or [ChannelResult].
  /// Fails when the source ends with an error before listing anything or
  /// stalls; other errors after the first entries end the listing.
  Stream<Object> next(int count) async* {
    if (_done) return;
    _idle?.cancel();
    try {
      var lines = _lines;
      if (lines == null) {
        lines = _lines = StreamIterator(_open());
        // Reopened after going idle: past what was already shown.
        for (var skip = _read; skip > 0; skip--) {
          if (!await _move(lines)) return;
        }
      }
      var taken = 0;
      while (taken < count) {
        if (!await _move(lines)) return;
        _read++;
        var entry = parseListingEntry(lines.current);
        if (entry == null) continue;
        final ref = channel;
        if (entry is VideoItem && ref != null) entry = entry.withChannel(ref);
        _found++;
        taken++;
        yield entry;
      }
    } finally {
      if (!_done) _idle = Timer(idleTimeout, _suspend);
    }
  }

  /// The next line, false at the end; see [next] for which errors fail.
  Future<bool> _move(StreamIterator<String> lines) async {
    final bool more;
    try {
      more = await lines.moveNext().timeout(timeout, onTimeout: () => throw TimeoutException(tr('yt-dlp 加载超时')));
    } catch (e) {
      close();
      if (_found == 0 || e is TimeoutException) rethrow;
      return false;
    }
    if (!more) _done = true;
    return more;
  }

  void _suspend() {
    final lines = _lines;
    _lines = null;
    unawaited(lines?.cancel());
  }

  void close() {
    _done = true;
    _idle?.cancel();
    unawaited(_lines?.cancel());
  }
}

class VideoRepository {
  final String ytDlpPath;
  final String? cacheDirectory;
  /// Deno for YouTube's JavaScript challenges.
  final String? deno;
  /// Put before PATH for yt-dlp, so it finds Deno and ffmpeg even though
  /// [Platform.environment] still holds the PATH from before the app
  /// added them.
  final List<String> toolDirectories;
  /// yt-dlp's `--proxy` value at the time of each call, see
  /// `NetworkProxy.ytDlpValue`.
  final String? Function()? proxy;
  VideoRepository(this.ytDlpPath, {this.cacheDirectory, this.deno, this.toolDirectories = const [], this.proxy});

  List<String> get _proxyArguments {
    final value = proxy?.call();
    return value == null ? const [] : ['--proxy', value];
  }

  /// Resolves videos for playback ahead of libmpv.
  late final StreamResolver streams = StreamResolver(
    ytDlpPath,
    cacheDirectory: cacheDirectory,
    deno: deno,
    proxy: proxy,
    infoDirectory: Directory(cacheDirectory == null
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}lumtub-info'
        : '${cacheDirectory!}${Platform.pathSeparator}..${Platform.pathSeparator}temp${Platform.pathSeparator}info'),
    environment: _environment,
  );

  /// Read-only chat replay, written under this repository's configured cache.
  late final LiveChatRepository liveChat = LiveChatRepository(
    ytDlpPath,
    cacheDirectory: cacheDirectory,
    deno: deno,
    proxy: proxy,
    environment: _environment,
  );

  static const pageSize = 20;

  /// YouTube's results page for [query], which lists channels as well as
  /// videos; `sp` is YouTube's own filter parameter.
  static String searchUrl(String query, {SearchFilter filter = SearchFilter.all, String? sp}) {
    final params = sp ?? filter.sp;
    return 'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(query)}${params == null ? '' : '&sp=$params'}';
  }

  /// yt-dlp arguments that print a listing's entries one per line as they
  /// arrive. `--lazy-playlist` matters: without it yt-dlp collects the whole
  /// listing before printing anything.
  List<String> listingArguments(String url, {String? cookies}) => [
        '--no-warnings',
        '--skip-download',
        if (cacheDirectory != null) ...['--cache-dir', cacheDirectory!],
        if (cookies != null) ...['--cookies', cookies],
        ..._proxyArguments,
        '--extractor-retries', '3',
        '--flat-playlist',
        '--lazy-playlist',
        '--dump-json',
        '--', url,
      ];

  /// Search results; one yt-dlp process serves every page. [region] is
  /// YouTube's country code (`gl`) to search as from, if not the one the
  /// connection gives.
  Listing search(String query, {SearchFilter filter = SearchFilter.all, String? sp, String? region}) {
    final url = searchUrl(query.trim(), filter: filter, sp: sp);
    return region == null || region.isEmpty ? _listing(url) : Listing(() => _regionLines(url, region));
  }

  /// Several searches at once, a few results of each in turn, for a mix
  /// of zones. A search that fails drops out; the mix fails only if all do.
  Listing searchMix(List<String> queries, {String? sp, String? region}) =>
      Listing(() => interleave([for (final q in queries) () => search(q, sp: sp, region: region)._open()]));

  /// Lines from each of [sources] in turn, [run] at a time, each started
  /// only when first read.
  static Stream<String> interleave(List<Stream<String> Function()> sources, {int run = 3}) async* {
    final open = <StreamIterator<String>>[];
    final pending = [...sources];
    Object? lastError;
    var yielded = false;
    var i = 0;
    try {
      while (open.isNotEmpty || pending.isNotEmpty) {
        if (pending.isNotEmpty && i >= open.length) open.add(StreamIterator(pending.removeAt(0)()));
        final lines = open[i];
        var taken = 0;
        var ended = false;
        try {
          while (taken < run) {
            if (!await lines.moveNext()) {
              ended = true;
              break;
            }
            taken++;
            yielded = true;
            yield lines.current;
          }
        } catch (e) {
          lastError = e;
          ended = true;
        }
        if (ended) {
          await lines.cancel();
          open.removeAt(i);
        } else {
          i++;
        }
        if (i >= open.length && pending.isEmpty) i = 0;
      }
      if (!yielded && lastError != null) throw lastError;
    } finally {
      for (final lines in open) {
        await lines.cancel();
      }
    }
  }

  /// YouTube takes the country from the PREF cookie, as its own location
  /// setting saves it. Each process gets a cookie file of its own with
  /// nothing else in it, removed afterwards, so no visitor id is kept.
  Stream<String> _regionLines(String url, String region) async* {
    final directory = Directory(cacheDirectory == null
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}lumtub-region'
        : '${cacheDirectory!}${Platform.pathSeparator}..${Platform.pathSeparator}temp${Platform.pathSeparator}region');
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-${_cookieFiles++}.txt');
    await file.writeAsString(regionCookies(region));
    try {
      yield* _lines(listingArguments(url, cookies: file.path));
    } finally {
      try {
        await file.delete();
      } on FileSystemException {
        // Left for 清理缓存.
      }
    }
  }

  static int _cookieFiles = 0;

  /// A Netscape cookie file holding only YouTube's PREF with country [gl].
  static String regionCookies(String gl) =>
      '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t2147483647\tPREF\tgl=${gl.toUpperCase()}&hl=en\n';

  /// [channel]'s uploads, newest first.
  Listing channelVideos(ChannelRef channel) => channelTab(channel, ChannelTab.videos);

  /// One tab of [channel]: uploads, Shorts, live streams, playlists or
  /// podcasts.
  Listing channelTab(ChannelRef channel, ChannelTab tab) {
    final url = '${channel.url}${tab.path ?? '/videos'}';
    if (tab != ChannelTab.playlists && tab != ChannelTab.podcasts) return _listing(url, channel: channel);
    return Listing(() => _expandingLines(url), channel: channel);
  }

  /// A playlists tab split into shelves ("Created playlists", "Saved
  /// playlists") lists each shelf only as a link to its own page, which
  /// --flat-playlist does not follow; those pages are listed in their turn.
  Stream<String> _expandingLines(String url) async* {
    final followed = <String>{};
    await for (final line in _lines(listingArguments(url))) {
      final shelf = shelfUrl(line);
      if (shelf == null) {
        yield line;
      } else if (followed.add(shelf)) {
        yield* _lines(listingArguments(shelf));
      }
    }
  }

  /// The URL of a channel tab shelf that a flat listing line links to, or
  /// null when the line is an entry itself.
  static String? shelfUrl(String line) {
    try {
      final data = jsonDecode(line);
      if (data is! Map) return null;
      final url = data['url']?.toString() ?? '';
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host != 'www.youtube.com' || uri.queryParameters.containsKey('list')) return null;
      final path = uri.path;
      return (path.endsWith('/playlists') || path.endsWith('/podcasts')) && uri.queryParameters.isNotEmpty ? url : null;
    } catch (_) {
      return null;
    }
  }

  /// The videos of a YouTube playlist.
  Listing playlist(String id) => _listing('https://www.youtube.com/playlist?list=$id');

  /// Videos of [channel] matching [query].
  Listing channelSearch(ChannelRef channel, String query) =>
      _listing('${channel.url}/search?query=${Uri.encodeQueryComponent(query.trim())}', channel: channel);

  Listing _listing(String url, {ChannelRef? channel}) =>
      Listing(() => _lines(listingArguments(url)), channel: channel);

  Stream<String> _lines(List<String> arguments) async* {
    final process = await ProcessTree.start(ytDlpPath, arguments, environment: _environment);
    lowerPriority(process.pid);
    final stderr = StringBuffer();
    final errors = process.stderr.transform(utf8.decoder).listen(stderr.write);
    try {
      // Reading pauses while the page is full, which pauses yt-dlp through
      // the pipe until the next page is asked for.
      yield* process.stdout.transform(utf8.decoder).transform(const LineSplitter());
      final exitCode = await process.exitCode;
      await errors.cancel();
      if (exitCode != 0) {
        final err = stderr.toString().trim();
        throw StateError(err.isEmpty ? 'yt-dlp exited with code $exitCode' : err);
      }
    } finally {
      process.kill();
    }
  }

  /// yt-dlp arguments for watch-page metadata. Skipping the player JS keeps
  /// this cheaper than the extraction libmpv runs for playback; formats are
  /// not needed here.
  List<String> detailsArguments(String videoId) => [
        '--no-warnings',
        '--skip-download',
        if (cacheDirectory != null) ...['--cache-dir', cacheDirectory!],
        '--no-playlist',
        ..._proxyArguments,
        '--ignore-no-formats-error',
        '--extractor-args', 'youtube:player_skip=js',
        '--dump-json',
        '--', 'https://www.youtube.com/watch?v=$videoId',
      ];

  Future<VideoDetails> details(String videoId) async {
    final result = await runWithTimeout(ytDlpPath, detailsArguments(videoId), timeout: const Duration(seconds: 45), environment: _environment);
    final output = result.stdout.toString().trim();
    if (result.exitCode != 0 || output.isEmpty) {
      final err = result.stderr.toString().trim();
      throw StateError(err.isEmpty ? 'yt-dlp exited with code ${result.exitCode}' : err);
    }
    final data = jsonDecode(const LineSplitter().convert(output).last);
    if (data is! Map<String, dynamic>) throw const FormatException('Unexpected yt-dlp output');
    return VideoDetails.fromJson(data);
  }

  /// The environment yt-dlp runs in, for downloads started elsewhere.
  Map<String, String> get processEnvironment => _environment;

  Map<String, String> get _environment {
    // Windows names it "Path"; keep one entry under its own spelling.
    final pathKey = Platform.environment.keys.firstWhere((key) => key.toUpperCase() == 'PATH', orElse: () => 'PATH');
    return {
      ...Platform.environment,
      if (toolDirectories.isNotEmpty)
        pathKey: [...toolDirectories, Platform.environment[pathKey] ?? ''].join(Platform.isWindows ? ';' : ':'),
      if (cacheDirectory != null) ...{
        'TMP': '${cacheDirectory!}${Platform.pathSeparator}..${Platform.pathSeparator}temp',
        'TEMP': '${cacheDirectory!}${Platform.pathSeparator}..${Platform.pathSeparator}temp',
      },
    };
  }
}

class HistoryStore {
  final AppDirectories directories;
  HistoryStore(this.directories);

  late File file;
  final List<VideoItem> items = [];

  Future<void> initialize() async {
    file = File('${directories.data.path}${Platform.pathSeparator}watch_history.json');
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is List) {
        for (final value in data) {
          try {
            if (value is Map<String, dynamic>) items.add(VideoItem.fromJson(value));
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    items.clear();
    await file.writeAsString('[]', flush: true);
  }

  /// Forgets the videos with these ids.
  Future<void> remove(Set<String> ids) async {
    items.removeWhere((item) => ids.contains(item.id));
    await _write();
  }

  Future<void> _write() => file.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()), flush: true);

  Future<void> record(VideoItem item) async {
    items.removeWhere((other) => other.id == item.id);
    items.insert(0, item);
    if (items.length > 60) items.removeRange(60, items.length);
    await _write();
  }
}
