import 'dart:ui' show Locale;

import 'strings_en.dart';
import 'strings_zh_hant.dart';

/// The languages Lumtub is written in. The source strings are simplified
/// Chinese; the other languages translate them.
enum AppLanguage {
  system('跟随系统', null),
  zhHans('简体中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')),
  zhHant('繁體中文', Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')),
  en('English', Locale('en'));

  const AppLanguage(this.nativeName, this.locale);
  /// The language's own name, the same in every language.
  final String nativeName;
  String get label => this == system ? tr(nativeName) : nativeName;
  final Locale? locale;

  /// [system] is English too: the interface is English for now, whatever
  /// language Windows uses. The Chinese values are kept for the source
  /// strings and tests, but nothing saved or chosen at run time reaches them.
  AppLanguage get resolved => this == system ? en : this;

  /// What can be chosen in settings (nothing yet, since there is only one).
  static const selectable = [en];

  /// Any saved value, including Chinese ones from earlier versions, becomes
  /// English.
  static AppLanguage parse(Object? raw) => en;
}

AppLanguage _current = AppLanguage.zhHans; // source language, until main() calls setLanguage
Map<String, String> _strings = const {};

/// The language the interface is shown in, chosen when Lumtub starts.
AppLanguage get currentLanguage => _current;

/// Shows the interface in [language] from now on. Text already on screen
/// changes after a restart.
void setLanguage(AppLanguage language) {
  _current = language.resolved;
  _strings = switch (_current) {
    AppLanguage.en => stringsEn,
    AppLanguage.zhHant => stringsZhHant,
    _ => const {},
  };
}

/// YouTube's `hl` for the interface language, so that titles, descriptions,
/// posts and comments come in it where YouTube has them translated.
String get youtubeHl => switch (_current) {
      AppLanguage.en => 'en',
      AppLanguage.zhHant => 'zh-TW',
      _ => 'zh-CN',
    };

/// `Accept-Language` to go with [youtubeHl].
String get youtubeAcceptLanguage => switch (_current) {
      AppLanguage.en => 'en-US,en;q=0.9',
      AppLanguage.zhHant => 'zh-TW,zh;q=0.9,en;q=0.8',
      _ => 'zh-CN,zh;q=0.9,en;q=0.8',
    };

/// [zh] in the current language, with `{0}`, `{1}`… replaced by [args].
/// Text with no translation stays as written.
String tr(String zh, [List<Object?> args = const []]) {
  final text = _strings[zh] ?? zh;
  if (args.isEmpty) return text;
  return text.replaceAllMapped(_placeholder, (m) {
    final i = int.parse(m.group(1)!);
    return i < args.length ? '${args[i]}' : m.group(0)!;
  });
}

final _placeholder = RegExp(r'\{(\d+)\}');
