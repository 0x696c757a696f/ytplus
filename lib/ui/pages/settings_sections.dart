import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../blocked_groups.dart';
import '../../feed_quality.dart';
import '../../format_policy.dart';
import '../../state_media.dart';
import '../../app_log.dart';
import '../../app_preferences.dart';
import '../../appearance_settings.dart';
import '../../decoder_status.dart';
import '../../network_proxy.dart';
import '../../piped_streams.dart';
import '../../player_settings.dart';
import '../../progress_line.dart';
import '../../translation.dart';
import '../../video_codec.dart';
import '../../widgets/pilinara_settings_tiles.dart';
import '../../windows_video_info.dart';
import '../common.dart';
import '../format_policy_dialogs.dart';
import '../player_shortcuts.dart';
import '../theme.dart';
import 'account_settings.dart';
import 'relay_servers_page.dart';
import 'settings_subpages.dart';
import '../../l10n/l10n.dart';

/// The groups in the settings list, in display order, named and ordered
/// like PiliNara's settings page. [account] and [about] are drawn at the
/// bottom of the list without a subtitle, as PiliNara draws them.
enum SettingsCategory {
  privacy('隐私设置', '屏蔽频道、观看历史、播放进度', Icons.privacy_tip_outlined),
  recommend('首页与搜索设置', '首页内容、关键词过滤、隐藏 Shorts 和看完的视频', Icons.explore_outlined),
  subscriptions('订阅设置', '订阅动态的刷新和过滤', Icons.dynamic_feed_outlined),
  video('视频设置', '画质、音质、解码、缓冲、音频输出等', Icons.video_settings_outlined),
  play('播放设置', '倍速、自动播放、播放顺序、字幕、音量、全屏、快捷键等', Icons.touch_app_outlined),
  style('外观设置', '主题、字体、页面过渡动画、导航栏、卡片宽度、封面质量等', Icons.style_outlined),
  extra('其它设置', '空降助手、相关视频、视频简介、组件更新、缓存等', Icons.extension_outlined),
  backup('备份与恢复', '导入、导出和重置设置', Icons.settings_backup_restore_rounded),
  account('Google 账号', '登录、同步订阅和播放列表', Icons.account_circle_outlined),
  about('关于', '版本、日志、诊断信息、开源许可', Icons.info_outline);

  const SettingsCategory(this._title, this._subtitle, this.icon);
  final String _title;
  String get title => tr(_title);
  final String _subtitle;
  String get subtitle => tr(_subtitle);
  final IconData icon;
}

/// One searchable row of a settings group.
class SettingEntry {
  const SettingEntry(this.title, this.builder, {this.subtitle});
  final String title;
  /// Extra words the search matches, such as the mpv option name.
  final String? subtitle;
  final WidgetBuilder builder;

  bool matches(String query) => title.toLowerCase().contains(query) || (subtitle?.toLowerCase().contains(query) ?? false);
}

String qualityLabel(int height) => height == 0 ? tr('自动（按屏幕分辨率）') : '${height}p';

List<(String, String)> get _scaleModes => [
      ('spline36', tr('Spline36（默认）')),
      ('bilinear', tr('Bilinear（最省资源）')),
      ('lanczos', tr('Lanczos（更锐利）')),
      ('ewa_lanczossharp', tr('EWA Lanczos Sharp（最清晰，GPU 负载高）')),
    ];
List<(String, String)> get _cacheModes => [('auto', tr('自动（推荐）')), ('yes', tr('启用')), ('no', tr('禁用'))];
List<(ThemeMode, String)> get themeModes => [(ThemeMode.system, tr('跟随系统')), (ThemeMode.light, tr('浅色')), (ThemeMode.dark, tr('深色'))];
List<(int, String)> get _durations => [(0, tr('不限')), (1, tr('1 分钟')), (3, tr('3 分钟')), (5, tr('5 分钟')), (10, tr('10 分钟')), (20, tr('20 分钟'))];
List<(FeedLevel, String)> get _feedLevels => [(FeedLevel.off, tr('不限')), (FeedLevel.reduce, tr('减少')), (FeedLevel.drop, tr('不推荐'))];
List<(int, String)> get _feedIntervals => [(5, tr('5 分钟')), (10, tr('10 分钟')), (30, tr('30 分钟')), (60, tr('1 小时')), (180, tr('3 小时'))];
List<(int, String)> get _hideTimes => [(2, tr('2 秒')), (3, tr('3 秒（默认）')), (5, tr('5 秒')), (10, tr('10 秒')), (30, tr('30 秒（便于屏幕阅读器）'))];
List<(int, String)> get _volumeMaxes => [(100, tr('100%（不增强）')), (130, '130%'), (150, '150%'), (200, '200%')];

String labelOf<T>(List<(T, String)> values, T value) {
  for (final (key, label) in values) {
    if (key == value) return label;
  }
  return '$value';
}

List<(T, String)> _enumValues<T extends Enum>(List<T> values, String Function(T) label) => [for (final v in values) (v, label(v))];

Widget _icon(IconData icon) => Icon(icon);

