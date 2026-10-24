// Settings sub-pages adapted from PiliNara (lib/pages/setting/pages/
// play_speed_set.dart, color_select.dart, font_setting.dart, logs.dart,
// lib/pages/setting/widgets/ and lib/pages/about/view.dart).
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: the pages read and save Lumtub's settings through
// AppController instead of PiliNara's storage, GetX and SmartDialog are
// removed, and the Bilibili-only options (danmaku, long-press speed,
// dynamic colour on Android) are dropped or replaced by Windows ones.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app_log.dart';
import '../../app_preferences.dart';
import '../../blocked_groups.dart';
import '../../state_media.dart';
import '../../appearance_settings.dart';
import '../../player_settings.dart';
import '../../windows_shell.dart';
import '../../widgets/pilinara_settings_tiles.dart';
import '../common.dart';
import '../theme.dart';
import 'settings_sections.dart';
import '../../l10n/l10n.dart';

const _repository = 'https://github.com/0x696c757a696f/lumtub';

/// Pushes a sub-page that rebuilds whenever [controller] changes.
Future<void> _push(BuildContext context, AppController controller, String title, List<Widget> Function(BuildContext context) children, {List<Widget>? actions}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 40), children: children(context)),
        ),
      ),
    ));

Widget _header(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall!.copyWith(color: context.colors.primary)),
    );

Widget _tip(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 16, color: context.colors.outline),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: context.colors.outline, fontSize: 12, height: 1.5))),
      ]),
    );

// 隐私设置 › 屏蔽频道

/// Blocked channels, by id or typed name, and channels not to recommend.
Future<void> openBlockedChannels(BuildContext context, AppController controller) => _push(
      context,
      controller,
      tr('屏蔽频道'),
      (context) {
        final prefs = controller.preferences;
        final outline = TextStyle(color: context.colors.outline, fontSize: 12);
        return [
          _header(context, tr('屏蔽的频道')),
          if (prefs.blockedChannels.isEmpty && prefs.blockedChannelNames.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(tr('还没有屏蔽任何频道。点右上角“添加”，或在视频卡片的右键菜单、频道页、播放页里选“屏蔽此频道”。'), style: TextStyle(color: context.colors.outline, height: 1.6)),
            ),
          for (final channel in prefs.blockedChannels)
            ListTile(
              leading: const Icon(Icons.person_off_outlined),
              title: Text(channel.name.isEmpty ? channel.id : channel.name),
              subtitle: Text(channel.id, style: outline),
              trailing: TextButton(onPressed: () => controller.unblockChannel(channel.id), child: Text(tr('移除'))),
            ),
          for (final name in prefs.blockedChannelNames)
            ListTile(
              leading: const Icon(Icons.person_off_outlined),
              title: Text(name),
              subtitle: Text(tr('按名称屏蔽'), style: outline),
              trailing: TextButton(onPressed: () => controller.unblockChannelName(name), child: Text(tr('移除'))),
            ),
          _tip(context, tr('屏蔽的频道不会出现在首页、探索、搜索、相关视频和订阅动态中。名单只保存在本机。')),
          _header(context, tr('不推荐的频道')),
          if (prefs.unrecommendedChannels.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(tr('还没有。在视频卡片的右键菜单、频道页或播放页里选“不推荐此频道”。'), style: TextStyle(color: context.colors.outline, height: 1.6)),
            ),
          for (final channel in prefs.unrecommendedChannels)
            ListTile(
              leading: const Icon(Icons.thumb_down_off_alt_outlined),
              title: Text(channel.name.isEmpty ? channel.id : channel.name),
              subtitle: Text(channel.id, style: outline),
              trailing: TextButton(onPressed: () => controller.setRecommendChannel(channel, true), child: Text(tr('恢复推荐'))),
            ),
          _tip(context, tr('不推荐的频道不会出现在首页推荐、探索和相关视频里，但搜索和关注不受影响。')),
        ];
      },
      actions: [
        Builder(builder: (context) => TextButton.icon(
              onPressed: () => _addBlockedChannel(context, controller),
              icon: const Icon(Icons.add_rounded),
              label: Text(tr('添加')),
            )),
        const SizedBox(width: 8),
      ],
    );

Future<void> _addBlockedChannel(BuildContext context, AppController controller) async {
  final text = TextEditingController();
  final typed = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('屏蔽频道')),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: text,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('频道链接或完整名称'),
            helperText: tr('链接里有 UC 开头的频道 ID 时按 ID 屏蔽，否则按名称完全一致屏蔽'),
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'))),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: Text(tr('屏蔽'))),
      ],
    ),
  );
  text.dispose();
  if (typed == null) return;
  final blocked = controller.blockChannelTyped(typed);
  if (blocked != null && context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('已屏蔽“{0}”', [blocked]))));
}

// 首页与搜索设置 › 屏蔽争议宗教团体

