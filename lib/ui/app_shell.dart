import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../appearance_settings.dart';
import 'common.dart';
import 'pages/account_settings.dart';
import 'pages/channel_page.dart';
import 'pages/downloads_page.dart';
import 'pages/explore_page.dart';
import 'pages/library_pages.dart';
import 'pages/settings_page.dart';
import 'pages/video_pages.dart';
import 'pages/watch_page.dart';
import 'pages/youtube_playlist_page.dart';
import 'mini_player.dart';
import 'pip_view.dart';
import 'theme.dart';
import 'video_card.dart';
import '../l10n/l10n.dart';

const appName = 'Lumtub';

/// Top bar, navigation rail (bottom bar on narrow windows), page area and
/// status line.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');
  StreamSubscription<String>? _notices;

  AppController get _controller => widget.controller;

  static final _destinations = [
    (PageMode.home, Icons.home_outlined, Icons.home_rounded, tr('首页')),
    (PageMode.explore, Icons.explore_outlined, Icons.explore_rounded, tr('探索')),
    (PageMode.subscriptions, Icons.subscriptions_outlined, Icons.subscriptions_rounded, tr('订阅')),
    (PageMode.history, Icons.history_outlined, Icons.history_rounded, tr('历史')),
    (PageMode.playlists, Icons.video_library_outlined, Icons.video_library_rounded, tr('播放列表')),
    (PageMode.downloads, Icons.download_for_offline_outlined, Icons.download_for_offline_rounded, tr('下载')),
  ];

  @override
  void initState() {
    super.initState();
    _notices = _controller.notices.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchText.selection = TextSelection(baseOffset: 0, extentOffset: _searchText.text.length);
  }

  void _submitSearch(String value) {
    if (value.trim().isEmpty) return;
    _searchFocus.unfocus();
    unawaited(_controller.search(value));
  }

  void _select(int index) {
    final target = _destinations[index].$1;
    if (target == PageMode.explore) {
      _controller.openExplore();
    } else {
      _controller.navigate(target);
    }
  }

  /// Goes back to the previous page or video.
  void _back() {
    if (_controller.canGoBack) _controller.goBack();
  }

  int? get _selectedIndex {
    final index = _destinations.indexWhere((d) => d.$1 == _controller.mode);
    return index < 0 ? null : index;
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): _focusSearch,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back,
        },
        child: Listener(
          // The mouse "back" button goes back, like Alt+←.
          onPointerDown: (event) {
            if (event.buttons == kBackMouseButton) _back();
          },
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
              // Picture in picture shows the video alone.
              if (_controller.pip && _controller.playing != null && _controller.videoController != null) {
                return PipView(controller: _controller);
              }
              final wide = constraints.maxWidth >= 720;
              final rail = switch (_controller.appearance.navigation) {
                NavigationStyle.auto => wide,
                NavigationStyle.rail => true,
                NavigationStyle.bottom => false,
              };
              return Scaffold(
                body: Column(children: [
                  _TopBar(
                    wide: wide,
                    controller: _controller,
                    searchText: _searchText,
                    searchFocus: _searchFocus,
                    onSubmit: _submitSearch,
                  ),
                  Expanded(child: Stack(children: [
                    Row(children: [
                      if (rail)
                        NavigationRail(
                          selectedIndex: _selectedIndex,
                          labelType: NavigationRailLabelType.all,
                          minWidth: 76,
                          groupAlignment: -1,
                          onDestinationSelected: _select,
                          destinations: [
                            for (final d in _destinations)
                              NavigationRailDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: Text(d.$4)),
                          ],
                        ),
                      Expanded(child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        // Keyed per page so each page's list keeps its scroll position
                        // (PageStorage) when the user comes back to it.
                        child: KeyedSubtree(key: PageStorageKey<String>(_pageKey), child: VideoActions(controller: _controller, child: _content())),
                      )),
                    ]),
                    // The video keeps playing over the pages; the watch page
                    // is not mounted meanwhile, so the card has the only Video.
                    if (_controller.mini && _controller.playing != null)
                      Positioned.fill(child: MiniPlayer(controller: _controller)),
                  ])),
                  if (_controller.appearance.showStatusBar) _StatusBar(controller: _controller),
                ]),
                bottomNavigationBar: rail ? null : NavigationBar(
                  height: 64,
                  selectedIndex: _selectedIndex ?? 0,
                  onDestinationSelected: _select,
                  destinations: [
                    for (final d in _destinations) NavigationDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: d.$4),
                  ],
                ),
              );
            }),
          ),
        ),
      );

  String get _pageKey => !_controller.ready ? 'setup' : _controller.onWatchPage ? 'watch' : switch (_controller.mode) {
        PageMode.channel => 'channel:${_controller.channel?.id}',
        PageMode.playlist => 'playlist:${_controller.openPlaylistId}',
        PageMode.youtubePlaylist => 'yt-playlist:${_controller.youtubePlaylist?.id}',
        PageMode.explore when _controller.query != null => 'search:${_controller.query}',
        final mode => mode.name,
      };

  Widget _content() {
    final controller = _controller;
    if (!controller.ready) return _SetupView(controller: controller);
    if (controller.onWatchPage && controller.videoController != null) return WatchPage(controller: controller);
    return switch (controller.mode) {
      PageMode.home => HomeFeedPage(controller: controller, onFocusSearch: _focusSearch),
      PageMode.explore => controller.query == null ? ExplorePage(controller: controller) : SearchResultsPage(controller: controller, onFocusSearch: _focusSearch),
      PageMode.history => HistoryPage(controller: controller),
      PageMode.subscriptions => SubscriptionsPage(controller: controller),
      PageMode.playlists => PlaylistsPage(controller: controller),
      PageMode.downloads => DownloadsPage(controller: controller),
      PageMode.channel => ChannelPage(controller: controller),
      PageMode.playlist => PlaylistDetailPage(controller: controller),
      PageMode.youtubePlaylist => YoutubePlaylistPage(controller: controller),
      PageMode.settings => SettingsPage(controller: controller),
    };
  }
}