List<SettingEntry> settingEntries(SettingsCategory category, AppController controller) {
  final settings = controller.settings;
  final prefs = controller.preferences;
  final appearance = controller.appearance;
  void save(PlayerSettings next) => controller.saveSettings(next);
  void savePrefs(AppPreferences next) => controller.savePreferences(next);
  void saveLooks(AppearanceSettings next) => controller.saveAppearance(next);

  final hardware = settings.hwdec != 'no';
  return switch (category) {
    SettingsCategory.privacy => [
        SettingEntry(tr('屏蔽频道'), (context) => NormalItem(
              title: tr('屏蔽频道'),
              subtitle: prefs.blockedChannels.isEmpty && prefs.blockedChannelNames.isEmpty && prefs.unrecommendedChannels.isEmpty
                  ? tr('手动添加，或在视频卡片、频道页、播放页里选“屏蔽此频道”')
                  : tr('已屏蔽 {0} 个，不推荐 {1} 个', [prefs.blockedChannels.length + prefs.blockedChannelNames.length, prefs.unrecommendedChannels.length]),
              leading: _icon(Icons.block_rounded),
              onTap: () => openBlockedChannels(context, controller),
            ), subtitle: tr('黑名单 不推荐')),
        SettingEntry(tr('记录观看历史'), (context) => SwitchItem(
              title: tr('记录观看历史'),
              subtitle: tr('关闭后新看的视频不再出现在“历史”和首页，也不再记录搜索词'),
              leading: _icon(Icons.history_rounded),
              value: prefs.recordHistory,
              onChanged: (v) => savePrefs(prefs.copyWith(recordHistory: v)),
            )),
        SettingEntry(tr('记录播放进度'), (context) => SwitchItem(
              title: tr('记录播放进度'),
              subtitle: tr('用于继续播放和卡片上的进度条'),
              leading: _icon(Icons.timelapse_rounded),
              value: prefs.recordProgress,
              onChanged: (v) => savePrefs(prefs.copyWith(recordProgress: v)),
            )),
        SettingEntry(tr('清空观看历史'), (context) => NormalItem(
              title: tr('清空观看历史'),
              subtitle: tr('{0} 条记录', [controller.history.length]),
              leading: _icon(Icons.delete_sweep_outlined),
              onTap: () async {
                if (await confirmDialog(context, title: tr('清空观看历史？'), content: tr('只删除本机的记录，不影响 YouTube 账号。'))) await controller.clearHistory();
              },
            )),
        SettingEntry(tr('清空搜索记录'), (context) => NormalItem(
              title: tr('清空搜索记录'),
              subtitle: tr('搜索框下方显示的最近搜索'),
              leading: _icon(Icons.manage_search_rounded),
              onTap: () async {
                if (await confirmDialog(context, title: tr('清空搜索记录？'), content: tr('只删除本机保存的搜索词。'))) await controller.clearSearchHistory();
              },
            )),
        SettingEntry(tr('清空播放进度'), (context) => NormalItem(
              title: tr('清空播放进度'),
              subtitle: tr('所有视频都从头开始播放'),
              leading: _icon(Icons.restart_alt_rounded),
              onTap: () async {
                if (await confirmDialog(context, title: tr('清空播放进度？'), content: tr('“继续观看”和卡片上的进度条会一并清空。'))) controller.clearProgress();
              },
            )),
      ],
    SettingsCategory.recommend => [
        SettingEntry(tr('首页显示为你推荐'), (context) => SwitchItem(
              title: tr('首页显示“为你推荐”'),
              subtitle: tr('根据本机的观看历史、收藏和关注在本机计算，不上传'),
              leading: _icon(Icons.auto_awesome_outlined),
              value: prefs.homeShowRecommended,
              onChanged: (v) => savePrefs(prefs.copyWith(homeShowRecommended: v)),
            )),
        SettingEntry(tr('推荐中的 Shorts 短视频'), (context) => NormalItem(
              title: tr('推荐中的 Shorts 短视频'),
              subtitle: tr('当前：{0}；Shorts 按 YouTube Shorts 标记或短时长识别，和普通竖屏视频独立；只影响首页和探索的为你推荐', [labelOf(_feedLevels, prefs.feedShorts)]),
              leading: _icon(Icons.smartphone_rounded),
              onTap: () => pickFromDialog<FeedLevel>(context, title: tr('推荐中的 Shorts 短视频'), value: prefs.feedShorts, values: _feedLevels, onSelected: (v) => savePrefs(prefs.copyWith(feedShorts: v))),
            ), subtitle: tr('短视频 减少 不推荐')),
        SettingEntry(tr('推荐中的竖屏视频'), (context) => NormalItem(
              title: tr('推荐中的竖屏视频'),
              subtitle: tr('当前：{0}；按已知画面尺寸的高大于宽识别，和 Shorts 独立；只影响首页和探索的为你推荐', [labelOf(_feedLevels, prefs.feedVertical)]),
              leading: _icon(Icons.stay_current_portrait_rounded),
              onTap: () => pickFromDialog<FeedLevel>(context, title: tr('推荐中的竖屏视频'), value: prefs.feedVertical, values: _feedLevels, onSelected: (v) => savePrefs(prefs.copyWith(feedVertical: v))),
            ), subtitle: tr('竖屏 减少 不推荐')),
        SettingEntry(tr('屏蔽争议宗教团体'), (context) => NormalItem(
              title: tr('屏蔽争议宗教团体'),
              subtitle: prefs.blockGroups
                  ? tr('已开启，屏蔽 {0} 个团体；输入完全正确的频道名仍能搜到', [blockedGroups.where(prefs.groupOn).length])
                  : tr('已关闭'),
              leading: _icon(Icons.block_rounded),
              onTap: () => openBlockedGroups(context, controller),
            ), subtitle: tr('法轮功 全能神 新天地 统一教 邪教 异端')),
        SettingEntry(tr('屏蔽官方宣传媒体'), (context) => NormalItem(
              title: tr('屏蔽官方宣传媒体'),
              subtitle: prefs.blockStateMedia
                  ? tr('已开启，屏蔽 {0} 类媒体', [stateMedia.where((g) => prefs.groupOn(g, media: true)).length])
                  : tr('已关闭'),
              leading: _icon(Icons.campaign_outlined),
              onTap: () => openStateMedia(context, controller),
            ), subtitle: tr('CGTN 央视 RT 政府 宣传 官方媒体')),
        SettingEntry(tr('清空不感兴趣'), (context) => NormalItem(
              title: tr('清空“不感兴趣”记录'),
              subtitle: tr('{0} 个视频', [controller.homeFeed?.notInterested.videos.length ?? 0]),
              leading: _icon(Icons.thumb_down_off_alt_outlined),
              onTap: () async {
                if (await confirmDialog(context, title: tr('清空“不感兴趣”记录？'), content: tr('被标记的视频和频道会重新出现在推荐里。'))) await controller.clearNotInterested();
              },
            )),
        SettingEntry(tr('首页显示继续观看'), (context) => SwitchItem(
              title: tr('首页显示“继续观看”'),
              subtitle: tr('没看完的视频'),
              leading: _icon(Icons.play_circle_outline_rounded),
              value: prefs.homeShowContinue,
              onChanged: (v) => savePrefs(prefs.copyWith(homeShowContinue: v)),
            )),
        SettingEntry(tr('首页显示最近观看'), (context) => SwitchItem(
              title: tr('首页显示“最近观看”'),
              leading: _icon(Icons.history_toggle_off_rounded),
              value: prefs.homeShowRecent,
              onChanged: (v) => savePrefs(prefs.copyWith(homeShowRecent: v)),
            )),
        SettingEntry(tr('标题关键词过滤'), (context) => NormalItem(
              title: tr('标题关键词过滤'),
              subtitle: prefs.blockedKeywords.isEmpty ? tr('点击添加') : tr('{0} 个关键词', [prefs.blockedKeywords.length]),
              leading: _icon(Icons.filter_alt_outlined),
              onTap: () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (context) => ListEditorDialog(title: tr('标题关键词过滤'), initialItems: prefs.blockedKeywords, hintText: tr('输入关键词，不区分大小写'), itemLabel: tr('关键词')),
                );
                if (result != null) savePrefs(controller.preferences.copyWith(blockedKeywords: result));
              },
            ), subtitle: tr('屏蔽 关键字')),
        SettingEntry(tr('隐藏 Shorts 短视频'), (context) => SwitchItem(
              title: tr('隐藏 Shorts 短视频'),
              subtitle: tr('隐藏 1 分钟以内的视频'),
              leading: _icon(Icons.smartphone_rounded),
              value: prefs.hideShorts,
              onChanged: (v) => savePrefs(prefs.copyWith(hideShorts: v)),
            )),
        SettingEntry(tr('最短视频时长'), (context) => NormalItem(
              title: tr('最短视频时长'),
              subtitle: tr('当前：{0}，更短的视频不显示', [labelOf(_durations, prefs.minDurationMinutes)]),
              leading: _icon(Icons.timer_outlined),
              onTap: () => pickFromDialog<int>(context, title: tr('最短视频时长'), value: prefs.minDurationMinutes, values: _durations, onSelected: (v) => savePrefs(prefs.copyWith(minDurationMinutes: v))),
            ), subtitle: tr('时长过滤')),
        SettingEntry(tr('隐藏已看完的视频'), (context) => SwitchItem(
              title: tr('隐藏已看完的视频'),
              subtitle: tr('根据本机的播放进度判断'),
              leading: _icon(Icons.visibility_off_outlined),
              value: prefs.hideWatched,
              onChanged: (v) => savePrefs(prefs.copyWith(hideWatched: v)),
            )),
      ],
    SettingsCategory.subscriptions => [
        SettingEntry(tr('进入订阅页时自动刷新'), (context) => SwitchItem(
              title: tr('进入订阅页时自动刷新'),
              subtitle: tr('关闭后只在点击刷新按钮时更新'),
              leading: _icon(Icons.sync_rounded),
              value: prefs.feedAutoRefresh,
              onChanged: (v) => savePrefs(prefs.copyWith(feedAutoRefresh: v)),
            )),
        SettingEntry(tr('自动刷新间隔'), (context) => NormalItem(
              title: tr('自动刷新间隔'),
              subtitle: tr('当前：{0}，间隔内再次进入不重新加载', [labelOf(_feedIntervals, prefs.feedRefreshMinutes)]),
              leading: _icon(Icons.update_rounded),
              enabled: prefs.feedAutoRefresh,
              onTap: () => pickFromDialog<int>(context, title: tr('自动刷新间隔'), value: prefs.feedRefreshMinutes, values: _feedIntervals, onSelected: (v) => savePrefs(prefs.copyWith(feedRefreshMinutes: v))),
            )),
        SettingEntry(tr('订阅动态也应用过滤'), (context) => SwitchItem(
              title: tr('订阅动态也应用过滤'),
              subtitle: tr('关键词、Shorts、时长和看完的视频；屏蔽的频道总是隐藏'),
              leading: _icon(Icons.filter_list_rounded),
              value: prefs.filterSubscriptions,
              onChanged: (v) => savePrefs(prefs.copyWith(filterSubscriptions: v)),
            )),
        SettingEntry(tr('立即刷新订阅动态'), (context) => NormalItem(
              title: tr('立即刷新订阅动态'),
              subtitle: tr('已关注 {0} 个频道', [controller.library?.channels.length ?? 0]),
              leading: _icon(Icons.refresh_rounded),
              onTap: () => controller.library?.refreshFeed(force: true),
            )),
      ],
    SettingsCategory.video => [
        SettingEntry(tr('开启硬解'), (context) => SwitchItem(
              title: tr('开启硬解'),
              subtitle: tr('以较低功耗播放视频，若异常卡死请关闭'),
              leading: _icon(Icons.memory_outlined),
              value: hardware,
              onChanged: (value) => save(settings.copyWith(hwdec: value ? 'auto-safe' : 'no')),
            ), subtitle: tr('硬件解码 hwdec')),
        SettingEntry(tr('硬解模式'), (context) => NormalItem(
              title: tr('硬解模式'),
              subtitle: hardware ? tr('当前：{0}（此项即 mpv 的 --hwdec，按顺序尝试）', [settings.hwdec]) : tr('已关闭硬解'),
              leading: _icon(Icons.developer_board_outlined),
              enabled: hardware,
              onTap: () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (context) => OrderedMultiSelectDialog<String>(
                    title: tr('硬解模式'),
                    initValues: settings.hwdec.split(','),
                    values: [for (final (name, label) in hwdecChoices) (name, name, label)],
                  ),
                );
                if (result != null && result.isNotEmpty) save(controller.settings.copyWith(hwdec: result.join(',')));
              },
            ), subtitle: 'hwdec D3D11VA D3D12VA DXVA2 NVDEC Vulkan AMF QSV'),
        SettingEntry(tr('硬解编码'), (context) => NormalItem(
              title: tr('硬解编码'),
              subtitle: tr('当前：{0}（此项即 mpv 的 --hwdec-codecs）', [settings.hwdecCodecs]),
              leading: _icon(Icons.video_file_outlined),
              enabled: hardware,
              onTap: () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (context) => OrderedMultiSelectDialog<String>(
                    title: tr('只对这些编码尝试硬解'),
                    ordered: false,
                    initValues: settings.hwdecCodecs.split(','),
                    values: [for (final codec in hwdecCodecChoices) (codec, codec, null)],
                  ),
                );
                if (result != null && result.isNotEmpty) {
                  save(controller.settings.copyWith(hwdecCodecs: [for (final c in hwdecCodecChoices) if (result.contains(c)) c].join(',')));
                }
              },
            ), subtitle: 'hwdec-codecs h264 hevc vp9 av1'),
        SettingEntry(tr('D3D11VA 零拷贝'), (context) => SwitchItem(
              title: tr('D3D11VA 零拷贝'),
              subtitle: tr('此项即 mpv 的 --d3d11va-zero-copy，只对 d3d11va 有效；其他解码器选不带 -copy 的模式即为零拷贝'),
              leading: _icon(Icons.bolt_outlined),
              enabled: hardware,
              value: settings.d3d11vaZeroCopy,
              onChanged: (v) => save(settings.copyWith(d3d11vaZeroCopy: v)),
            ), subtitle: 'd3d11va-zero-copy'),
        SettingEntry(tr('直接解码到显存'), (context) => PopupItem<String>(
              title: tr('直接解码到显存（vd-lavc-dr）'),
              leading: _icon(Icons.memory_rounded),
              value: settings.directRendering,
              values: [('auto', tr('auto（默认）')), ('yes', 'yes'), ('no', 'no')],
              onSelected: (v) => save(settings.copyWith(directRendering: v)),
            ), subtitle: 'vd-lavc-dr direct rendering'),
        SettingEntry(tr('默认画质'), (context) => NormalItem(
              title: tr('默认画质'),
              subtitle: tr('当前：{0}', [qualityLabel(settings.maxHeight)]),
              leading: _icon(Icons.high_quality_outlined),
              onTap: () => pickFromDialog<int>(context, title: tr('默认画质'), value: settings.maxHeight, values: [for (final h in qualityHeights) (h, qualityLabel(h))], onSelected: controller.setMaxHeight),
            ), subtitle: tr('清晰度 分辨率')),
        SettingEntry(tr('播放策略'), (context) => NormalItem(
              title: tr('播放策略'),
              subtitle: '${settings.strategy.label}：${settings.strategy.description}',
              leading: _icon(Icons.movie_filter_outlined),
              onTap: () => pickPlaybackStrategy(context, settings.strategy, (v) => save(settings.copyWith(strategy: v))),
            ), subtitle: tr('视频格式 编码 H.264 VP9 AV1 智能自动 画质优先 低资源占用')),
        for (final codec in VideoCodec.values)
          SettingEntry(tr('禁用 {0}', [codec.label]), (context) => SwitchItem(
                title: tr('禁用 {0}', [codec.label]),
                subtitle: codec == VideoCodec.values.first ? disabledCodecsNote : null,
                leading: _icon(Icons.block_outlined),
                value: settings.disabledCodecs.contains(codec),
                onChanged: (v) => save(settings.copyWith(disabledCodecs: withCodecDisabled(settings.disabledCodecs, codec, v))),
              ), subtitle: tr('视频格式 禁用视频编码')),
        SettingEntry(tr('当前规则'), (context) => ListTile(
              dense: true,
              leading: _icon(Icons.rule_rounded),
              title: Text(FormatPolicy.summary(settings), style: _note(context)),
            ), subtitle: tr('视频格式')),
        SettingEntry(tr('默认音质'), (context) => NormalItem(
              title: tr('默认音质'),
              subtitle: tr('当前：{0}', [settings.audioQuality.label]),
              leading: _icon(Icons.music_note_outlined),
              onTap: () => pickFromDialog<AudioQuality>(
                context,
                title: tr('默认音质'),
                value: settings.audioQuality,
                values: _enumValues(AudioQuality.values, (q) => q.label),
                onSelected: (v) => save(settings.copyWith(audioQuality: v)),
              ),
            )),
        SettingEntry(tr('音频输出设备'), (context) {
          final devices = controller.audioDevices;
          String describe(String name) => name == 'auto'
              ? tr('自动（系统默认）')
              : devices.where((d) => d.name == name).map((d) => d.description.isEmpty ? d.name : d.description).firstOrNull ?? name;
          return NormalItem(
            title: tr('音频输出设备'),
            subtitle: tr('当前：{0}', [describe(settings.audioDevice)]),
            leading: _icon(Icons.speaker_outlined),
            onTap: () => pickFromDialog<String>(
              context,
              title: tr('音频输出设备'),
              value: settings.audioDevice,
              values: [('auto', tr('自动（系统默认）')), for (final d in devices) if (d.name != 'auto') (d.name, describe(d.name))],
              onSelected: (v) => save(settings.copyWith(audioDevice: v)),
            ),
          );
        }, subtitle: tr('声卡 耳机 音箱')),
        SettingEntry(tr('音量均衡'), (context) => NormalItem(
              title: tr('音量均衡'),
              subtitle: tr('当前：{0}', [audioFilterPresets.where((p) => p.$1 == settings.audioFilter).map((p) => p.$2).firstOrNull ?? tr('自定义 {0}', [settings.audioFilter])]),
              leading: _icon(Icons.equalizer_rounded),
              onTap: () => _pickAudioFilter(context, controller),
            ), subtitle: tr('loudnorm dynaudnorm af 响度')),
        SettingEntry(tr('画面与音画同步调节'), (context) => NormalItem(
              title: tr('画面与音画同步调节'),
              subtitle: settings.picture.isEmpty && settings.audioDelayMs == 0 ? tr('亮度、对比度、饱和度、伽马、色调、音频延迟') : tr('已调整'),
              leading: _icon(Icons.tune_rounded),
              onTap: () => openPictureSettings(context, controller),
            ), subtitle: tr('亮度 对比度 饱和度 伽马 色调 音频延迟 audio-delay')),
        SettingEntry(tr('播放来源'), (context) => NormalItem(
              title: tr('播放来源'),
              subtitle: tr('当前：{0}{1}。Piped、Invidious 服务器替你从 YouTube 取视频，可避开限速，但它们会知道你看了哪个视频；失败、直播或开着字幕时直接连接 YouTube；YouTube 返回 429 时会自动试用它们', [settings.playbackSource.label, switch (settings.playbackSource) { PlaybackSource.pipedCustom => ' ${settings.pipedServer}', PlaybackSource.invidiousCustom => ' ${settings.invidiousServer}', _ => '' }]),
              leading: _icon(Icons.dns_outlined),
              onTap: () => pickFromDialog<PlaybackSource>(
                context,
                title: tr('播放来源'),
                value: settings.playbackSource,
                values: _enumValues(PlaybackSource.values, (s) => s.label),
                onSelected: (source) async {
                  if (!source.isCustom) return save(settings.copyWith(playbackSource: source));
                  if (context.mounted) await openRelayServers(context, controller, source.relay!);
                },
              ),
            ), subtitle: tr('Piped Invidious 服务器 限速 实例 instance 429')),
        SettingEntry(tr('Piped 服务器'), (context) => NormalItem(
              title: tr('Piped 服务器'),
              subtitle: settings.playbackSource == PlaybackSource.pipedCustom ? tr('当前：{0}', [settings.pipedServer]) : tr('当前：自动选择最快的服务器。可测速、手动选择，列表每天自动更新'),
              leading: _icon(Icons.speed_rounded),
              onTap: () => openRelayServers(context, controller, RelayKind.piped),
            ), subtitle: tr('Piped 服务器 测速 列表 更新 instance')),
        SettingEntry(tr('Invidious 实例'), (context) => NormalItem(
              title: tr('Invidious 实例'),
              subtitle: settings.playbackSource == PlaybackSource.invidiousCustom ? tr('当前：{0}', [settings.invidiousServer]) : tr('当前：自动选择最快的实例。可测速、手动选择，列表每天自动更新'),
              leading: _icon(Icons.speed_rounded),
              onTap: () => openRelayServers(context, controller, RelayKind.invidious),
            ), subtitle: tr('Invidious 实例 测速 列表 更新 instance')),
        SettingEntry(tr('网络代理'), (context) {
          final proxy = controller.proxy;
          final now = proxy.url == null ? tr('当前直接连接') : tr('当前使用 {0}{1}', [proxy.url, proxy.isHttp ? '' : tr('（视频流不支持此类代理，视频流直接连接）')]);
          return NormalItem(
            title: tr('网络代理'),
            subtitle: '${settings.proxyMode.label}。$now',
            leading: _icon(Icons.vpn_lock_outlined),
            onTap: () => pickFromDialog<ProxyMode>(
              context,
              title: tr('网络代理'),
              value: settings.proxyMode,
              values: _enumValues(ProxyMode.values, (m) => m.label),
              onSelected: (mode) async {
                if (mode != ProxyMode.custom) return save(settings.copyWith(proxyMode: mode));
                await _editProxy(context, controller);
              },
            ),
          );
        }, subtitle: tr('proxy 代理 Clash v2rayN 系统代理 http-proxy')),
        SettingEntry(tr('缓冲模式'), (context) => NormalItem(
              title: tr('缓冲模式'),
              subtitle: tr('当前：{0}。只使用内存，不写入磁盘', [labelOf(_cacheModes, settings.cacheMode)]),
              leading: _icon(Icons.storage_outlined),
              onTap: () => pickFromDialog<String>(context, title: tr('缓冲模式'), value: settings.cacheMode, values: _cacheModes, onSelected: (value) => save(settings.copyWith(cacheMode: value))),
            ), subtitle: tr('网络缓存')),
        SettingEntry(tr('缓冲大小'), (context) => NormalItem(
              title: tr('缓冲大小'),
              subtitle: tr('当前：{0} MB，预读占用的内存上限', [settings.cacheMemoryMb]),
              leading: _icon(Icons.sd_card_outlined),
              onTap: () => pickWithSlider(context, title: tr('缓冲大小'), value: settings.cacheMemoryMb.toDouble(), min: 16, max: 512, divisions: 31, suffix: ' MB', onSelected: (v) => save(settings.copyWith(cacheMemoryMb: v.round()))),
            ), subtitle: tr('内存上限')),
        SettingEntry(tr('缓冲时长'), (context) => NormalItem(
              title: tr('缓冲时长'),
              subtitle: tr('当前：{0} 秒，最多预读多久的视频', [settings.cacheSeconds]),
              leading: _icon(Icons.timer_outlined),
              onTap: () => pickWithSlider(context, title: tr('缓冲时长'), value: settings.cacheSeconds.toDouble(), min: 1, max: 300, divisions: 299, suffix: tr(' 秒'), onSelected: (v) => save(settings.copyWith(cacheSeconds: v.round()))),
            ), subtitle: tr('预读时间')),
        SettingEntry(tr('视频同步'), (context) => NormalItem(
              title: tr('视频同步'),
              subtitle: tr('当前：{0}，{1}（此项即 mpv 的 --video-sync）', [settings.videoSync.mpvValue, settings.videoSync.label]),
              leading: _icon(Icons.sync_alt_rounded),
              onTap: () => pickFromDialog<VideoSync>(
                context,
                title: tr('视频同步'),
                value: settings.videoSync,
                values: _enumValues(VideoSync.values, (v) => v.label),
                onSelected: (v) => save(settings.copyWith(videoSync: v)),
              ),
            ), subtitle: 'video-sync display-resample'),
        SettingEntry(tr('自动同步'), (context) => NormalItem(
              title: tr('自动同步'),
              subtitle: tr('当前：{0}（此项即 mpv 的 --autosync，0 为关闭）', [settings.autosync == 0 ? tr('关闭') : settings.autosync]),
              leading: _icon(Icons.sync_rounded),
              onTap: () => pickWithSlider(context, title: tr('自动同步'), value: settings.autosync.toDouble(), min: 0, max: 30, divisions: 30, suffix: '', onSelected: (v) => save(controller.settings.copyWith(autosync: v.round()))),
            ), subtitle: 'autosync'),
        SettingEntry(tr('视频缩放算法'), (context) => NormalItem(
              title: tr('视频缩放算法'),
              subtitle: tr('当前：{0}', [labelOf(_scaleModes, settings.scale)]),
              leading: _icon(Icons.photo_size_select_large_rounded),
              onTap: () => pickFromDialog<String>(context, title: tr('视频缩放算法'), value: settings.scale, values: _scaleModes, onSelected: (value) => save(settings.copyWith(scale: value))),
            ), subtitle: tr('scale 超分辨率')),
        SettingEntry(tr('色带消除'), (context) => SwitchItem(
              title: tr('色带消除'),
              subtitle: tr('减轻渐变中的色带，略增 GPU 负载'),
              leading: _icon(Icons.gradient_rounded),
              value: settings.deband,
              onChanged: (value) => save(settings.copyWith(deband: value)),
            ), subtitle: 'deband'),
        SettingEntry(tr('帧插值'), (context) => SwitchItem(
              title: tr('帧插值'),
              subtitle: tr('让画面更平滑，会增加 GPU 负载。下一段视频生效'),
              leading: _icon(Icons.animation_rounded),
              value: settings.interpolation,
              onChanged: (value) => save(settings.copyWith(interpolation: value)),
            ), subtitle: 'interpolation'),
        SettingEntry(tr('解码状态'), (context) => _DecoderStatus(controller: controller), subtitle: tr('GPU 当前解码方式 VP9 AV1 视频扩展')),
        SettingEntry(tr('自定义 mpv 参数'), (context) {
          final (options, rejected) = parseMpvConf(settings.mpvConf);
          return NormalItem(
            title: tr('自定义 mpv 参数'),
            subtitle: options.isEmpty ? tr('按 mpv.conf 格式填写，例如 d3d11va-zero-copy=yes') : tr('已设置 {0} 项{1}', [options.length, rejected.isEmpty ? '' : tr('，{0} 行无法使用', [rejected.length])]),
            leading: _icon(Icons.code_rounded),
            onTap: () => _editMpvConf(context, controller),
          );
        }, subtitle: tr('mpv.conf 自定义参数')),
        SettingEntry(tr('高级 libmpv 参数'), (context) => _AdvancedOptions(settings: settings, onReset: () => save(PlayerSettings(cachePath: settings.cachePath, decoderResults: settings.decoderResults))), subtitle: tr('恢复默认设置')),
      ],
    SettingsCategory.play => [
        SettingEntry(tr('倍速设置'), (context) => NormalItem(
              title: tr('倍速设置'),
              subtitle: tr('默认 {0}x，{1} 档可选', [trimSpeed(settings.defaultSpeed), settings.speeds.length]),
              leading: _icon(Icons.speed_rounded),
              onTap: () => openPlaySpeed(context, controller),
            ), subtitle: tr('播放速度')),
        SettingEntry(tr('自动播放'), (context) => SwitchItem(
              title: tr('自动播放'),
              subtitle: tr('打开视频后立即开始播放'),
              leading: _icon(Icons.play_arrow_rounded),
              value: prefs.autoPlay,
              onChanged: (v) => savePrefs(prefs.copyWith(autoPlay: v)),
            )),
        SettingEntry(tr('播放顺序'), (context) => PopupItem<PlayOrder>(
              title: tr('播放顺序'),
              leading: _icon(Icons.repeat_rounded),
              value: settings.playOrder,
              values: _enumValues(PlayOrder.values, (o) => o.label),
              onSelected: controller.setPlayOrder,
            ), subtitle: tr('自动连播 循环')),
        SettingEntry(tr('从上次位置继续播放'), (context) => SwitchItem(
              title: tr('从上次位置继续播放'),
              subtitle: tr('再次打开没看完的视频时跳到上次的位置'),
              leading: _icon(Icons.history_rounded),
              value: prefs.resumePlayback,
              onChanged: (v) => savePrefs(prefs.copyWith(resumePlayback: v)),
            ), subtitle: tr('续播 进度')),
        SettingEntry(tr('应用内小窗'), (context) => SwitchItem(
              title: tr('应用内小窗'),
              subtitle: tr('离开播放页时让视频继续在小窗里播放；关闭则停止播放'),
              leading: _icon(Icons.picture_in_picture_rounded),
              value: prefs.miniPlayer,
              onChanged: (v) => savePrefs(prefs.copyWith(miniPlayer: v)),
            ), subtitle: tr('小窗 离开播放页 悬浮')),
        SettingEntry(tr('看完后从稍后观看移除'), (context) => SwitchItem(
              title: tr('看完后从稍后观看移除'),
              subtitle: tr('稍后观看里的视频播到结尾时自动移出列表'),
              leading: _icon(Icons.watch_later_outlined),
              value: prefs.watchLaterAutoRemove,
              onChanged: (v) => savePrefs(prefs.copyWith(watchLaterAutoRemove: v)),
            ), subtitle: tr('稍后观看 自动移除')),
        SettingEntry(tr('字幕设置'), (context) => NormalItem(
              title: tr('字幕设置'),
              subtitle: '${settings.subtitleMode.label} · ${settings.subtitleLanguage.label} · ${settings.subtitleScale.toStringAsFixed(1)}×',
              leading: _icon(Icons.subtitles_outlined),
              onTap: () => openSubtitleSettings(context, controller),
            ), subtitle: tr('自动启用字幕 字幕语言 字幕大小')),
        SettingEntry(tr('播放器音量'), (context) => NormalItem(
              title: tr('播放器音量'),
              subtitle: tr('启动时的音量：{0}%', [settings.defaultVolume]),
              leading: _icon(Icons.volume_up_outlined),
              onTap: () => pickWithSlider(context, title: tr('播放器音量'), value: settings.defaultVolume.toDouble(), min: 0, max: 100, divisions: 20, suffix: '%', onSelected: (v) => save(settings.copyWith(defaultVolume: v.round()))),
            )),
        SettingEntry(tr('最高音量'), (context) => NormalItem(
              title: tr('最高音量'),
              subtitle: tr('当前：{0}，超过 100% 可放大声音较小的视频', [labelOf(_volumeMaxes, settings.volumeMax)]),
              leading: _icon(Icons.campaign_outlined),
              onTap: () => pickFromDialog<int>(context, title: tr('最高音量'), value: settings.volumeMax, values: _volumeMaxes, onSelected: (v) => save(settings.copyWith(volumeMax: v))),
            ), subtitle: tr('音量增强')),
        SettingEntry(tr('自动全屏'), (context) => SwitchItem(
              title: tr('自动全屏'),
              subtitle: tr('视频开始播放时进入全屏'),
              leading: _icon(Icons.fullscreen_rounded),
              value: prefs.autoFullscreen,
              onChanged: (v) => savePrefs(prefs.copyWith(autoFullscreen: v)),
            )),
        SettingEntry(tr('自动退出全屏'), (context) => SwitchItem(
              title: tr('自动退出全屏'),
              subtitle: tr('视频播放结束、没有下一个时退出全屏'),
              leading: _icon(Icons.fullscreen_exit_rounded),
              value: prefs.exitFullscreenOnEnd,
              onChanged: (v) => savePrefs(prefs.copyWith(exitFullscreenOnEnd: v)),
            )),
        SettingEntry(tr('最小化时暂停'), (context) => SwitchItem(
              title: tr('最小化时暂停/还原时播放'),
              leading: _icon(Icons.minimize_rounded),
              value: prefs.pauseOnMinimize,
              onChanged: (v) => savePrefs(prefs.copyWith(pauseOnMinimize: v)),
            ), subtitle: tr('后台播放')),
        SettingEntry(tr('最小化时只听声音'), (context) => SwitchItem(
              title: tr('最小化时只听声音'),
              subtitle: tr('窗口最小化或收到托盘时不解码画面，还原后恢复'),
              leading: _icon(Icons.headphones_outlined),
              value: prefs.audioOnlyInBackground,
              onChanged: (v) => savePrefs(prefs.copyWith(audioOnlyInBackground: v)),
            ), subtitle: tr('后台播放')),
        SettingEntry(tr('关闭时最小化到托盘'), (context) => SwitchItem(
              title: tr('关闭时最小化到托盘'),
              subtitle: tr('点关闭按钮时隐藏到托盘图标，继续播放；从托盘菜单退出'),
              leading: _icon(Icons.call_to_action_outlined),
              value: prefs.closeToTray,
              onChanged: (v) => savePrefs(prefs.copyWith(closeToTray: v)),
            ), subtitle: tr('托盘 后台播放')),
        SettingEntry(tr('延长播放控件显示时间'), (context) => NormalItem(
              title: tr('播放控件显示时间'),
              subtitle: tr('鼠标不动 {0} 后隐藏', [labelOf(_hideTimes, prefs.controlsHideSeconds)]),
              leading: _icon(Icons.touch_app_outlined),
              onTap: () => pickFromDialog<int>(context, title: tr('播放控件显示时间'), value: prefs.controlsHideSeconds, values: _hideTimes, onSelected: (v) => savePrefs(prefs.copyWith(controlsHideSeconds: v))),
            ), subtitle: tr('控制栏 隐藏')),
        SettingEntry(tr('最多重放曲线'), (context) => SwitchItem(
              title: tr('进度条上方显示“最多重放”曲线'),
              subtitle: tr('热门视频才有，看哪一段被反复观看'),
              leading: _icon(Icons.area_chart_outlined),
              value: prefs.showHeatmap,
              onChanged: (v) => savePrefs(prefs.copyWith(showHeatmap: v)),
            ), subtitle: tr('热度 进度条 最多重放')),
        SettingEntry(tr('底部细进度条'), (context) => NormalItem(
              title: tr('底部细进度条'),
              subtitle: tr('当前：{0}；播放控件隐藏时，画面底部的一条细线', [prefs.progressLine.label]),
              leading: _icon(Icons.linear_scale_rounded),
              onTap: () => pickFromDialog<ProgressLine>(context, title: tr('底部细进度条'), value: prefs.progressLine, values: [for (final v in ProgressLine.values) (v, v.label)], onSelected: (v) => savePrefs(prefs.copyWith(progressLine: v))),
            ), subtitle: tr('进度条 迷你 隐藏')),
        SettingEntry(tr('启用键盘控制'), (context) => SwitchItem(
              title: tr('启用键盘控制'),
              subtitle: tr('空格暂停、方向键快进和音量、F 全屏等'),
              leading: _icon(Icons.keyboard_outlined),
              value: prefs.keyboardShortcuts,
              onChanged: (v) => savePrefs(prefs.copyWith(keyboardShortcuts: v)),
            ), subtitle: tr('快捷键')),
        SettingEntry(tr('快进/快退时长'), (context) => NormalItem(
              title: tr('快进/快退时长'),
              subtitle: tr('← → 方向键：{0} 秒', [prefs.seekSeconds]),
              leading: _icon(Icons.fast_forward_outlined),
              enabled: prefs.keyboardShortcuts,
              onTap: () => pickWithSlider(context, title: tr('快进/快退时长'), value: prefs.seekSeconds.toDouble(), min: 1, max: 30, divisions: 29, suffix: tr(' 秒'), onSelected: (v) => savePrefs(prefs.copyWith(seekSeconds: v.round()))),
            ), subtitle: tr('方向键')),
        SettingEntry(tr('大步快进/快退时长'), (context) => NormalItem(
              title: tr('大步快进/快退时长'),
              subtitle: tr('J / L 键：{0} 秒', [prefs.longSeekSeconds]),
              leading: _icon(Icons.double_arrow_rounded),
              enabled: prefs.keyboardShortcuts,
              onTap: () => pickWithSlider(context, title: tr('大步快进/快退时长'), value: prefs.longSeekSeconds.toDouble(), min: 5, max: 120, divisions: 23, suffix: tr(' 秒'), onSelected: (v) => savePrefs(prefs.copyWith(longSeekSeconds: v.round()))),
            )),
        SettingEntry(tr('音量调节步长'), (context) => NormalItem(
              title: tr('音量调节步长'),
              subtitle: tr('↑ ↓ 方向键和滚轮：每次 {0}%', [prefs.volumeStep]),
              leading: _icon(Icons.volume_down_outlined),
              onTap: () => pickWithSlider(context, title: tr('音量调节步长'), value: prefs.volumeStep.toDouble(), min: 1, max: 20, divisions: 19, suffix: '%', onSelected: (v) => savePrefs(prefs.copyWith(volumeStep: v.round()))),
            )),
        SettingEntry(tr('快捷键说明'), (context) => NormalItem(
              title: tr('快捷键说明'),
              subtitle: tr('查看所有播放器快捷键'),
              leading: _icon(Icons.help_outline_rounded),
              onTap: () => showShortcutHelp(context, controller.preferences),
            )),
      ],
    SettingsCategory.style => [
        SettingEntry(tr('主题模式'), (context) => PopupItem<ThemeMode>(
              title: tr('主题模式'),
              leading: _icon(Icons.brightness_6_outlined),
              value: appearance.themeMode,
              values: themeModes,
              onSelected: (mode) => saveLooks(appearance.copyWith(themeMode: mode)),
            ), subtitle: tr('深色 浅色')),
        SettingEntry(tr('纯黑主题'), (context) => SwitchItem(
              title: tr('纯黑主题'),
              subtitle: tr('深色模式使用纯黑背景'),
              leading: _icon(Icons.dark_mode_outlined),
              value: appearance.pureBlack,
              onChanged: (v) => saveLooks(appearance.copyWith(pureBlack: v)),
            ), subtitle: 'AMOLED'),
        SettingEntry(tr('应用主题'), (context) => NormalItem(
              title: tr('应用主题'),
              subtitle: tr('当前：{0} · {1}', [appearance.accentLabel, schemeVariantNames[appearance.schemeVariant]]),
              leading: _icon(Icons.color_lens_outlined),
              trailing: CircleAvatar(radius: 12, backgroundColor: controller.accentColor),
              onTap: () => openColorSelect(context, controller),
            ), subtitle: tr('主题色 颜色 调色板 动态取色')),
        SettingEntry(tr('App 字体设置'), (context) => NormalItem(
              title: tr('App 字体设置'),
              subtitle: tr('{0} · 字号 {1}%', [fontChoices.where((f) => f.$1 == appearance.fontFamily).map((f) => f.$2).firstOrNull ?? tr('系统默认'), (appearance.textScale * 100).round()]),
              leading: _icon(Icons.text_fields_rounded),
              onTap: () => openFontSettings(context, controller),
            ), subtitle: tr('字号 字体大小')),
        SettingEntry(tr('页面过渡动画'), (context) => NormalItem(
              title: tr('页面过渡动画'),
              subtitle: tr('当前：{0}', [appearance.transition.label]),
              leading: _icon(Icons.animation_outlined),
              onTap: () => pickFromDialog<PageTransition>(
                context,
                title: tr('页面过渡动画'),
                value: appearance.transition,
                values: _enumValues(PageTransition.values, (t) => t.label),
                onSelected: (v) => saveLooks(appearance.copyWith(transition: v)),
              ),
            )),
        SettingEntry(tr('导航栏样式'), (context) => PopupItem<NavigationStyle>(
              title: tr('导航栏样式'),
              leading: _icon(Icons.view_sidebar_outlined),
              value: appearance.navigation,
              values: _enumValues(NavigationStyle.values, (n) => n.label),
              onSelected: (v) => saveLooks(appearance.copyWith(navigation: v)),
            ), subtitle: tr('侧边栏 底栏')),
        SettingEntry(tr('默认启动页'), (context) => PopupItem<String>(
              title: tr('默认启动页'),
              leading: _icon(Icons.home_outlined),
              value: prefs.startPage,
              values: startPages,
              onSelected: (v) => savePrefs(prefs.copyWith(startPage: v)),
            )),
        SettingEntry(tr('视频卡片宽度'), (context) => NormalItem(
              title: tr('视频卡片最小宽度'),
              subtitle: tr('当前：{0} 像素，越小每行的视频越多', [appearance.cardWidth.round()]),
              leading: _icon(Icons.grid_view_rounded),
              onTap: () => pickWithSlider(context, title: tr('视频卡片最小宽度'), value: appearance.cardWidth, min: 180, max: 420, divisions: 24, suffix: tr(' 像素'), onSelected: (v) => saveLooks(appearance.copyWith(cardWidth: v))),
            ), subtitle: tr('列宽 列数')),
        SettingEntry(tr('封面图片质量'), (context) => NormalItem(
              title: tr('封面图片质量'),
              subtitle: tr('当前：{0}', [appearance.thumbnailQuality.label]),
              leading: _icon(Icons.image_outlined),
              onTap: () => pickFromDialog<ThumbnailQuality>(
                context,
                title: tr('封面图片质量'),
                value: appearance.thumbnailQuality,
                values: _enumValues(ThumbnailQuality.values, (q) => q.label),
                onSelected: (v) => saveLooks(appearance.copyWith(thumbnailQuality: v)),
              ),
            ), subtitle: tr('缩略图')),
        SettingEntry(tr('视频播放页使用深色主题'), (context) => SwitchItem(
              title: tr('视频播放页使用深色主题'),
              leading: _icon(Icons.contrast_rounded),
              value: appearance.darkWatchPage,
              onChanged: (v) => saveLooks(appearance.copyWith(darkWatchPage: v)),
            )),
        SettingEntry(tr('显示底部状态栏'), (context) => SwitchItem(
              title: tr('显示底部状态栏'),
              subtitle: tr('窗口底部的 libmpv 版本和状态信息'),
              leading: _icon(Icons.horizontal_rule_rounded),
              value: appearance.showStatusBar,
              onChanged: (v) => saveLooks(appearance.copyWith(showStatusBar: v)),
            )),
      ],
    SettingsCategory.extra => [
        SettingEntry(tr('空降助手'), (context) => SwitchItem(
              title: tr('空降助手'),
              subtitle: settings.sponsorBlock ? tr('已开启 · 跳过 {0} 类片段，点击配置', [settings.sponsorCategories.length]) : tr('点击配置'),
              leading: _icon(Icons.flight_takeoff_rounded),
              value: settings.sponsorBlock,
              onChanged: (v) => save(settings.copyWith(sponsorBlock: v)),
              onTap: () => openSponsorBlock(context, controller),
            ), subtitle: tr('SponsorBlock 跳过 赞助 广告')),
        SettingEntry(tr('显示踩数'), (context) => SwitchItem(
              title: tr('显示踩数'),
              subtitle: tr('用 Return YouTube Dislike 估算的踩数，显示在播放页；开启后会把正在看的视频 ID 发给它的服务器'),
              leading: _icon(Icons.thumb_down_alt_outlined),
              value: settings.returnDislike,
              onChanged: (v) => save(settings.copyWith(returnDislike: v)),
            ), subtitle: tr('Return YouTube Dislike 倒赞 点踩')),
        SettingEntry(tr('DeArrow 替换标题'), (context) => SwitchItem(
              title: tr('DeArrow 替换标题'),
              subtitle: tr('用 DeArrow 用户提交的标题替换标题党标题。和空降助手一样只发视频 ID 哈希的前几位，服务器不知道你在看什么'),
              leading: _icon(Icons.title_rounded),
              value: settings.deArrowTitles,
              onChanged: (v) => save(settings.copyWith(deArrowTitles: v)),
            ), subtitle: tr('DeArrow 标题党 标题 封面')),
        SettingEntry(tr('DeArrow 替换封面'), (context) => SwitchItem(
              title: tr('DeArrow 替换封面'),
              subtitle: tr('用 DeArrow 用户选的视频画面替换夸张封面。画面由它的服务器生成，开启后会把有替换封面的视频 ID 发给它'),
              leading: _icon(Icons.image_outlined),
              value: settings.deArrowThumbnails,
              onChanged: (v) => save(settings.copyWith(deArrowThumbnails: v)),
            ), subtitle: tr('DeArrow 封面 缩略图')),
        SettingEntry(tr('视频页显示相关视频'), (context) => SwitchItem(
              title: tr('视频页显示相关视频'),
              subtitle: tr('按标题搜索得到；关闭后自动连播只播放队列'),
              leading: _icon(Icons.video_library_outlined),
              value: prefs.showRelated,
              onChanged: (v) => savePrefs(prefs.copyWith(showRelated: v)),
            )),
        SettingEntry(tr('默认展开视频简介'), (context) => SwitchItem(
              title: tr('默认展开视频简介'),
              leading: _icon(Icons.notes_rounded),
              value: prefs.expandDescription,
              onChanged: (v) => savePrefs(prefs.copyWith(expandDescription: v)),
            )),
        SettingEntry(tr('翻译目标语言'), (context) => PopupItem<String>(
              title: tr('翻译目标语言'),
              leading: _icon(Icons.translate_rounded),
              value: prefs.translateLanguage,
              values: [for (final l in TranslationLanguage.all) (l.code, l.label)],
              onSelected: (v) => savePrefs(prefs.copyWith(translateLanguage: v)),
            ), subtitle: '翻译 字幕 双语 语言 translate Google'),
        SettingEntry(tr('自动检查组件更新'), (context) => SwitchItem(
              title: tr('自动检查组件更新'),
              subtitle: tr('每天检查一次 libmpv、yt-dlp 和 Deno'),
              leading: _icon(Icons.system_update_alt_rounded),
              value: prefs.autoCheckUpdates,
              onChanged: (v) => savePrefs(prefs.copyWith(autoCheckUpdates: v)),
            )),
        SettingEntry(tr('组件管理'), (context) => NormalItem(
              title: tr('组件管理'),
              subtitle: 'libmpv ${controller.tools?.libmpv.current?.label ?? '内置'} · yt-dlp ${controller.tools?.ytDlpVersion ?? '未安装'}',
              leading: _icon(Icons.extension_outlined),
              onTap: () => openComponents(context, controller),
            ), subtitle: tr('libmpv yt-dlp Deno 检查更新 回退')),
        SettingEntry(tr('缓存路径'), (context) => NormalItem(
              title: tr('缓存路径'),
              subtitle: settings.cachePath ?? controller.cacheRoot?.path ?? tr('正在准备…'),
              leading: _icon(Icons.folder_outlined),
              onTap: () => _changeCacheLocation(context, controller),
            ), subtitle: tr('缓存位置')),
        SettingEntry(tr('清理缓存'), (context) => NormalItem(
              title: tr('清理缓存'),
              subtitle: tr('已占用 {0}，只清理 Lumtub 创建的缩略图和临时文件', [formatBytes(controller.cacheBytes)]),
              leading: _icon(Icons.cleaning_services_outlined),
              onTap: controller.clearCache,
            ), subtitle: tr('缓存占用')),
        SettingEntry(tr('数据位置'), (context) => NormalItem(
              title: tr('数据位置'),
              subtitle: tr('{0}\n设置、观看记录、收藏和下载的组件都保存在这里，卸载时会保留', [controller.directories?.root.path ?? tr('正在准备…')]),
              leading: _icon(Icons.inventory_2_outlined),
              onTap: controller.directories == null ? null : () => openExternal(controller.directories!.root.path),
            )),
      ],
    SettingsCategory.backup => [
        SettingEntry(tr('导出设置'), (context) => NormalItem(
              title: tr('导出设置'),
              subtitle: tr('保存为 JSON 文件，不含账号、观看记录和本机路径'),
              leading: _icon(Icons.upload_file_rounded),
              onTap: () => _exportSettings(context, controller),
            ), subtitle: tr('备份')),
        SettingEntry(tr('导入设置'), (context) => NormalItem(
              title: tr('导入设置'),
              subtitle: tr('从导出的文件恢复'),
              leading: _icon(Icons.download_rounded),
              onTap: () => _importSettings(context, controller),
            ), subtitle: tr('恢复')),
        SettingEntry(tr('重置所有设置'), (context) => NormalItem(
              title: tr('重置所有设置'),
              subtitle: tr('恢复默认值；观看记录、收藏、播放列表和账号不受影响'),
              leading: _icon(Icons.restore_rounded),
              onTap: () async {
                if (await confirmDialog(context, title: tr('重置所有设置？'), content: tr('播放、外观和隐私设置都会恢复默认值。'), confirm: tr('重置'))) await controller.resetSettings();
              },
            ), subtitle: tr('恢复默认')),
      ],
    SettingsCategory.account => [
        SettingEntry(tr('Google 账号'), (context) => AccountSettings(account: controller.account, note: _note(context)), subtitle: tr('登录、同步订阅和播放列表、退出登录、自定义客户端')),
        SettingEntry(tr('关注时同步订阅'), (context) => SwitchItem(
              title: tr('关注频道时同步订阅到 YouTube'),
              subtitle: tr('登录后，关注和取消关注也会在 YouTube 账号上订阅或退订'),
              leading: _icon(Icons.subscriptions_outlined),
              value: prefs.syncFollowToYoutube,
              onChanged: (v) => savePrefs(prefs.copyWith(syncFollowToYoutube: v)),
            )),
      ],
    SettingsCategory.about => aboutEntries(controller),
  };
}

