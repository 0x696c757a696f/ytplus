import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_preferences.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/subtitle_translation.dart';
import 'package:lumtub/translation.dart';
import 'package:lumtub/ui/translatable.dart';

class _Fake implements Translator {
  int calls = 0;
  bool fail = false;
  @override
  Future<String> translate(String text, String target) async {
    calls++;
    if (fail) throw const TranslationException('出错了');
    return '[$target] $text';
  }
}

void main() {
  test('reads the endpoint reply and joins its segments', () {
    expect(GoogleTranslator.parseResponse('[[["你好，","Hello, ",null],["世界\\n","world\\n"]],null,"en"]'), '你好，世界\n');
    expect(() => GoogleTranslator.parseResponse('<html>'), throwsA(isA<TranslationException>()));
  });

  test('splits long text at line ends so that the pieces join back', () {
    final text = List.generate(30, (i) => 'line number $i').join('\n');
    final chunks = GoogleTranslator.splitText(text, max: 100);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.length <= 100), isTrue);
    expect(chunks.join(), text);
    expect(GoogleTranslator.splitText('x' * 250, max: 100).join(), 'x' * 250);
  });

  test('asks the endpoint with the target language and caches the answer', () async {
    final requests = <Uri>[];
    final translator = GoogleTranslator(MockClient((request) async {
      requests.add(request.url);
      return http.Response('[[["你好","hello"]]]', 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }), cacheSize: 2);
    expect(await translator.translate('hello', 'zh-CN'), '你好');
    expect(await translator.translate('hello', 'zh-CN'), '你好');
    expect(requests, hasLength(1));
    expect(requests.single.host, 'translate.googleapis.com');
    expect(requests.single.queryParameters, {'client': 'gtx', 'sl': 'auto', 'tl': 'zh-CN', 'dt': 't', 'q': 'hello'});
    // The oldest of three entries is dropped from a cache of two.
    await translator.translate('a', 'zh-CN');
    await translator.translate('hello', 'zh-CN');
    await translator.translate('b', 'zh-CN');
    expect(requests, hasLength(3));
    await translator.translate('hello', 'zh-CN');
    expect(requests, hasLength(3));
    await translator.translate('a', 'zh-CN');
    expect(requests, hasLength(4));
  });

  test('turns failures into short messages', () async {
    expect(GoogleTranslator(MockClient((_) async => http.Response('', 429))).translate('x', 'en'), throwsA(isA<TranslationException>()));
    expect(GoogleTranslator(MockClient((_) async => throw http.ClientException('offline'))).translate('x', 'en'), throwsA(isA<TranslationException>()));
  });

  test('the target language is saved and unknown codes fall back', () {
    final prefs = const AppPreferences().copyWith(translateLanguage: 'ja');
    expect(AppPreferences.fromJson(prefs.toJson()).translateLanguage, 'ja');
    expect(AppPreferences.fromJson({'translateLanguage': 'xx'}).translateLanguage, 'zh-CN');
    expect(const AppPreferences().translateLanguage, TranslationLanguage.defaultCode);
  });

  test('translated subtitles use a listed track or translate the original', () {
    const en = SubtitleOption(language: 'en', name: 'English', url: 'https://yt.example/api/timedtext?v=1&lang=en&fmt=vtt', kind: SubtitleKind.automatic);
    const zh = SubtitleOption(language: 'zh-Hans', name: 'Chinese', url: 'https://yt.example/zh.vtt', kind: SubtitleKind.translated);
    final target = TranslationLanguage.byCode('zh-CN');
    expect(translationOf([en, zh], target), zh);
    final derived = translationOf([en], target)!;
    expect(derived.kind, SubtitleKind.translated);
    expect(derived.language, 'zh-Hans');
    expect(Uri.parse(derived.url).queryParameters, {'v': '1', 'lang': 'en', 'fmt': 'vtt', 'tlang': 'zh-Hans'});
    // Nothing to translate when the only subtitle is already in the target language.
    expect(translationOf([const SubtitleOption(language: 'zh-Hans', name: '', url: 'https://yt.example/a.vtt')], target), isNull);
    expect(translationOf(const [], target), isNull);
  });

  testWidgets('translates on tap, shows the original again and reports errors', (tester) async {
    final fake = _Fake();
    final controller = AppController()..translator = fake;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Translatable(controller: controller, text: 'Hello', builder: (context, text) => Text(text)))));
    expect(find.text('Hello'), findsOneWidget);
    expect(fake.calls, 0);
    await tester.tap(find.text('翻译'));
    await tester.pump();
    await tester.pump();
    expect(find.text('[zh-CN] Hello'), findsOneWidget);
    await tester.tap(find.text('显示原文'));
    await tester.pump();
    expect(find.text('Hello'), findsOneWidget);
    // Showing the translation again does not ask a second time.
    await tester.tap(find.text('翻译'));
    await tester.pump();
    expect(find.text('[zh-CN] Hello'), findsOneWidget);
    expect(fake.calls, 1);

    final failing = _Fake()..fail = true;
    controller.translator = failing;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Translatable(key: const ValueKey('b'), controller: controller, text: 'Other', builder: (context, text) => Text(text)))));
    await tester.tap(find.text('翻译'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('出错了'), findsOneWidget);
  });
}
