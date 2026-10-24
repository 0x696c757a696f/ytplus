import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app/library_controller.dart';
import 'package:lumtub/app/video_list_loader.dart';
import 'package:lumtub/library_store.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/pages/channel_page.dart';
import 'package:lumtub/ui/pages/library_pages.dart';
import 'package:lumtub/ui/theme.dart';
import 'package:lumtub/ui/video_card.dart';
import 'package:lumtub/video_repository.dart';
import 'package:lumtub/youtube_account.dart';

void main() {
  const channel = ChannelRef('UCuAXFkgsw1L7xaCfnd5JJOw', 'Rick Astley');
  final videos = [
    for (var i = 0; i < 6; i++)
      VideoItem(id: 'video${i}xxxxx', title: '视频 $i', channel: 'Rick Astley', url: 'https://www.youtube.com/watch?v=video${i}xxxxx', duration: 200, channelId: channel.id),
  ];

  late AppController controller;
  late LibraryController library;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('lumtub_pages');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = LibraryStore(File('${dir.path}/library.json'));
    library = LibraryController(store);
    controller = AppController()..library = library;
  });

  Future<void> pump(WidgetTester tester, Widget page, {double width = 1280}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Colors.red, Brightness.light),
      home: Scaffold(body: VideoActions(controller: controller, child: page)),
    ));
    await tester.pump();
  }

  testWidgets('subscriptions explain how to follow a channel', (tester) async {
    await pump(tester, SubscriptionsPage(controller: controller));
    expect(find.text('还没有关注频道'), findsOneWidget);
  });

  testWidgets('subscriptions show followed channels and their feed', (tester) async {
    library.toggleFollow(channel);
    library.feed = videos;
    for (final width in [1280.0, 600.0]) {
      await pump(tester, SubscriptionsPage(controller: controller), width: width);
      expect(find.text('Rick Astley'), findsWidgets);
      expect(find.text('视频 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    unawaited(library.flush());
  });

  testWidgets('many subscriptions fit in one row; picking one narrows the feed', (tester) async {
    for (var i = 0; i < 100; i++) {
      library.toggleFollow(ChannelRef('UC${'$i'.padLeft(22, '0')}', '频道 $i'));
    }
    library.toggleFollow(channel);
    library.feed = videos;
    // A wide window lists the channels in a column on the left.
    await pump(tester, SubscriptionsPage(controller: controller));
    expect(tester.getTopLeft(find.text('Rick Astley').first).dx, lessThan(100));
    expect(find.text('全部 101 个'), findsOneWidget);

    await pump(tester, SubscriptionsPage(controller: controller), width: 900);
    final strip = find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal);
    Finder inStrip(String text) => find.descendant(of: strip, matching: find.text(text));
    // The channel that just posted comes right after 全部, in the same row.
    final rick = tester.getTopLeft(inStrip('Rick Astley'));
    expect(tester.getTopLeft(find.text('全部')).dx, lessThan(rick.dx));
    expect(find.text('视频 0'), findsOneWidget);

    await tester.tap(find.text('频道 3'));
    await tester.pump();
    expect(find.text('视频 0'), findsNothing);
    expect(find.text('这个频道最近没有新视频'), findsOneWidget);
    await tester.tap(inStrip('Rick Astley'));
    await tester.pump();
    expect(find.text('Rick Astley 的新视频'), findsOneWidget);
    expect(find.text('视频 0'), findsOneWidget);

    // A mouse wheel scrolls the row sideways.
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(tester.getCenter(strip));
    final before = tester.getTopLeft(inStrip('频道 3')).dx;
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pump();
    expect(tester.getTopLeft(inStrip('频道 3')).dx, lessThan(before));

    // The full list searches by name and narrows the page to the pick.
    await tester.tap(find.text('全部 101 个'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '频道 42');
    await tester.pump();
    expect(find.widgetWithText(ListTile, '频道 7'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, '频道 42'));
    await tester.pumpAndSettle();
    expect(find.text('频道 42 的新视频'), findsOneWidget);
    expect(tester.takeException(), isNull);
    unawaited(library.flush());
  });

  test('imported subscriptions keep their pictures', () {
    final ref = YouTubeAccountApi.parseSubscription({
      'snippet': {
        'title': 'Rick Astley',
        'resourceId': {'channelId': channel.id},
        'thumbnails': {'default': {'url': 'https://yt3.ggpht.com/a=s88'}, 'medium': {'url': 'https://yt3.ggpht.com/a=s240'}},
      },
    })!;
    expect(ref.avatar, 'https://yt3.ggpht.com/a=s240');
    expect(ChannelRef.fromJson(ref.toJson())!.avatar, ref.avatar);
    library.toggleFollow(channel);
    library.followAll([ref]);
    expect(library.channels.single.avatar, ref.avatar);
    unawaited(library.flush());
  });

  testWidgets('playlists list favorites first and open a playlist', (tester) async {
    library.toggleFavorite(videos.first);
    final playlist = library.createPlaylist('周末歌单');
    for (final video in videos.take(3)) {
      library.addToPlaylist(playlist, video);
    }
    await pump(tester, PlaylistsPage(controller: controller));
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('周末歌单'), findsOneWidget);
    expect(find.text('3 个视频'), findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.openPlaylistId = playlist.id;
    await pump(tester, PlaylistDetailPage(controller: controller));
    expect(find.text('播放全部'), findsOneWidget);
    expect(find.text('视频 2'), findsOneWidget);
    expect(find.byTooltip('重命名'), findsOneWidget);

    controller.openPlaylistId = AppController.favoritesPlaylistId;
    await pump(tester, PlaylistDetailPage(controller: controller));
    expect(find.byTooltip('重命名'), findsNothing);
    expect(find.text('视频 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Cancels the delayed save, which the test clock would never run.
    unawaited(library.flush());
  });

  testWidgets('channel page lists uploads and follows the channel', (tester) async {
    controller.channel = channel;
    controller.channelVideos = VideoListLoader(() => Listing(() => Stream.fromIterable([for (final v in videos) jsonEncode(v.toJson())])))..loadMore();
    addTearDown(controller.channelVideos!.dispose);
    await pump(tester, ChannelPage(controller: controller));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Rick Astley'), findsWidgets);
    expect(find.text('视频 5'), findsOneWidget);
    expect(find.text('搜索频道内的视频'), findsOneWidget);
    await tester.tap(find.text('关注'));
    await tester.pump();
    expect(library.isFollowing(channel.id), isTrue);
    expect(tester.takeException(), isNull);
    // Cancels the delayed save, which the test clock would never run.
    unawaited(library.flush());
  });
}
