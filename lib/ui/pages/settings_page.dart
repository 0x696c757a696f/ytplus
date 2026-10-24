// Layout adapted from PiliNara (lib/pages/setting/view.dart): a list of
// settings groups with a search box, and the chosen group beside it on wide
// windows or on its own page on narrow ones.
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: GetX routing is replaced with local state and a
// MaterialPageRoute, and the groups are Lumtub's own.

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../widgets/pilinara_settings_tiles.dart';
import '../theme.dart';
import 'settings_sections.dart';
import '../../l10n/l10n.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller, this.initial = SettingsCategory.account});
  final AppController controller;
  final SettingsCategory initial;

  /// Below this width the groups and their rows no longer fit side by side.
  static const wideWidth = 720.0;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsCategory _category = widget.initial;
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  AppController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= SettingsPage.wideWidth;
        if (!wide) return _list(context, wide: false);
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 4, child: _list(context, wide: true)),
          VerticalDivider(width: 1, color: context.colors.outline.withValues(alpha: 0.1)),
          Expanded(flex: 6, child: _query.isEmpty ? _Entries(controller: _controller, category: _category) : _SearchResults(controller: _controller, query: _query)),
        ]);
      });

  Widget _list(BuildContext context, {required bool wide}) => ListenableBuilder(
        listenable: Listenable.merge([_controller, _controller.account]),
        builder: (context, _) => _listBody(context, wide: wide),
      );

  Widget _listBody(BuildContext context, {required bool wide}) {
    final theme = Theme.of(context);
    final searching = _query.isNotEmpty;
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: TextField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.onInverseSurface,
            hintText: tr('搜索设置'),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: searching
                ? IconButton(
                    tooltip: tr('清除'),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                    }),
                  )
                : null,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(50), borderSide: BorderSide.none),
          ),
        ),
      ),
      // On narrow windows the matches replace the groups; wide windows show
      // them in the detail pane.
      if (searching && !wide)
        ..._SearchResults.rows(context, _controller, _query)
      else ...[
        for (final category in SettingsCategory.values)
          if (category != SettingsCategory.account && category != SettingsCategory.about) _tile(context, category, wide: wide, subtitle: category.subtitle),
        // Like PiliNara, the account and about rows sit at the bottom
        // without a subtitle, with sign-out between them when signed in.
        _tile(context, SettingsCategory.account, wide: wide),
        if (_controller.account?.signedIn ?? false)
          ListTile(
            leading: const Icon(Icons.logout_outlined),
            title: Text(tr('退出登录'), style: theme.textTheme.titleMedium),
            onTap: () async {
              if (await confirmDialog(context, title: tr('退出登录？'), content: tr('本机保存的 Google 登录凭据会被删除，订阅和播放列表保留在本机。'), confirm: tr('退出登录'))) {
                await _controller.account?.signOut();
              }
            },
          ),
        _tile(context, SettingsCategory.about, wide: wide),
      ],
    ]);
  }

  Widget _tile(BuildContext context, SettingsCategory category, {required bool wide, String? subtitle}) {
    final theme = Theme.of(context);
    return ListTile(
      tileColor: wide && _query.isEmpty && category == _category ? theme.colorScheme.onInverseSurface : null,
      leading: Icon(category.icon),
      title: Text(category.title, style: theme.textTheme.titleMedium),
      subtitle: subtitle == null ? null : Text(subtitle, style: theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.outline)),
      onTap: () {
        if (wide) {
          setState(() {
            _category = category;
            _search.clear();
            _query = '';
          });
        } else {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              appBar: AppBar(title: Text(category.title)),
              body: _Entries(controller: _controller, category: category),
            ),
          ));
        }
      },
    );
  }
}

/// The rows of one group, rebuilt whenever a setting changes.
class _Entries extends StatelessWidget {
  const _Entries({required this.controller, required this.category});
  final AppController controller;
  final SettingsCategory category;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(padding: const EdgeInsets.only(top: 4, bottom: 24), children: [
          for (final entry in settingEntries(category, controller)) entry.builder(context),
        ]),
      );
}

/// Rows from every group whose title or keywords contain the query.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.controller, required this.query});
  final AppController controller;
  final String query;

  static List<Widget> rows(BuildContext context, AppController controller, String query) {
    final rows = <Widget>[
      for (final category in SettingsCategory.values)
        for (final entry in settingEntries(category, controller))
          if (entry.matches(query) || category.title.toLowerCase().contains(query)) entry.builder(context),
    ];
    if (rows.isNotEmpty) return rows;
    return [
      Padding(
        padding: const EdgeInsets.all(32),
        child: Text(tr('没有找到相关设置'), textAlign: TextAlign.center, style: TextStyle(color: context.colors.outline)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(padding: const EdgeInsets.only(top: 4, bottom: 24), children: rows(context, controller, query)),
      );
}