/// Opens 设置. While a video is open it goes over the watch page, so the
/// video keeps playing and 返回 comes back to it.
void openSettings(BuildContext context, AppController controller) {
  if (!controller.onWatchPage) return controller.navigate(PageMode.settings);
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (context) {
      void back() => Navigator.of(context).maybePop();
      return CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): back},
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kBackMouseButton) back();
          },
          child: Focus(autofocus: true, child: Scaffold(appBar: AppBar(title: Text(tr('设置'))), body: SettingsPage(controller: controller))),
        ),
      );
    },
  )));
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.wide, required this.controller, required this.searchText, required this.searchFocus, required this.onSubmit});
  final bool wide;
  final AppController controller;
  final TextEditingController searchText;
  final FocusNode searchFocus;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ready = controller.ready;
    return SizedBox(
      height: AppStyle.topBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          InkWell(
            borderRadius: AppStyle.cardRadius,
            onTap: () => controller.navigate(PageMode.home),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(9)),
                  child: Icon(Icons.play_arrow_rounded, color: colors.onPrimary, size: 22),
                ),
                if (wide) ...[
                  const SizedBox(width: 10),
                  Text(appName, style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                ],
              ]),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SizedBox(height: 40, child: _SearchField(app: controller, controller: searchText, focusNode: searchFocus, enabled: ready, onSubmit: onSubmit)),
          ))),
          const SizedBox(width: 16),
          IconButton(
            tooltip: tr('检查组件更新'),
            onPressed: ready && !controller.checking ? controller.checkUpdates : null,
            icon: controller.checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.system_update_alt_rounded),
          ),
          IconButton(
            tooltip: tr('设置'),
            isSelected: controller.mode == PageMode.settings && !controller.onWatchPage,
            onPressed: () => openSettings(context, controller),
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
          ),
          AccountButton(account: controller.account, onOpenSettings: () => openSettings(context, controller)),
        ]),
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.app, required this.controller, required this.focusNode, required this.enabled, required this.onSubmit});
  final AppController app;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

/// A row under the search field: a recent search or YouTube's suggestion.
class _SearchOption {
  const _SearchOption(this.text, {this.recent = false});
  final String text;
  final bool recent;
}

/// The search field, with recent searches when empty and YouTube's
/// suggestions while typing. Enter searches for what is typed unless a row
/// was picked with the arrow keys.
class _SearchFieldState extends State<_SearchField> {
  bool _picking = false;
  double _width = 640;

  @override
  void initState() {
    super.initState();
    widget.focusNode
      ..onKeyEvent = _onKey
      ..addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode
      ..onKeyEvent = null
      ..removeListener(_onFocus);
    super.dispose();
  }