/// The groups of blocked_groups.dart, all on or off and one by one.
Future<void> openBlockedGroups(BuildContext context, AppController controller) => _push(context, controller, tr('屏蔽争议宗教团体'), (context) {
      final prefs = controller.preferences;
      void save(AppPreferences next) => controller.savePreferences(next);
      return [
        SwitchListTile(
          secondary: const Icon(Icons.block_rounded),
          title: Text(tr('屏蔽争议宗教团体')),
          subtitle: Text(tr('推荐、探索、相关视频和搜索里不显示下列团体自己的频道和视频；其他频道发的相关报道，以及搜索这些名字，都不受影响')),
          value: prefs.blockGroups,
          onChanged: (v) => save(prefs.copyWith(blockGroups: v)),
        ),
        _tip(context, tr('搜索时输入完全正确的频道名（区分大小写，多一个字或少一个字都不行），仍能找到这个频道和它的视频。关注的频道照常出现在订阅里。')),
        _header(context, tr('屏蔽哪些')),
        ..._groupTiles(context, controller, blockedGroups, media: false),
        _tip(context, tr('点一个团体可以看它的完整名单，逐项取消。只按频道名、@账号和频道 ID 匹配，不看标题和简介；名单只保存在本机。还想屏蔽别的，可以用 首页与搜索设置 › 标题关键词过滤，或 隐私设置 › 屏蔽频道。')),
      ];
    });

Future<void> openStateMedia(BuildContext context, AppController controller) => _push(context, controller, tr('屏蔽官方宣传媒体'), (context) {
      final prefs = controller.preferences;
      void save(AppPreferences next) => controller.savePreferences(next);
      return [
        SwitchListTile(
          secondary: const Icon(Icons.campaign_outlined),
          title: Text(tr('屏蔽官方宣传媒体')),
          subtitle: Text(tr('推荐、探索、相关视频和搜索里不显示下列政府宣传媒体自己的频道和视频')),
          value: prefs.blockStateMedia,
          onChanged: (v) => save(prefs.copyWith(blockStateMedia: v)),
        ),
        _tip(context, tr('只按频道名判断，别的频道转载或报道它们的视频照常显示。BBC、NHK、PBS 这类编辑独立的公共媒体不在其中。搜索完全正确的频道名（区分大小写）仍能找到。')),
        _header(context, tr('屏蔽哪些')),
        ..._groupTiles(context, controller, stateMedia, media: true),
        _tip(context, tr('名单只保存在本机。漏掉的频道可以在 隐私设置 › 屏蔽频道 里自己加。')),
      ];
    });

/// [prefs] with [group] ticked or not.
AppPreferences _withGroup(AppPreferences prefs, BlockedGroup group, bool on, {required bool media}) {
  List<String> toggled(List<String> list, bool add) => add ? {...list, group.name}.toList() : [...list.where((n) => n != group.name)];
  if (!group.onByDefault) return prefs.copyWith(enabledGroups: toggled(prefs.enabledGroups, on));
  return media ? prefs.copyWith(allowedMedia: toggled(prefs.allowedMedia, !on)) : prefs.copyWith(allowedGroups: toggled(prefs.allowedGroups, !on));
}

