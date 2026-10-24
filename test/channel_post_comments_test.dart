import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app/posts_loader.dart';
import 'package:lumtub/community_posts.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/ui/pages/channel_page.dart';
import 'package:lumtub/video_repository.dart';

void main() {
  Future<AppController> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = ChannelRef('UCaaaaaaaaaaaaaaaaaaaaaa', '频道');
    final controller = AppController()
      ..ready = true
      ..channel = channel
      ..channelTab = ChannelTab.posts
      ..channelPosts = (PostsLoader(CommunityPosts(http.Client()), channel)
        ..hasMore = false
        ..posts = const [
          CommunityPost(id: 'Ugkx1', text: '第一条帖子', comments: '12'),
          CommunityPost(id: 'Ugkx2', text: '第二条帖子', comments: '3'),
        ]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChannelPage(controller: controller))));
    await tester.pump();
    return controller;
  }

  testWidgets('wide windows open a post\'s comments on the right', (tester) async {
    await pump(tester, const Size(1400, 900));
    expect(find.byType(PostCommentsPanel), findsNothing);
    await tester.tap(find.text('12'));
    await tester.pump();
    expect(find.byType(PostCommentsPanel), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    // The posts stay on the left, next to the panel.
    expect(tester.getTopLeft(find.byType(PostCommentsPanel)).dx, greaterThan(tester.getTopRight(find.text('第一条帖子').first).dx));
    // Another post's button switches the panel; its own closes it.
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(find.descendant(of: find.byType(PostCommentsPanel), matching: find.text('第二条帖子')), findsOneWidget);
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(find.byType(PostCommentsPanel), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('narrow windows open them as a page', (tester) async {
    await pump(tester, const Size(800, 900));
    await tester.tap(find.text('12'));
    await tester.pumpAndSettle();
    expect(find.byType(PostCommentsPanel), findsOneWidget);
    expect(find.byType(ChannelPage, skipOffstage: true), findsNothing);
    await tester.tap(find.byTooltip('关闭 (Esc)'));
    await tester.pumpAndSettle();
    expect(find.byType(PostCommentsPanel), findsNothing);
  });
}