  /// The first arrow key only marks the first row; later ones move.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent || (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp)) return KeyEventResult.ignored;
    if (_picking) return KeyEventResult.ignored;
    setState(() => _picking = true);
    return key == LogicalKeyboardKey.arrowDown ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onFocus() {
    if (widget.focusNode.hasFocus) {
      _refresh();
    } else if (_picking) {
      setState(() => _picking = false);
    }
  }

  /// Builds the rows again for the same text; they otherwise only change
  /// when the text does.
  void _refresh() {
    final value = widget.controller.value;
    widget.controller.value = value.copyWith(text: '${value.text} ');
    widget.controller.value = value;
  }

  Future<List<String>> _recent() async =>
      widget.app.preferences.recordHistory ? await widget.app.searchHistory?.items() ?? const [] : const [];

  Future<Iterable<_SearchOption>> _options(TextEditingValue value) async {
    final text = value.text.trim();
    if (text.isEmpty) return [for (final q in (await _recent()).take(10)) _SearchOption(q, recent: true)];
    final lower = text.toLowerCase();
    final recent = [for (final q in await _recent()) if (q.toLowerCase().startsWith(lower) && q != text) q].take(3).toList();
    // Wait for typing to pause before asking YouTube.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (widget.controller.text.trim() != text) return const [];
    final suggested = await widget.app.searchSuggestions.forQuery(text);
    return [
      for (final q in recent) _SearchOption(q, recent: true),
      for (final q in suggested)
        if (!recent.contains(q)) _SearchOption(q),
    ].take(12);
  }

  Future<void> _remove(String query) async {
    await widget.app.searchHistory?.remove(query);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        _width = constraints.maxWidth;
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.focusNode.unfocus},
          child: RawAutocomplete<_SearchOption>(
            textEditingController: widget.controller,
            focusNode: widget.focusNode,
            displayStringForOption: (option) => option.text,
            optionsBuilder: _options,
            onSelected: (option) => widget.onSubmit(option.text),
            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) => TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: widget.enabled,
              onSubmitted: (text) {
                if (_picking) {
                  _picking = false;
                  onFieldSubmitted();
                } else {
                  widget.onSubmit(text);
                }
              },
              onChanged: (_) => setState(() => _picking = false),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: tr('搜索 YouTube，或粘贴视频链接'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: controller.text.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Center(widthFactor: 1, child: Text('Ctrl+K', style: TextStyle(fontSize: 12, color: context.colors.outline))),
                      )
                    : IconButton(
                        tooltip: tr('清除'),
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          controller.clear();
                          setState(() {});
                          focusNode.requestFocus();
                        },
                      ),
              ),
            ),
            optionsViewBuilder: (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Material(
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: _width, minWidth: _width, maxHeight: 420),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, i) {
                        final option = options.elementAt(i);
                        final highlighted = _picking && AutocompleteHighlightedOption.of(context) == i;
                        return ListTile(
                          dense: true,
                          selected: highlighted,
                          selectedTileColor: context.colors.surfaceContainerHighest,
                          leading: Icon(option.recent ? Icons.history_rounded : Icons.search_rounded, size: 20),
                          title: Text(option.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: option.recent
                              ? IconButton(tooltip: tr('删除这条记录'), icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => _remove(option.text))
                              : null,
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      });
}

class _SetupView extends StatelessWidget {
  const _SetupView({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.error;
    if (error != null) {
      return StatusView(
        icon: Icons.error_outline_rounded,
        error: true,
        title: tr('组件安装遇到问题'),
        message: error,
        action: FilledButton.icon(onPressed: controller.retryInitialize, icon: const Icon(Icons.refresh_rounded), label: Text(tr('重试'))),
      );
    }
    return StatusView(
      icon: Icons.download_for_offline_outlined,
      title: tr('正在准备播放器组件'),
      message: tr('{0}\n首次运行需要从 GitHub 下载组件，以后可以离线启动。', [controller.status]),
      action: const SizedBox(width: 240, child: LinearProgressIndicator()),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final paths = controller.paths;
    final text = controller.ready && paths != null
        ? 'libmpv ${controller.tools?.libmpv.current?.label ?? '内置'}  ·  $status'
        : status;
    return Container(
      width: double.infinity,
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: context.colors.outlineVariant.withValues(alpha: 0.4)))),
      alignment: Alignment.centerLeft,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.colors.outline, fontSize: 11)),
    );
  }
}
