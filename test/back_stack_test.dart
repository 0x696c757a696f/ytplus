import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app/back_stack.dart';
import 'package:lumtub/models.dart';
import 'package:lumtub/video_repository.dart';

void main() {
  group('BackStack', () {
    test('keeps one entry per place in a row', () {
      final stack = BackStack()
        ..push(const BackEntry.page(PageMode.home))
        ..push(const BackEntry.page(PageMode.explore, query: 'a'))
        ..push(const BackEntry.page(PageMode.explore, query: 'a'))
        ..push(const BackEntry.page(PageMode.explore, query: 'b'));
      expect(stack.length, 3);
      expect(stack.pop()?.query, 'b');
      expect(stack.pop()?.query, 'a');
      expect(stack.pop()?.mode, PageMode.home);
      expect(stack.pop(), isNull);
    });

    test('a video replaces its older position', () {
      const video = VideoItem(id: 'abcdefghijk', title: 't', channel: 'c', url: 'u');
      final stack = BackStack()
        ..push(const BackEntry.video(video, mode: PageMode.home, position: Duration(seconds: 1)))
        ..push(const BackEntry.video(video, mode: PageMode.home, position: Duration(seconds: 9)));
      expect(stack.length, 1);
      expect(stack.last?.position, const Duration(seconds: 9));
    });

    test('tells channels and their tabs apart', () {
      final a = ChannelRef('UCaaaaaaaaaaaaaaaaaaaaaa', 'A');
      expect(BackEntry.page(PageMode.channel, channel: a).same(BackEntry.page(PageMode.channel, channel: a)), isTrue);
      expect(BackEntry.page(PageMode.channel, channel: a).same(BackEntry.page(PageMode.channel, channel: a, channelTab: ChannelTab.shorts)), isFalse);
      expect(BackEntry.page(PageMode.channel, channel: a).same(BackEntry.page(PageMode.channel, channel: ChannelRef('UCbbbbbbbbbbbbbbbbbbbbbb', 'B'))), isFalse);
    });

    test('forgets the oldest places past its limit', () {
      final stack = BackStack();
      for (var i = 0; i < BackStack.limit + 10; i++) {
        stack.push(BackEntry.page(PageMode.explore, query: '$i'));
      }
      expect(stack.length, BackStack.limit);
    });
  });

  group('AppController.goBack', () {
    AppController ready() => AppController()..ready = true;

    test('returns through the pages opened before', () {
      final controller = ready();
      controller.navigate(PageMode.subscriptions);
      controller.openPlaylist(AppController.favoritesPlaylistId);
      controller.navigate(PageMode.history);
      expect(controller.mode, PageMode.history);
      controller.goBack();
      expect(controller.mode, PageMode.playlist);
      controller.goBack();
      expect(controller.mode, PageMode.subscriptions);
      controller.goBack();
      expect(controller.mode, PageMode.home);
      expect(controller.canGoBack, isFalse);
    });

    test('leaves search results for the page before them', () {
      final controller = ready()..navigate(PageMode.history);
      controller.debugQuery = 'lofi';
      controller.navigate(PageMode.explore);
      controller.navigate(PageMode.settings);
      controller.goBack();
      expect((controller.mode, controller.query), (PageMode.explore, 'lofi'));
      controller.goBack();
      expect(controller.mode, PageMode.history);
    });

    test('with nothing earlier, closes the search and then goes home', () {
      final controller = ready()..mode = PageMode.explore;
      controller.debugQuery = 'lofi';
      controller.goBack();
      expect(controller.query, isNull);
      controller.goBack();
      expect(controller.mode, PageMode.home);
    });
  });
}
