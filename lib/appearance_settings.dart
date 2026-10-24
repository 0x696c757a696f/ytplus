import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_directories.dart';
import 'l10n/l10n.dart';

/// Seed colours offered in Settings; the first is the default. The first
/// six are Lumtub's own, the rest PiliNara's palette.
final accentChoices = <(String, Color)>[
  (tr('YouTube 红'), Color(0xFFE53935)),
  (tr('青绿'), Color(0xFF26A69A)),
  (tr('天蓝'), Color(0xFF1E88E5)),
  (tr('紫罗兰'), Color(0xFF7E57C2)),
  (tr('琥珀'), Color(0xFFFFB300)),
  (tr('粉红'), Color(0xFFEC407A)),
  (tr('默认绿'), Color(0xFF5CB67B)),
  (tr('橙色'), Colors.orange),
  (tr('黄色'), Colors.yellow),
  (tr('酸橙色'), Colors.lime),
  (tr('浅绿色'), Colors.lightGreen),
  (tr('青色'), Colors.teal),
  (tr('蓝绿色'), Colors.cyan),
  (tr('浅蓝色'), Colors.lightBlue),
  (tr('靛蓝色'), Colors.indigo),
  (tr('深紫色'), Colors.deepPurple),
  (tr('蓝灰色'), Colors.blueGrey),
  (tr('棕色'), Colors.brown),
  (tr('灰色'), Colors.grey),
];

/// Material's palette styles with the names PiliNara uses.
final schemeVariantNames = {
  DynamicSchemeVariant.tonalSpot: tr('默认（Tonal Spot）'),
  DynamicSchemeVariant.fidelity: tr('保真（Fidelity）'),
  DynamicSchemeVariant.content: tr('内容（Content）'),
  DynamicSchemeVariant.vibrant: tr('鲜艳（Vibrant）'),
  DynamicSchemeVariant.expressive: tr('表现力（Expressive）'),
  DynamicSchemeVariant.neutral: tr('中性（Neutral）'),
  DynamicSchemeVariant.monochrome: tr('单色（Monochrome）'),
  DynamicSchemeVariant.rainbow: tr('彩虹（Rainbow）'),
  DynamicSchemeVariant.fruitSalad: tr('水果沙拉（Fruit Salad）'),
};

enum PageTransition {
  fade('淡入淡出（默认）'),
  zoom('缩放'),
  slide('上滑'),
  cupertino('左右滑动'),
  none('无动画');

  const PageTransition(this._label);
  final String _label;
  String get label => tr(_label);
}

enum NavigationStyle {
  auto('自动（窗口较宽时用侧边栏）'),
  rail('始终使用侧边栏'),
  bottom('始终使用底栏');

  const NavigationStyle(this._label);
  final String _label;
  String get label => tr(_label);
}

enum ThumbnailQuality {
  medium('mqdefault', '标准（320×180，最省流量）'),
  high('hqdefault', '高（480×360，默认）'),
  standard('sddefault', '较高（640×480）'),
  max('maxresdefault', '最高（1280×720，部分视频没有）');

  const ThumbnailQuality(this._file, this._label);
  final String _file;
  String get file => tr(_file);
  final String _label;
  String get label => tr(_label);
}

/// The font bundled with Lumtub and used by default.
const bundledFont = 'Noto Sans CJK SC';

/// Fonts offered in Settings: the bundled one, then fonts that ship with
/// Windows and cover Chinese; null is the system UI font.
final fontChoices = <(String?, String)>[
  (bundledFont, tr('Noto Sans CJK SC（默认，内置）')),
  (null, tr('系统默认')),
  ('Microsoft YaHei UI', tr('微软雅黑')),
  ('DengXian', tr('等线')),
];

/// The narrowest a video card may get; set from [AppearanceSettings.cardWidth].
double videoCardMinWidth = 250.0;

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) => values.where((v) => v.name == name).firstOrNull ?? fallback;

class AppearanceSettings {
  final ThemeMode themeMode;
  /// An index into [accentChoices], or -1 for [customAccent].
  final int accentIndex;
  final int customAccent;
  /// Follow the Windows accent colour instead of the chosen one.
  final bool systemAccent;
  final DynamicSchemeVariant schemeVariant;
  /// True black backgrounds in dark mode.
  final bool pureBlack;
  final String? fontFamily;
  final double textScale;
  final PageTransition transition;
  final NavigationStyle navigation;
  /// The narrowest a video card may get before a column is dropped.
  final double cardWidth;
  final ThumbnailQuality thumbnailQuality;
  final bool darkWatchPage;
  final bool showStatusBar;
  /// The interface language; it applies after a restart.
  final AppLanguage language;

  const AppearanceSettings({
    this.themeMode = ThemeMode.system,
    this.accentIndex = 0,
    this.customAccent = 0xFFE53935,
    this.systemAccent = false,
    this.schemeVariant = DynamicSchemeVariant.tonalSpot,
    this.pureBlack = false,
    this.fontFamily = bundledFont,
    this.textScale = 1.0,
    this.transition = PageTransition.fade,
    this.navigation = NavigationStyle.auto,
    this.cardWidth = 250,
    this.thumbnailQuality = ThumbnailQuality.high,
    this.darkWatchPage = false,
    this.showStatusBar = true,
    this.language = AppLanguage.en,
  });

  /// The chosen colour; [systemAccent] is resolved by the app.
  Color get accent => accentIndex < 0 ? Color(customAccent) : accentChoices[accentIndex].$2;