/// One row per group: a tick for the whole group, and a tap for its list.
List<Widget> _groupTiles(BuildContext context, AppController controller, List<BlockedGroup> groups, {required bool media}) {
  final prefs = controller.preferences;
  final enabled = media ? prefs.blockStateMedia : prefs.blockGroups;
  final allowed = prefs.allowedEntries.toSet();
  return [
    for (final group in groups)
      Builder(builder: (context) {
        final entries = group.entries();
        final off = entries.where((e) => allowed.contains(e.key)).length;
        return ListTile(
          dense: true,
          enabled: enabled,
          leading: Checkbox(
            value: prefs.groupOn(group, media: media),
            onChanged: enabled ? (on) => controller.savePreferences(_withGroup(prefs, group, on == true, media: media)) : null,
          ),
          title: Text(group.label),
          subtitle: Text(
            [
              if (group.note case final note?) tr(note),
              [
                tr('{0} 项', [entries.length]),
                if (off > 0) tr('{0} 项已取消', [off]),
                if (!group.onByDefault) tr('默认不屏蔽'),
                entries.take(4).map((e) => e.label).join('、'),
              ].join(' · '),
            ].join('\n'),
            maxLines: group.note == null ? 1 : 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.colors.outline, fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _openGroupEntries(context, controller, group, media: media),
        );
      }),
  ];
}

/// Everything [group] blocks, each tickable on its own.
Future<void> _openGroupEntries(BuildContext context, AppController controller, BlockedGroup group, {required bool media}) {
  final entries = group.entries();
  void setAll(bool on) {
    final keys = {for (final e in entries) e.key};
    final rest = controller.preferences.allowedEntries.where((k) => !keys.contains(k));
    controller.savePreferences(controller.preferences.copyWith(allowedEntries: [...rest, if (!on) ...keys]));
  }

  return _push(context, controller, group.label, (context) {
    final prefs = controller.preferences;
    final allowed = prefs.allowedEntries.toSet();
    final groupOn = prefs.groupOn(group, media: media) && (media ? prefs.blockStateMedia : prefs.blockGroups);
    return [
      SwitchListTile(
        title: Text(tr('屏蔽这一组')),
        subtitle: Text(media ? tr('需要先打开“屏蔽官方宣传媒体”') : tr('需要先打开“屏蔽争议宗教团体”')),
        value: prefs.groupOn(group, media: media),
        onChanged: (on) => controller.savePreferences(_withGroup(prefs, group, on, media: media)),
      ),
      for (final kind in BlockKind.values)
        if (entries.where((e) => e.kind == kind).toList() case final list when list.isNotEmpty) ...[
          _header(context, '${kind.label} · ${list.length}'),
          for (final entry in list)
            CheckboxListTile(
              dense: true,
              enabled: groupOn,
              title: Text(entry.label),
              subtitle: entry.forms.length > 1 ? Text(entry.forms.skip(1).join('、'), style: TextStyle(color: context.colors.outline, fontSize: 12)) : null,
              value: !allowed.contains(entry.key),
              onChanged: (on) => controller.savePreferences(prefs.copyWith(
                allowedEntries: on == true ? [...prefs.allowedEntries.where((k) => k != entry.key)] : [...prefs.allowedEntries, entry.key],
              )),
            ),
        ],
      _tip(context, switch (media) {
        true => tr('频道名是这几个字，或以它开头（后面接空格或符号），就会被屏蔽。'),
        false => tr('“标题和频道名里的词”出现在标题或频道名里就屏蔽；“频道名”只看频道名，是这几个字或以它开头才屏蔽；@账号和频道 ID 要完全一致。'),
      }),
    ];
  }, actions: [
    TextButton(onPressed: () => setAll(true), child: Text(tr('全选'))),
    TextButton(onPressed: () => setAll(false), child: Text(tr('全不选'))),
  ]);
}

// 播放设置 › 倍速设置 (PiliNara's play_speed_set.dart)

Future<void> openPlaySpeed(BuildContext context, AppController controller) {
  void save(PlayerSettings next) => controller.saveSettings(next);

  Future<void> add(BuildContext context) async {
    final text = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('添加倍速')),
        content: TextField(
          controller: text,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('自定义倍速'), helperText: tr('0.1 到 5 之间')),
          onSubmitted: (v) => Navigator.pop(context, double.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'), style: TextStyle(color: context.colors.outline))),
          TextButton(onPressed: () => Navigator.pop(context, double.tryParse(text.text)), child: Text(tr('确认'))),
        ],
      ),
    );
    text.dispose();
    if (value == null) return;
    if (value < 0.1 || value > 5) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('倍速需在 0.1 到 5 之间'))));
      return;
    }
    final speed = (value * 100).round() / 100;
    final speeds = controller.settings.speeds;
    if (speeds.contains(speed)) return;
    save(controller.settings.copyWith(speeds: [...speeds, speed]..sort()));
  }

  Future<void> edit(BuildContext context, double speed) async {
    final settings = controller.settings;
    final action = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.all(12), child: Text('${trimSpeed(speed)}x', style: Theme.of(context).textTheme.titleMedium)),
          ListTile(leading: const Icon(Icons.check_circle_outline), title: Text(tr('设置为默认倍速')), onTap: () => Navigator.pop(context, 0)),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(tr('删除该项')),
            enabled: settings.speeds.length > 1 && speed != settings.defaultSpeed,
            onTap: () => Navigator.pop(context, 1),
          ),
        ]),
      ),
    );
    if (action == 0) save(controller.settings.copyWith(defaultSpeed: speed));
    if (action == 1) save(controller.settings.copyWith(speeds: [...controller.settings.speeds]..remove(speed)));
  }

  return _push(
    context,
    controller,
    tr('倍速设置'),
    actions: [
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            if (await confirmDialog(context, title: tr('重置倍速？'), content: tr('恢复默认的倍速列表，默认倍速改回 1x。'), confirm: tr('重置'))) {
              save(controller.settings.copyWith(speeds: defaultSpeeds, defaultSpeed: 1));
            }
          },
          child: Text(tr('重置')),
        ),
      ),
      const SizedBox(width: 8),
    ],
    (context) {
      final settings = controller.settings;
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(tr('点击下方按钮设置默认（首选）倍速或删除'), style: TextStyle(color: context.colors.outline)),
        ),
        ListTile(title: Text(tr('默认倍速')), subtitle: Text('${trimSpeed(settings.defaultSpeed)}x')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(children: [
            Text(tr('倍速列表'), style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(onPressed: () => add(context), child: Text(tr('添加'))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final speed in settings.speeds)
              speed == settings.defaultSpeed
                  ? FilledButton(onPressed: () => edit(context, speed), child: Text('${trimSpeed(speed)}x'))
                  : FilledButton.tonal(onPressed: () => edit(context, speed), child: Text('${trimSpeed(speed)}x')),
          ]),
        ),
        _tip(context, tr('播放器底栏的倍速菜单使用这里的列表。')),
      ];
    },
  );
}

