import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/search_options.dart';
import 'package:lumtub/search_suggestions.dart';
import 'package:lumtub/video_repository.dart';

void main() {
  group('searchParams', () {
    test('is null without options', () => expect(searchParams(), isNull));

    test('matches the type filters YouTube uses', () {
      for (final filter in SearchFilter.values) {
        expect(searchParams(type: filter), filter.sp, reason: filter.name);
      }
    });

    test('combines order, upload date, type and length', () {
      // YouTube's own "this week, videos, by upload date".
      expect(searchParams(type: SearchFilter.videos, sort: SearchSort.date, date: SearchUploadDate.week), 'CAISBAgDEAE%253D');
      // "Over 20 minutes, by view count".
      expect(searchParams(sort: SearchSort.views, duration: SearchDuration.long), 'CAMSAhgC');
      final bytes = base64.decode(Uri.decodeComponent(Uri.decodeComponent(searchParams(type: SearchFilter.live, duration: SearchDuration.medium)!)));
      expect(bytes, [0x12, 4, 0x40, 1, 0x18, 3]);
    });
  });

  test('parses suggestions', () {
    expect(SearchSuggestions.parse('["lofi",["lofi hip hop","lofi 中文",3]]'), ['lofi hip hop', 'lofi 中文']);
    expect(SearchSuggestions.parse('<html>'), isEmpty);
  });

  test('fetches suggestions once per text', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.queryParameters['q'], 'abc');
      return http.Response.bytes(utf8.encode('["abc",["abc 1","abc 2"]]'), 200);
    });
    final suggestions = SearchSuggestions(client);
    expect(await suggestions.forQuery(' abc '), ['abc 1', 'abc 2']);
    expect(await suggestions.forQuery('abc'), ['abc 1', 'abc 2']);
    expect(calls, 1);
    expect(await suggestions.forQuery('  '), isEmpty);
  });

  test('keeps search history newest first without repeats', () async {
    final dir = await Directory.systemTemp.createTemp('lumtub_search');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/search_history.json');
    final history = SearchHistory(file);
    await history.add('a');
    await history.add('b');
    await history.add(' a ');
    await history.add('');
    expect(await history.items(), ['a', 'b']);
    expect(await SearchHistory(file).items(), ['a', 'b']);
    await history.remove('a');
    expect(await SearchHistory(file).items(), ['b']);
    for (var i = 0; i < 60; i++) {
      await history.add('q$i');
    }
    expect((await history.items()).length, SearchHistory.limit);
    expect((await history.items()).first, 'q59');
    await history.clear();
    expect(await SearchHistory(file).items(), isEmpty);
  });
}