String trimSpeed(double speed) => speed.toString().replaceFirst(RegExp(r'\.0$'), '');

TextStyle _note(BuildContext context) => TextStyle(color: context.colors.outline, fontSize: 12, height: 1.5);

Future<void> _exportSettings(BuildContext context, AppController controller) async {
  final now = DateTime.now();
  final name = tr('Lumtub_设置_{0}{1}{2}.json', [now.year, now.month.toString().padLeft(2, '0'), now.day.toString().padLeft(2, '0')]);
  final location = await getSaveLocation(suggestedName: name, acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])]);
  if (location == null) return;
  try {
    await XFile.fromData(Uint8List.fromList(utf8.encode(controller.exportSettings())), mimeType: 'application/json', name: name).saveTo(location.path);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('设置已导出'))));
  } catch (e) {
    logError('导出设置失败', e);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('导出失败：{0}', [e]))));
  }
}

Future<void> _importSettings(BuildContext context, AppController controller) async {
  final file = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])]);
  if (file == null) return;
  final String text;
  try {
    text = await file.readAsString();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('无法读取文件：{0}', [e]))));
    return;
  }
  final ok = await controller.importSettings(text);
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? tr('设置已导入') : tr('这不是 Lumtub 导出的设置文件'))));
}

Future<void> _changeCacheLocation(BuildContext context, AppController controller) async {
  if (controller.cacheRoot == null) return;
  if (!controller.ensureNotPlaying(tr('请先返回列表并停止当前视频，再迁移缓存。'))) return;
  final selected = await getDirectoryPath(initialDirectory: controller.cacheRoot!.path);
  if (selected == null || !context.mounted) return;
  await controller.changeCacheLocation(selected, (targetPath) => showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: Text(tr('迁移现有缓存？')),
    content: Text(tr('新位置：{0}\n\n只迁移 Lumtub 创建的缩略图、临时文件、yt-dlp 和 mpv 缓存目录。', [targetPath])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('不迁移'))),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('迁移'))),
    ],
  )));
}

