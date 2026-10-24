import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/app/library_controller.dart';
import 'package:lumtub/channel_avatars.dart';
import 'package:lumtub/library_store.dart';
import 'package:lumtub/models.dart';

void main() {
  const a = ChannelRef('UCuAXFkgsw1L7xaCfnd5JJOw', 'A');
  const b = ChannelRef('UCBR8-60-B28hp2BmDPdntcQ', 'B');
  const c = ChannelRef('UCX6OQ3DkcsbYNE6H8uQQuVA', 'C');

  String page(String image) => '<html><head><meta property="og:image" content="$image"></head></html>';

  test('reads the avatar from a channel page and ignores the site logo', () {
    expect(ChannelAvatars.parse(page('https://yt3.googleusercontent.com/x=s900-c&amp;y')), 'https://yt3.googleusercontent.com/x=s900-c&y');
    expect(ChannelAvatars.parse(page('https://www.youtube.com/img/desktop/yt_1200.png')), isNull);
    expect(ChannelAvatars.parse('<html></html>'), isNull);
  });

  test('avatar urls are upgraded to https', () {
    expect(ChannelRef.avatarUrl('//yt3.ggpht.com/a'), 'https://yt3.ggpht.com/a');
    expect(ChannelRef.avatarUrl('http://yt3.ggpht.com/a'), 'https://yt3.ggpht.com/a');
    expect(ChannelRef.avatarUrl('ftp://x'), isNull);
    expect(ChannelRef.avatarUrl(null), isNull);
    expect(ChannelRef.fromJson({'id': a.id, 'name': 'A', 'avatar': '//yt3.ggpht.com/a'})!.avatar, 'https://yt3.ggpht.com/a');
  });

  test('channels saved without a picture get one once, a few at a time', () async {
    final dir = Directory.systemTemp.createTempSync('lumtub_avatars');
    addTearDown(() => dir.deleteSync(recursive: true));
    var active = 0;
    var peak = 0;
    final requests = <String>[];
    final client = MockClient((request) async {
      final id = request.url.pathSegments.last;
      requests.add(id);
      active++;
      peak = active > peak ? active : peak;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
      return id == c.id ? http.Response('', 404) : http.Response(page('https://yt3.googleusercontent.com/$id'), 200);
    });
    final store = LibraryStore(File('${dir.path}/library.json'))
      ..channels.addAll([a, b, c, const ChannelRef('UCaaaaaaaaaaaaaaaaaaaaaa', 'D', 'https://yt3.ggpht.com/d')]);
    final library = LibraryController(store, client: client);
    await library.fillMissingAvatars(concurrency: 2);
    expect(library.channels.map((ch) => ch.avatar), [
      'https://yt3.googleusercontent.com/${a.id}',
      'https://yt3.googleusercontent.com/${b.id}',
      null,
      'https://yt3.ggpht.com/d',
    ]);
    expect(library.channels.first.name, 'A');
    expect(peak, lessThanOrEqualTo(2));
    expect(requests, hasLength(3));
    await library.fillMissingAvatars();
    expect(requests, hasLength(3), reason: 'a channel is looked up once per session');
    await library.flush();
  });
}
