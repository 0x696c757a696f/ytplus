import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/models.dart';

void main() {
  test('lists uploaded subtitles, original captions, then translations', () {
    List<Map<String, String>> formats(String lang, String name) => [
          {'ext': 'json3', 'url': 'https://yt.example/$lang.json3', 'name': name},
          {'ext': 'vtt', 'url': 'https://yt.example/$lang.vtt', 'name': name},
        ];
    final options = SubtitleOption.listFrom(
      {'zh-Hant': formats('zh-Hant', 'Chinese (Traditional)'), 'live_chat': formats('chat', 'chat')},
      {
        'en-orig': formats('en-orig', 'English (Original)'),
        'en': formats('en', 'English'),
        'ja': formats('ja', 'Japanese'),
        'xx': [
          {'ext': 'vtt', 'url': 'http://insecure.example/xx.vtt'},
        ],
      },
    );
    expect([for (final o in options) (o.language, o.kind)], [
      ('zh-Hant', SubtitleKind.uploaded),
      ('en', SubtitleKind.automatic),
      ('ja', SubtitleKind.translated),
    ]);
    expect(options.first.url, 'https://yt.example/zh-Hant.vtt');
    expect(options[1].label, '英语（自动生成）');
    expect(options[2].label, '日语（自动翻译）');
    expect(SubtitleOption.languageName('sw', 'Swahili (Original)'), 'Swahili · sw');
  });
}