/// GPU, the decoder in use, which codecs were verified to decode in
/// hardware, and the optional Windows video extensions.
class _DecoderStatus extends StatefulWidget {
  const _DecoderStatus({required this.controller});
  final AppController controller;

  @override
  State<_DecoderStatus> createState() => _DecoderStatusState();
}

class _DecoderStatusState extends State<_DecoderStatus> {
  @override
  void initState() {
    super.initState();
    widget.controller.refreshWindowsVideoInfo();
  }

  AppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final info = controller.windowsVideoInfo;
    final colors = context.colors;
    return ExpansionTile(
      // Its own key: an unkeyed tile shares the page's PageStorage slot with
      // the list's scroll offset, and reads that double as its open state.
      key: const PageStorageKey('expand:decoder'),
      leading: const Icon(Icons.speed_rounded),
      title: Text(tr('解码状态'), style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(tr('当前：{0} · {1}', [controller.currentCodec, controller.currentHwdec]), style: _subtitle(context)),
      children: [
        ListTile(dense: true, title: const Text('GPU'), subtitle: Text(info.gpuNames.isEmpty ? tr('尚未检测到或无法读取') : info.gpuNames.join('\n'))),
        ListTile(
          dense: true,
          title: Text(tr('当前实际解码方式')),
          subtitle: Text(tr('视频：{0}\n方式：{1}', [controller.currentCodec, controller.currentHwdec])),
          trailing: OutlinedButton(onPressed: controller.playing == null ? null : controller.inspectCurrentDecoder, child: Text(tr('检测'))),
        ),
        for (final (key, label) in const [('h264', 'H.264'), ('vp9', 'VP9'), ('av1', 'AV1')])
          ListTile(
            dense: true,
            title: Text(tr('{0} 硬件解码', [label])),
            trailing: Builder(builder: (context) {
              final status = controller.decodeStates[key] ?? const DecoderStatus.unverified();
              return Text(status.label, style: TextStyle(color: status.isVerified ? colors.primary : colors.onSurfaceVariant));
            }),
          ),
        _extension(context, 'VP9 Video Extensions', info.vp9Extension, 'https://apps.microsoft.com/detail/9n4d0msmp0pt'),
        _extension(context, 'AV1 Video Extension', info.av1Extension, 'https://apps.microsoft.com/detail/9mvzqvxjbq9v'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(tr('状态只在实际播放对应编码后更新。商店扩展是 Windows Media Foundation 组件，不是 Lumtub 必需的，也不能让不支持的显卡获得硬件解码。'), style: _note(context)),
        ),
      ],
    );
  }

