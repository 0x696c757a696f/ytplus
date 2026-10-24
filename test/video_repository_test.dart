import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/video_repository.dart';

void main() {
  test('searches YouTube\'s results page so channels are listed too', () {
    expect(VideoRepository.searchUrl('lofi 音乐'), 'https://www.youtube.com/results?search_query=lofi+%E9%9F%B3%E4%B9%90');
    expect(VideoRepository.searchUrl('x', filter: SearchFilter.channels), endsWith('&sp=EgIQAg%253D%253D'));
    final arguments = VideoRepository('yt-dlp.exe').listingArguments(VideoRepository.searchUrl('lofi'));
    expect(arguments, containsAllInOrder(['--flat-playlist', '--lazy-playlist', '--dump-json']));
  });

  test('keeps the query inside the URL after the option terminator', () {
    final arguments = VideoRepository('yt-dlp.exe').listingArguments(VideoRepository.searchUrl('--exec calc'));
    expect(arguments.sublist(arguments.length - 2), ['--', 'https://www.youtube.com/results?search_query=--exec+calc']);
  });

  test('streams results line by line from one process', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_search');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\n'
        'echo \'{"id":"dQw4w9WgXcQ","title":"One","channel":"A"}\'\n'
        'echo \'not json\'\n'
        'echo \'{"id":"9bZkp7q19f0","title":"Two","channel":"B"}\'\n');
    await Process.run('chmod', ['+x', script.path]);
    final listing = VideoRepository(script.path).search('test');
    final first = await listing.next(1).toList();
    final rest = await listing.next(5).toList();
    expect([...first, ...rest].map((item) => (item as VideoItem).id), ['dQw4w9WgXcQ', '9bZkp7q19f0']);
    expect(listing.done, isTrue);
  });

  test('reports yt-dlp errors when nothing was listed', () async {
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_search');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\necho "ERROR: blocked" >&2\nexit 1\n');
    await Process.run('chmod', ['+x', script.path]);
    expect(VideoRepository(script.path).search('test').next(20).toList(), throwsA(isA<StateError>().having((e) => e.message, 'message', 'ERROR: blocked')));
  });

  test('searches inside a channel', () async {
    const channel = ChannelRef('UCuAXFkgsw1L7xaCfnd5JJOw', 'Rick Astley');
    if (Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('lumtub_search');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/fake-yt-dlp');
    await script.writeAsString('#!/bin/sh\nfor a; do last="\$a"; done\necho "{\\"id\\":\\"dQw4w9WgXcQ\\",\\"title\\":\\"\$last\\"}"\n');
    await Process.run('chmod', ['+x', script.path]);
    final items = await VideoRepository(script.path).channelSearch(channel, 'never gonna').next(5).toList();
    final item = items.single as VideoItem;
    expect(item.title, 'https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw/search?query=never+gonna');
    expect(item.channelId, channel.id);
  });

  test('channel tabs and playlists have their own addresses', () {
    const channel = ChannelRef('UCuAXFkgsw1L7xaCfnd5JJOw', 'Rick Astley');
    expect(ChannelTab.values.map((t) => t.label), ['视频', 'Shorts', '直播', '播放列表', '播客', '社区']);
    expect(ChannelTab.live.path, '/streams');
    expect(SearchFilter.playlists.sp, 'EgIQAw%253D%253D');
    expect('${channel.url}${ChannelTab.shorts.path}', 'https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw/shorts');
  });
}