  String get accentLabel => systemAccent ? tr('跟随 Windows 强调色') : accentIndex < 0 ? tr('自定义') : accentChoices[accentIndex].$1;

  AppearanceSettings copyWith({
    ThemeMode? themeMode,
    int? accentIndex,
    int? customAccent,
    bool? systemAccent,
    DynamicSchemeVariant? schemeVariant,
    bool? pureBlack,
    String? fontFamily,
    bool clearFontFamily = false,
    double? textScale,
    PageTransition? transition,
    NavigationStyle? navigation,
    double? cardWidth,
    ThumbnailQuality? thumbnailQuality,
    bool? darkWatchPage,
    bool? showStatusBar,
    AppLanguage? language,
  }) =>
      AppearanceSettings(
        themeMode: themeMode ?? this.themeMode,
        accentIndex: accentIndex ?? this.accentIndex,
        customAccent: customAccent ?? this.customAccent,
        systemAccent: systemAccent ?? this.systemAccent,
        schemeVariant: schemeVariant ?? this.schemeVariant,
        pureBlack: pureBlack ?? this.pureBlack,
        fontFamily: clearFontFamily ? null : fontFamily ?? this.fontFamily,
        textScale: textScale ?? this.textScale,
        transition: transition ?? this.transition,
        navigation: navigation ?? this.navigation,
        cardWidth: cardWidth ?? this.cardWidth,
        thumbnailQuality: thumbnailQuality ?? this.thumbnailQuality,
        darkWatchPage: darkWatchPage ?? this.darkWatchPage,
        showStatusBar: showStatusBar ?? this.showStatusBar,
        language: language ?? this.language,
      );

  /// What a theme is built from; themes are rebuilt only when it changes.
  Object themeKey(Color seed) => (seed, schemeVariant, pureBlack, fontFamily, transition);

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode.name,
        'accentIndex': accentIndex,
        'customAccent': customAccent,
        'systemAccent': systemAccent,
        'schemeVariant': schemeVariant.name,
        'pureBlack': pureBlack,
        'fontFamily': fontFamily ?? 'system',
        'textScale': textScale,
        'transition': transition.name,
        'navigation': navigation.name,
        'cardWidth': cardWidth,
        'thumbnailQuality': thumbnailQuality.name,
        'darkWatchPage': darkWatchPage,
        'showStatusBar': showStatusBar,
        'language': language.name,
      };

  factory AppearanceSettings.fromJson(Object? raw) {
    if (raw is! Map) return const AppearanceSettings();
    final mode = ThemeMode.values.where((m) => m.name == raw['themeMode']).firstOrNull ?? ThemeMode.system;
    final index = raw['accentIndex'];
    final custom = raw['customAccent'];
    final font = raw['fontFamily']?.toString();
    final scale = raw['textScale'];
    final width = raw['cardWidth'];
    return AppearanceSettings(
      themeMode: mode,
      accentIndex: index is int && index >= -1 && index < accentChoices.length ? index : 0,
      customAccent: custom is int ? custom | 0xFF000000 : 0xFFE53935,
      systemAccent: raw['systemAccent'] == true,
      schemeVariant: _byName(DynamicSchemeVariant.values, raw['schemeVariant'], DynamicSchemeVariant.tonalSpot),
      pureBlack: raw['pureBlack'] == true,
      // Earlier builds wrote nothing for the system font; it now defaults to
      // the bundled one.
      fontFamily: font == 'system' ? null : font?.trim().isNotEmpty == true ? font : bundledFont,
      textScale: scale is num ? scale.toDouble().clamp(0.8, 1.4) : 1.0,
      transition: _byName(PageTransition.values, raw['transition'], PageTransition.fade),
      navigation: _byName(NavigationStyle.values, raw['navigation'], NavigationStyle.auto),
      cardWidth: width is num ? width.toDouble().clamp(180, 420) : 250,
      thumbnailQuality: _byName(ThumbnailQuality.values, raw['thumbnailQuality'], ThumbnailQuality.high),
      darkWatchPage: raw['darkWatchPage'] == true,
      showStatusBar: raw['showStatusBar'] != false,
      language: AppLanguage.parse(raw['language']),
    );
  }
}

/// Reads the Windows accent colour (Settings › Personalisation › Colours).
/// Returns null when it cannot be read, such as outside Windows.
Future<Color?> readWindowsAccent() async {
  if (!Platform.isWindows) return null;
  try {
    final result = await Process.run('reg', ['query', r'HKCU\Software\Microsoft\Windows\DWM', '/v', 'AccentColor']);
    final match = RegExp(r'AccentColor\s+REG_DWORD\s+0x([0-9a-fA-F]+)').firstMatch('${result.stdout}');
    if (match == null) return null;
    // Stored as 0xAABBGGRR.
    final abgr = int.parse(match[1]!, radix: 16);
    return Color.fromARGB(0xFF, abgr & 0xFF, (abgr >> 8) & 0xFF, (abgr >> 16) & 0xFF);
  } catch (_) {
    return null;
  }
}

class AppearanceSettingsStore {
  final File file;
  AppearanceSettingsStore(AppDirectories directories) : file = File('${directories.config.path}${Platform.pathSeparator}appearance.json');

  Future<AppearanceSettings> load() async {
    try {
      return AppearanceSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return const AppearanceSettings();
    }
  }

  Future<void> save(AppearanceSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}