  Widget _extension(BuildContext context, String title, ExtensionStatus status, String storeUrl) {
    final colors = context.colors;
    return ListTile(
      dense: true,
      title: Text(title),
      trailing: switch (status) {
        ExtensionStatus.missing => TextButton(onPressed: () => controller.openStore(storeUrl), child: Text(tr('在商店查看'))),
        ExtensionStatus.present => Text(tr('已安装'), style: TextStyle(color: colors.primary)),
        ExtensionStatus.unknown => Text(tr('尚未验证'), style: TextStyle(color: colors.onSurfaceVariant)),
      },
    );
  }
}

class _AdvancedOptions extends StatelessWidget {
  const _AdvancedOptions({required this.settings, required this.onReset});
  final PlayerSettings settings;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    Widget option(String name, String value, String description, String applies) => ListTile(
          dense: true,
          title: Text(name, style: const TextStyle(fontFamily: 'monospace')),
          subtitle: Text(tr('{0} · {1}生效', [description, applies])),
          trailing: Text(value, style: TextStyle(color: context.colors.primary, fontFamily: 'monospace')),
        );
    return ExpansionTile(
      key: const PageStorageKey('expand:mpv'),
      leading: const Icon(Icons.tune_rounded),
      title: Text(tr('高级 libmpv 参数'), style: Theme.of(context).textTheme.titleMedium),
      subtitle: Text(tr('查看实际传给 libmpv 的参数，或恢复默认'), style: _subtitle(context)),
      children: [
        option('hwdec', settings.hwdec, tr('硬件解码方式'), tr('下一段视频')),
        option('scale', settings.scale, tr('视频缩放算法'), tr('立即')),
        option('deband', settings.deband ? 'yes' : 'no', tr('色带消除'), tr('立即')),
        option('interpolation', settings.interpolation ? 'yes' : 'no', tr('帧插值'), tr('下一段视频')),
        option('hwdec-codecs', settings.hwdecCodecs, tr('硬解编码'), tr('下一段视频')),
        option('d3d11va-zero-copy', settings.d3d11vaZeroCopy ? 'yes' : 'no', tr('D3D11VA 零拷贝'), tr('下一段视频')),
        option('vd-lavc-dr', settings.directRendering, tr('直接解码到显存'), tr('下一段视频')),
        option('video-sync', settings.videoSync.mpvValue, tr('视频同步'), tr('立即')),
        option('autosync', settings.autosync == 0 ? 'no' : '${settings.autosync}', tr('自动同步'), tr('立即')),
        option('af', settings.audioFilter.isEmpty ? tr('（无）') : settings.audioFilter, tr('音频滤镜'), tr('立即')),
        for (final (key, value) in settings.customOptions.entries.map((e) => (e.key, e.value))) option(key, value, tr('自定义参数'), tr('立即或下一段视频')),
        option('cache', settings.cacheMode, tr('网络缓存模式'), tr('立即')),
        option('cache-secs', '${settings.cacheSeconds}', tr('缓存预读时间'), tr('立即')),
        option('demuxer-max-bytes', '${settings.cacheMemoryMb}MiB', tr('缓存内存上限'), tr('立即')),
        option('volume-max', '${settings.volumeMax}', tr('最高音量'), tr('立即')),
        option('audio-device', settings.audioDevice, tr('音频输出设备'), tr('立即')),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: OutlinedButton.icon(onPressed: onReset, icon: const Icon(Icons.restart_alt), label: Text(tr('恢复全部播放器默认设置'))),
          ),
        ),
      ],
    );
  }
}