// 播放设置 › 字幕设置

Future<void> openSubtitleSettings(BuildContext context, AppController controller) => _push(context, controller, tr('字幕设置'), (context) {
      final settings = controller.settings;
      void save(PlayerSettings next) => controller.saveSettings(next);
      return [
        PopupItem<SubtitleMode>(
          title: tr('自动启用字幕'),
          leading: const Icon(Icons.subtitles_outlined),
          value: settings.subtitleMode,
          values: [for (final m in SubtitleMode.values) (m, m.label)],
          onSelected: (v) => save(settings.copyWith(subtitleMode: v)),
        ),
        PopupItem<SubtitleLanguage>(
          title: tr('首选字幕语言'),
          leading: const Icon(Icons.translate_rounded),
          value: settings.subtitleLanguage,
          values: [for (final l in SubtitleLanguage.values) (l, l.label)],
          onSelected: (v) => save(settings.copyWith(subtitleLanguage: v)),
        ),
        _header(context, tr('样式')),
        SwitchItem(
          title: tr('由 mpv 绘制字幕（libass）'),
          subtitle: tr('支持特效字幕；关闭时由界面绘制，更省资源。重启后生效'),
          leading: const Icon(Icons.layers_outlined),
          value: settings.libassSubtitles,
          onChanged: (v) => save(settings.copyWith(libassSubtitles: v)),
        ),
        NormalItem(
          title: tr('字幕大小'),
          subtitle: tr('当前：{0}×', [settings.subtitleScale.toStringAsFixed(1)]),
          leading: const Icon(Icons.format_size_rounded),
          onTap: () => pickWithSlider(context, title: tr('字幕大小'), value: settings.subtitleScale, min: 0.5, max: 3, divisions: 25, suffix: '×', onSelected: (v) => save(controller.settings.copyWith(subtitleScale: (v * 10).round() / 10))),
        ),
        NormalItem(
          title: tr('字幕位置'),
          subtitle: tr('当前：{0}%（100 为画面底部）', [settings.subtitlePosition]),
          leading: const Icon(Icons.vertical_align_bottom_rounded),
          onTap: () => pickWithSlider(context, title: tr('字幕位置'), value: settings.subtitlePosition.toDouble(), min: 0, max: 100, divisions: 100, suffix: '%', onSelected: (v) => save(controller.settings.copyWith(subtitlePosition: v.round()))),
        ),
        NormalItem(
          title: tr('描边粗细'),
          subtitle: tr('当前：{0}', [settings.subtitleBorder.toStringAsFixed(1)]),
          leading: const Icon(Icons.border_style_rounded),
          onTap: () => pickWithSlider(context, title: tr('描边粗细'), value: settings.subtitleBorder, min: 0, max: 8, divisions: 16, suffix: '', onSelected: (v) => save(controller.settings.copyWith(subtitleBorder: v))),
        ),
        SwitchItem(
          title: tr('背景色块'),
          subtitle: tr('在字幕后面加半透明黑底，替代描边'),
          leading: const Icon(Icons.rectangle_outlined),
          value: settings.subtitleBackground,
          onChanged: (v) => save(settings.copyWith(subtitleBackground: v)),
        ),
        SwitchItem(
          title: tr('粗体'),
          leading: const Icon(Icons.format_bold_rounded),
          value: settings.subtitleBold,
          onChanged: (v) => save(settings.copyWith(subtitleBold: v)),
        ),
        _tip(context, tr('字幕由 yt-dlp 获取，没有人工字幕时使用自动生成的字幕。语言和启用方式从下一个视频开始生效，样式立即生效。')),
      ];
    });

// 其它设置 › 空降助手

Future<void> openSponsorBlock(BuildContext context, AppController controller) => _push(context, controller, tr('空降助手'), (context) {
      final settings = controller.settings;
      void save(PlayerSettings next) => controller.saveSettings(next);
      return [
        SwitchItem(
          title: tr('开启空降助手'),
          subtitle: tr('自动跳过赞助、自我推广等片段'),
          leading: const Icon(Icons.flight_takeoff_rounded),
          value: settings.sponsorBlock,
          onChanged: (v) => save(settings.copyWith(sponsorBlock: v)),
        ),
        SwitchItem(
          title: tr('跳过时显示提示'),
          leading: const Icon(Icons.notifications_none_rounded),
          value: settings.sponsorNotice,
          enabled: settings.sponsorBlock,
          onChanged: (v) => save(settings.copyWith(sponsorNotice: v)),
        ),
        _header(context, tr('跳过的片段类型')),
        for (final MapEntry(key: category, value: (name, description)) in sponsorCategoryNames.entries)
          CheckboxListTile(
            title: Text(name),
            subtitle: Text(description, style: TextStyle(color: context.colors.outline, fontSize: 12)),
            value: settings.sponsorCategories.contains(category),
            enabled: settings.sponsorBlock,
            onChanged: (v) {
              final next = {...controller.settings.sponsorCategories};
              v == true ? next.add(category) : next.remove(category);
              save(controller.settings.copyWith(sponsorCategories: next));
            },
          ),
        _tip(context, tr('片段数据来自 SponsorBlock 社区（sponsor.ajay.app）。查询时只发送视频 ID 哈希值的前 4 位，不发送账号或观看记录。')),
      ];
    });

