import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/community_posts.dart';
import 'package:lumtub/models.dart';

Map<String, dynamic> _post(String id, {Map<String, dynamic>? attachment}) => {
      'backstagePostThreadRenderer': {
        'post': {
          'backstagePostRenderer': {
            'postId': id,
            'contentText': {'runs': [{'text': '新视频上线了 '}, {'text': '快去看看'}]},
            'publishedTimeText': {'runs': [{'text': '3天前'}]},
            'voteCount': {'simpleText': '1.2万'},
            if (attachment != null) 'backstageAttachment': attachment,
          },
        },
      },
    };

final _page = {
  'contents': {
    'twoColumnBrowseResultsRenderer': {
      'tabs': [
        {
          'tabRenderer': {
            'title': '帖子',
            'content': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'itemSectionRenderer': {
                      'contents': [
                        _post('Ugkx1', attachment: {
                          'postMultiImageRenderer': {
                            'images': [
                              {'backstageImageRenderer': {'image': {'thumbnails': [{'url': 'https://yt3.ggpht.com/a=s288'}, {'url': 'https://yt3.ggpht.com/a=s1080'}]}}},
                              {'backstageImageRenderer': {'image': {'thumbnails': [{'url': '//yt3.ggpht.com/b=s1080'}]}}},
                            ],
                          },
                        }),
                        _post('Ugkx2', attachment: {
                          'videoRenderer': {'videoId': 'dQw4w9WgXcQ', 'title': {'runs': [{'text': 'Never Gonna'}]}, 'lengthText': {'simpleText': '3:33'}},
                        }),
                        _post('Ugkx3', attachment: {
                          'pollRenderer': {'choices': [{'text': {'runs': [{'text': '是'}]}}, {'text': {'runs': [{'text': '否'}]}}]},
                        }),
                        {'continuationItemRenderer': {'continuationEndpoint': {'continuationCommand': {'token': 'NEXT'}}}},
                      ],
                    },
                  },
                ],
              },
            },
          },
        },
      ],
    },
  },
};

void main() {
  test('reads posts, images, videos, polls and the next token', () {
    final page = CommunityPosts.parse(_page);
    expect(page.posts.map((p) => p.id), ['Ugkx1', 'Ugkx2', 'Ugkx3']);
    expect(page.posts[0].text, '新视频上线了 快去看看');
    expect(page.posts[0].published, '3天前');
    expect(page.posts[0].likes, '1.2万');
    expect(page.posts[0].images, ['https://yt3.ggpht.com/a=s1080', 'https://yt3.ggpht.com/b=s1080']);
    expect(page.posts[1].video?.id, 'dQw4w9WgXcQ');
    expect(page.posts[1].video?.duration, 213);
    expect(page.posts[2].poll, ['是', '否']);
    expect(page.continuation, 'NEXT');
  });

  test('finds ytInitialData in the page despite braces inside strings', () {
    final html = '<script>var ytInitialData = ${jsonEncode({'a': '};{', 'b': {'c': 1}})};</script>';
    expect(CommunityPosts.initialData(html), {'a': '};{', 'b': {'c': 1}});
    expect(CommunityPosts.initialData('<html></html>'), isNull);
  });

  test('loads the first page from HTML and the next from the browse endpoint', () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response.bytes(utf8.encode('<script>ytcfg.set({"INNERTUBE_API_KEY":"KEY","INNERTUBE_CLIENT_VERSION":"2.2026"});var ytInitialData = ${jsonEncode(_page)};</script>'), 200);
      }
      return http.Response.bytes(utf8.encode(jsonEncode({'onResponseReceivedEndpoints': [{'appendContinuationItemsAction': {'continuationItems': [_post('Ugkx4')]}}]})), 200);
    });
    final posts = CommunityPosts(client);
    final first = await posts.first(const ChannelRef('UCuAXFkgsw1L7xaCfnd5JJOw', 'Rick'));
    expect(requests.single.url.toString(), 'https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw/posts?hl=zh-CN');
    final next = await posts.next(first.continuation!);
    expect(next.posts.single.id, 'Ugkx4');
    expect(next.continuation, isNull);
    expect(requests.last.url.queryParameters['key'], 'KEY');
    final body = jsonDecode(requests.last.body) as Map;
    expect(body['continuation'], 'NEXT');
    expect(body['context']['client']['clientVersion'], '2.2026');
  });
}