Future<void> _pickAudioFilter(BuildContext context, AppController controller) async {
  const custom = '\u0000custom';
  final current = controller.settings.audioFilter;
  final preset = audioFilterPresets.any((p) => p.$1 == current);
  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: tr('音量均衡'),
      value: preset ? current : custom,
      values: [...audioFilterPresets, (custom, preset ? tr('自定义') : tr('自定义：{0}', [current]))],
    ),
  );
  if (chosen == null || !context.mounted) return;
  if (chosen != custom) {
    await controller.saveSettings(controller.settings.copyWith(audioFilter: chosen));
    return;
  }
  final text = await showDialog<String>(
    context: context,
    builder: (context) => TextEditDialog(title: tr('自定义音频滤镜'), initialText: preset ? '' : current, hintText: tr('例如 loudnorm=I=-14:LRA=7:TP=-2'), monospace: true),
  );
  if (text != null) await controller.saveSettings(controller.settings.copyWith(audioFilter: text.trim().replaceAll(RegExp(r'[\r\n]'), '')));
}

Future<void> editRelayServer(BuildContext context, AppController controller, RelayKind kind) async {
  final piped = kind == RelayKind.piped;
  final text = await showDialog<String>(
    context: context,
    builder: (context) => TextEditDialog(
      title: piped ? tr('Piped 服务器') : tr('Invidious 实例'),
      initialText: piped ? controller.settings.pipedServer : controller.settings.invidiousServer,
      hintText: piped ? tr('例如 https://pipedapi.kavin.rocks') : tr('例如 https://yewtu.be'),
      helper: (text) {
        final colors = context.colors;
        final server = normalizePipedServer(text);
        return Text(server == null ? (piped ? tr('请填写 Piped 的 API 地址（https://…）') : tr('请填写 Invidious 实例的地址（https://…）')) : tr('将使用 {0}', [server]), style: TextStyle(fontSize: 12, color: server == null ? colors.error : colors.outline));
      },
    ),
  );
  final server = text == null ? null : normalizePipedServer(text);
  if (server == null) return;
  final settings = controller.settings;
  await controller.saveSettings(piped
      ? settings.copyWith(playbackSource: PlaybackSource.pipedCustom, pipedServer: server)
      : settings.copyWith(playbackSource: PlaybackSource.invidiousCustom, invidiousServer: server));
}