// 外观设置 › 应用主题 (PiliNara's color_select.dart)

Future<void> openColorSelect(BuildContext context, AppController controller) => _push(context, controller, tr('选择应用主题'), (context) {
      final appearance = controller.appearance;
      final brightness = Theme.of(context).brightness;
      void save(AppearanceSettings next) => controller.saveAppearance(next);
      ColorScheme schemeOf(Color seed) => ColorScheme.fromSeed(seedColor: seed, brightness: brightness, dynamicSchemeVariant: appearance.schemeVariant);
      Widget swatch(Color seed, String label, bool selected, VoidCallback onTap) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(children: [
              ColorPalette(colorScheme: schemeOf(seed), selected: selected),
              const SizedBox(height: 3),
              Text(label, style: TextStyle(fontSize: 12, color: selected ? null : context.colors.outline)),
            ]),
          );
      final windows = controller.windowsAccent;
      return [
        PopupItem<ThemeMode>(
          title: tr('主题模式'),
          leading: const Icon(Icons.flashlight_on_outlined),
          value: appearance.themeMode,
          values: themeModes,
          onSelected: (mode) => save(appearance.copyWith(themeMode: mode)),
        ),
        PopupItem<DynamicSchemeVariant>(
          title: tr('调色板风格'),
          leading: const Icon(Icons.palette_outlined),
          value: appearance.schemeVariant,
          values: [for (final e in schemeVariantNames.entries) (e.key, e.value)],
          onSelected: (v) => save(appearance.copyWith(schemeVariant: v)),
        ),
        ListTile(
          title: Text(tr('跟随 Windows 强调色')),
          subtitle: Text(windows == null ? tr('无法读取系统强调色') : tr('在 Windows 设置 › 个性化 › 颜色 中更改'), style: TextStyle(color: context.colors.outline, fontSize: 12)),
          enabled: windows != null,
          leading: Checkbox(
            value: appearance.systemAccent,
            onChanged: windows == null ? null : (v) => save(appearance.copyWith(systemAccent: v ?? false)),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          ),
          onTap: windows == null ? null : () => save(appearance.copyWith(systemAccent: !appearance.systemAccent)),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: appearance.systemAccent && windows != null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(spacing: 22, runSpacing: 18, alignment: WrapAlignment.center, children: [
                    swatch(Color(appearance.customAccent), tr('自定义'), appearance.accentIndex < 0, () async {
                      final color = await showDialog<Color>(
                        context: context,
                        builder: (context) => AlertDialog(
                          clipBehavior: Clip.hardEdge,
                          contentPadding: const EdgeInsets.symmetric(vertical: 16),
                          title: Text(tr('自定义颜色')),
                          content: SlideColorPicker(color: Color(appearance.customAccent)),
                        ),
                      );
                      if (color != null) save(controller.appearance.copyWith(accentIndex: -1, customAccent: color.toARGB32()));
                    }),
                    for (var i = 0; i < accentChoices.length; i++)
                      swatch(accentChoices[i].$2, accentChoices[i].$1, appearance.accentIndex == i, () => save(controller.appearance.copyWith(accentIndex: i))),
                  ]),
                ),
        ),
        _header(context, tr('预览')),
        IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('标题文字'), style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(tr('次要说明文字'), style: TextStyle(color: context.colors.outline)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    FilledButton(onPressed: () {}, child: Text(tr('订阅'))),
                    FilledButton.tonal(onPressed: () {}, child: Text(tr('收藏'))),
                    OutlinedButton(onPressed: () {}, child: Text(tr('分享'))),
                    Switch(value: true, onChanged: (_) {}),
                  ]),
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(value: 0.6),
                ]),
              ),
            ),
          ),
        ),
      ];
    });

// 外观设置 › App 字体设置 (PiliNara's font_setting.dart)

Future<void> openFontSettings(BuildContext context, AppController controller) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _FontSettingsPage(controller: controller)));

class _FontSettingsPage extends StatefulWidget {
  const _FontSettingsPage({required this.controller});
  final AppController controller;

  @override
  State<_FontSettingsPage> createState() => _FontSettingsPageState();
}