Future<void> _editProxy(BuildContext context, AppController controller) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => TextEditDialog(
      title: tr('代理地址'),
      initialText: controller.settings.proxyAddress,
      hintText: tr('例如 127.0.0.1:7890 或 socks5://127.0.0.1:7891'),
      helper: (text) {
        final colors = context.colors;
        final address = NetworkProxy.normalize(text);
        return Text(
          address == null ? tr('请填写 主机:端口，可加 http:// 或 socks5:// 前缀') : tr('将使用 {0}{1}', [address, address.startsWith('http://') ? '' : tr('。视频流只支持 HTTP 代理，会直接连接')]),
          style: TextStyle(fontSize: 12, color: address == null ? colors.error : colors.outline),
        );
      },
    ),
  );
  final address = text == null ? null : NetworkProxy.normalize(text);
  if (address != null) await controller.saveSettings(controller.settings.copyWith(proxyMode: ProxyMode.custom, proxyAddress: address));
}

Future<void> _editMpvConf(BuildContext context, AppController controller) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => TextEditDialog(
      title: tr('自定义 mpv 参数'),
      initialText: controller.settings.mpvConf,
      hintText: tr('# 每行一个，和 mpv.conf 相同\nd3d11va-zero-copy=yes\nhwdec-codecs = h264,vc1,hevc,vp8,vp9,av1,prores,ffv1\nvd-lavc-dr = auto'),
      monospace: true,
      maxLines: 14,
      helper: (text) {
        final (options, rejected) = parseMpvConf(text);
        final colors = context.colors;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('可用 {0} 项，在其它设置之后应用。部分参数下一段视频或重启后生效。', [options.length]), style: TextStyle(fontSize: 12, color: colors.outline)),
          for (final (line, reason) in rejected) Text(tr('不会应用：{0}（{1}）', [line, reason]), style: TextStyle(fontSize: 12, color: colors.error)),
        ]);
      },
    ),
  );
  if (text != null) await controller.saveSettings(controller.settings.copyWith(mpvConf: text));
}

TextStyle _subtitle(BuildContext context) => Theme.of(context).textTheme.labelMedium!.copyWith(color: context.colors.outline);