class _FontSettingsPageState extends State<_FontSettingsPage> {
  List<String>? _systemFonts;
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsShell.systemFontFamilies().then((fonts) {
        if (mounted) setState(() => _systemFonts = fonts);
      });
    } else {
      _systemFonts = const [];
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('App 字体设置'))),
        body: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final controller = widget.controller;
            final appearance = controller.appearance;
            final fixed = {for (final (family, _) in fontChoices) if (family != null) family};
            final needle = _query.trim().toLowerCase();
            final system = (_systemFonts ?? const <String>[]).where((family) => !fixed.contains(family) && (needle.isEmpty || family.toLowerCase().contains(needle))).toList();
            void save(String? family) => controller.saveAppearance(family == null ? appearance.copyWith(clearFontFamily: true) : appearance.copyWith(fontFamily: family));
            Widget option(String? family, String label) => RadioListTile<String?>(
                  value: family,
                  title: Text(label, style: TextStyle(fontFamily: family)),
                  subtitle: family == null ? null : Text(family, style: TextStyle(color: context.colors.outline, fontSize: 12)),
                );
            final theme = Theme.of(context);
            return RadioGroup<String?>(
              groupValue: appearance.fontFamily,
              onChanged: save,
              child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
                _header(context, tr('字体')),
                for (final (family, label) in fontChoices) option(family, label),
                _header(context, tr('已安装的系统字体')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('搜索已安装字体')),
                  ),
                ),
                if (_systemFonts == null)
                  const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                else if (system.isEmpty)
                  Padding(padding: const EdgeInsets.all(16), child: Text(tr('没有匹配的已安装字体'), style: TextStyle(color: context.colors.outline)))
                else
                  for (final family in system) option(family, family),
                _header(context, tr('字号')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    Expanded(child: Slider(min: 0.8, max: 1.4, divisions: 12, value: appearance.textScale, label: '${(appearance.textScale * 100).round()}%', onChanged: (v) => controller.saveAppearance(appearance.copyWith(textScale: (v * 100).round() / 100)))),
                    SizedBox(width: 48, child: Text('${(appearance.textScale * 100).round()}%')),
                    TextButton(onPressed: () => controller.saveAppearance(appearance.copyWith(textScale: 1, fontFamily: bundledFont)), child: Text(tr('重置'))),
                  ]),
                ),
                _header(context, tr('预览')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('Lumtub 让 YouTube 在 Windows 上更好用'), style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text('The quick brown fox jumps over the lazy dog. 0123456789', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    Text(tr('频道名称 · 12 万次观看 · 3 天前'), style: theme.textTheme.labelMedium!.copyWith(color: context.colors.outline)),
                  ]),
                ),
                _tip(context, tr('Noto Sans CJK SC 随 Lumtub 安装；系统字体从当前 Windows 用户的字体集合读取。')),
              ]),
            );
          },
        ),
      );
}

// 视频设置 › 画面与音画同步调节 (PiliNara's video picture panel)

Future<void> openPictureSettings(BuildContext context, AppController controller) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => _PictureSettingsPage(controller: controller)),
    );

class _PictureSettingsPage extends StatefulWidget {
  const _PictureSettingsPage({required this.controller});
  final AppController controller;

  @override
  State<_PictureSettingsPage> createState() => _PictureSettingsPageState();
}

class _PictureSettingsPageState extends State<_PictureSettingsPage> {
  late final Map<String, int> _picture = {...widget.controller.settings.picture};
  late int _audioDelay = widget.controller.settings.audioDelayMs;

  void _save() => widget.controller.saveSettings(widget.controller.settings.copyWith(picture: {
        for (final entry in _picture.entries)
          if (entry.value != 0) entry.key: entry.value,
      }, audioDelayMs: _audioDelay));

  Widget _slider(String label, int value, int min, int max, String suffix, ValueChanged<int> onChanged, VoidCallback onReset) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(children: [
          SizedBox(width: 72, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              label: '$value$suffix',
              onChanged: (v) => onChanged(v.round()),
              onChangeEnd: (_) => _save(),
            ),
          ),
          SizedBox(width: 64, child: Text('$value$suffix', textAlign: TextAlign.end)),
          IconButton(tooltip: tr('重置'), icon: const Icon(Icons.restart_alt_rounded, size: 20), onPressed: value == 0 ? null : onReset),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('画面与音画同步调节')),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _picture.clear();
                _audioDelay = 0;
              });
              for (final (key, _) in pictureProperties) {
                controller.previewProperty(key, '0');
              }
              controller.previewProperty('audio-delay', '0');
              _save();
            },
            child: Text(tr('全部重置')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
        _header(context, tr('画面')),
        for (final (key, label) in pictureProperties)
          _slider(label, _picture[key] ?? 0, -100, 100, '', (v) {
            setState(() => _picture[key] = v);
            controller.previewProperty(key, '$v');
          }, () {
            setState(() => _picture[key] = 0);
            controller.previewProperty(key, '0');
            _save();
          }),
        _header(context, tr('音画同步')),
        _slider(tr('音频延迟'), _audioDelay, -2000, 2000, ' ms', (v) {
          setState(() => _audioDelay = (v / 10).round() * 10);
          controller.previewProperty('audio-delay', '${_audioDelay / 1000}');
        }, () {
          setState(() => _audioDelay = 0);
          controller.previewProperty('audio-delay', '0');
          _save();
        }),
        _tip(context, tr('拖动时立即在正在播放的视频上预览。音频延迟为正时声音推后，为负时声音提前。这些值对之后的所有视频都生效。')),
      ]),
    );
  }
}

// 其它设置 › 组件管理

Future<void> openComponents(BuildContext context, AppController controller) => _push(context, controller, tr('组件管理'), (context) {
      final tools = controller.tools;
      if (tools == null || !controller.ready) return [NormalItem(title: tr('正在准备组件…'))];
      final libmpv = tools.libmpv;
      final current = libmpv.current;
      final next = libmpv.selected;
      final pendingRestart = next != null && next != current;
      return [
        NormalItem(
          title: 'libmpv',
          subtitle: [
            '${libmpv.usesDownload ? '已更新' : '内置'}：${current?.label ?? '未知版本'}',
            if (pendingRestart) tr('重启后使用 {0}', [next.label]),
          ].join('\n'),
          leading: const Icon(Icons.movie_outlined),
          trailing: libmpv.usesDownload || pendingRestart ? TextButton(onPressed: controller.rollBackLibmpv, child: Text(tr('改回内置'))) : null,
        ),
        NormalItem(
          title: 'yt-dlp',
          subtitle: tools.ytDlpVersion ?? tr('未安装'),
          leading: const Icon(Icons.terminal_rounded),
          trailing: tools.canRollBackYtDlp ? TextButton(onPressed: controller.rollBackYtDlp, child: Text(tr('回退上一版'))) : null,
        ),
        NormalItem(title: 'Deno', subtitle: tools.denoVersion ?? tr('未安装'), leading: const Icon(Icons.code_rounded)),
        NormalItem(
          title: 'ffmpeg',
          subtitle: controller.installingFfmpeg
              ? tr('正在安装… {0}', [controller.ffmpegProgress == null ? '' : '${(controller.ffmpegProgress! * 100).round()}%'])
              : tools.ffmpegVersion == null
                  ? tr('未安装（合并高画质下载时按需安装）')
                  : tr('{0} · 占用 {1}', [tools.ffmpegVersion!, formatBytes(tools.ffmpegBytes ?? 0)]),
          leading: const Icon(Icons.merge_type_rounded),
          trailing: controller.installingFfmpeg
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: controller.installFfmpeg, child: Text(tools.ffmpegVersion == null ? tr('安装') : tr('更新'))),
                  if (tools.ffmpegVersion != null) TextButton(onPressed: controller.removeFfmpeg, child: Text(tr('移除'))),
                ]),
        ),
        NormalItem(
          title: controller.checking ? tr('正在检查更新…') : tr('立即检查更新'),
          subtitle: tr('只从官方 GitHub Release 下载并校验 SHA-256，重启后启用'),
          leading: const Icon(Icons.system_update_alt_rounded),
          enabled: !controller.checking,
          onTap: controller.checkUpdates,
        ),
        _tip(context, tr('新 libmpv 出错时会自动改回内置版本。yt-dlp 更新后若无法播放，可以回退到上一版。')),
        _tip(context, tr('ffmpeg 是可选组件，只用于合并高画质视频和音频，不会自动下载。它是 Lumtub 自建的 LGPL 精简构建（https://github.com/0x696c757a696f/lumtub-media-builds），包内 BUILD.txt 写明所用的 FFmpeg 源代码。')),
      ];
    });

// 关于 (PiliNara's about/view.dart)

List<SettingEntry> aboutEntries(AppController controller) => [
      SettingEntry(tr('版本'), (context) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              Icon(Icons.smart_display_rounded, size: 72, color: context.colors.primary),
              const SizedBox(height: 4),
              Text('Lumtub', style: Theme.of(context).textTheme.titleMedium!.copyWith(height: 2)),
              Text(tr('使用 Flutter 和 mpv 开发的 YouTube 第三方客户端'), style: TextStyle(color: context.colors.outline)),
              const SizedBox(height: 8),
              ListTile(
                title: Text(tr('当前版本')),
                leading: const Icon(Icons.commit_outlined),
                trailing: Text(appVersion, style: TextStyle(fontSize: 14, color: context.colors.outline)),
                onTap: () => copyText(context, appVersion, tr('版本号已复制')),
              ),
            ]),
          ), subtitle: tr('当前版本 更新')),
      SettingEntry(tr('检查更新'), (context) => NormalItem(
            title: controller.checkingAppUpdate
                ? tr('正在检查软件更新…')
                : controller.availableAppVersion == null
                    ? tr('检查更新')
                    : tr('有新版本：{0}', [controller.availableAppVersion!]),
            subtitle: controller.appUpdateError == null
                ? controller.availableAppVersion == null
                    ? tr('启动时自动检查，也可立即检查')
                    : tr('点击打开 GitHub Release 下载')
                : tr('检查软件更新失败：{0}', [controller.appUpdateError!]),
            leading: const Icon(Icons.update_rounded),
            onTap: () async {
              await controller.checkAppUpdate();
              openExternal(controller.availableAppUrl ?? '$_repository/releases');
            },
          ), subtitle: tr('发布页 新版本')),
      SettingEntry(tr('源代码'), (context) => NormalItem(
            title: tr('Github 仓库'),
            subtitle: 'github.com/0x696c757a696f/lumtub',
            leading: const Icon(Icons.code_rounded),
            onTap: () => openExternal(_repository),
          ), subtitle: tr('GitHub 源代码')),
      SettingEntry(tr('问题反馈'), (context) => NormalItem(
            title: tr('问题反馈'),
            subtitle: tr('在 GitHub 提交 issue，请附上诊断信息和错误日志'),
            leading: const Icon(Icons.feedback_outlined),
            onTap: () => openExternal('$_repository/issues'),
          ), subtitle: 'issue bug'),
      SettingEntry(tr('错误日志'), (context) => NormalItem(
            title: tr('错误日志'),
            subtitle: tr('只保存在本机，不记录登录凭据和视频流地址'),
            leading: const Icon(Icons.bug_report_outlined),
            onTap: () => openLogs(context, controller),
          ), subtitle: tr('日志 log')),
      SettingEntry(tr('复制诊断信息'), (context) => NormalItem(
            title: tr('复制诊断信息'),
            subtitle: tr('版本、系统、显卡、组件和播放设置'),
            leading: const Icon(Icons.content_copy_rounded),
            onTap: () => copyText(context, controller.diagnostics(), tr('诊断信息已复制')),
          ), subtitle: tr('反馈 问题')),
      SettingEntry(tr('开源许可'), (context) => NormalItem(
            title: tr('开源许可'),
            subtitle: tr('GPLv3；部分界面改编自 PiliNara，播放基于 mpv、media_kit 和 yt-dlp'),
            leading: const Icon(Icons.gavel_rounded),
            onTap: () => showLicensePage(context: context, applicationName: 'Lumtub', applicationVersion: appVersion),
          ), subtitle: 'PiliNara mpv media_kit yt-dlp license'),
    ];

// 关于 › 错误日志 (PiliNara's logs.dart)

Future<void> openLogs(BuildContext context, AppController controller) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => _LogsPage(controller: controller)));

class _LogsPage extends StatefulWidget {
  const _LogsPage({required this.controller});
  final AppController controller;

  @override
  State<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<_LogsPage> {
  String? _text;

  Directory? get _directory => widget.controller.directories?.logs;

  File? _file(String name) => _directory == null ? null : File('${_directory!.path}${Platform.pathSeparator}$name');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final parts = <String>[];
    for (final name in const ['lumtub.old.log', 'lumtub.log']) {
      try {
        final file = _file(name);
        if (file != null && await file.exists()) parts.add(await file.readAsString());
      } on FileSystemException {
        // An unreadable log is shown as empty.
      }
    }
    if (mounted) setState(() => _text = parts.join());
  }

  Future<void> _clear() async {
    if (!await confirmDialog(context, title: tr('清空日志？'), content: tr('删除本机保存的 Lumtub 日志。'), confirm: tr('清空'))) return;
    for (final name in const ['lumtub.old.log', 'lumtub.log']) {
      try {
        final file = _file(name);
        if (file != null && await file.exists()) await file.writeAsString('');
      } on FileSystemException {
        // Keep going; the rest of the log is still cleared.
      }
    }
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('已清空'))));
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final lines = text == null ? const <String>[] : text.split('\n').where((l) => l.isNotEmpty).toList().reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('日志')),
        actions: [
          PopupMenuButton<int>(
            onSelected: (value) => switch (value) {
              0 => copyText(context, text ?? '', tr('复制成功')),
              1 => openExternal('$_repository/issues'),
              2 => _directory == null ? null : openExternal(_directory!.path),
              _ => _clear(),
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 0, child: Text(tr('复制日志'))),
              PopupMenuItem(value: 1, child: Text(tr('错误反馈'))),
              PopupMenuItem(value: 2, child: Text(tr('打开日志文件夹'))),
              PopupMenuItem(value: 3, child: Text(tr('清空日志'))),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: text == null
          ? const Center(child: CircularProgressIndicator())
          : lines.isEmpty
              ? Center(child: Text(tr('暂无日志'), style: TextStyle(color: context.colors.outline)))
              : SelectionArea(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    itemCount: lines.length,
                    separatorBuilder: (context, i) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final line = lines[i];
                      final space = line.indexOf(' ');
                      final time = space > 0 ? line.substring(0, space).replaceFirst('T', ' ').split('.').first : '';
                      final rest = space > 0 ? line.substring(space + 1) : line;
                      final error = rest.startsWith('ERROR') || rest.startsWith('错误');
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if (time.isNotEmpty) Text(time, style: TextStyle(fontSize: 12, color: context.colors.outline)),
                          Text(rest, style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: error ? context.colors.error : null)),
                        ]),
                      );
                    },
                  ),
                ),
    );
  }
}
