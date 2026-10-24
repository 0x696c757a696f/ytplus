import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/youtube_comments.dart';

Map<String, Object?> _continuation(String token) => {
      'continuationItemRenderer': {
        'continuationEndpoint': {
          'continuationCommand': {'token': token},
        },
      },
    };

Map<String, Object?> _entity(String id, String text, {String replies = '0'}) => {
      'entityKey': 'key-$id',
      'payload': {
        'commentEntityPayload': {
          'properties': {'commentId': id, 'content': {'content': text}, 'publishedTime': '3天前'},
          'author': {'displayName': '@作者$id', 'channelId': 'UCabcdefghijklmnopqrstuv', 'avatarThumbnailUrl': 'https://yt3.example/a.jpg', 'isCreator': id == 'b'},
          'toolbar': {'likeCountNotliked': '1.2万', 'replyCount': replies},
        },
      },
    };

void main() {
  test('builds the comment section token as yt-dlp does', () {
    final bytes = base64.decode(YoutubeComments.videoSectionToken('dQw4w9WgXcQ'));
    expect(utf8.decode(bytes), contains('dQw4w9WgXcQ'));
    expect(utf8.decode(bytes), endsWith('comments-section'));
    expect(bytes.take(4), [0x12, 0x0d, 0x12, 0x0b]);
  });

  test('reads the header with its sort orders', () {
    final page = YoutubeComments.parse({
      'onResponseReceivedEndpoints': [
        {
          'reloadContinuationItemsCommand': {
            'continuationItems': [
              {
                'commentsHeaderRenderer': {
                  'countText': {'runs': [{'text': '1,234'}, {'text': ' 条评论'}]},
                  'sortMenu': {
                    'sortFilterSubMenuRenderer': {
                      'subMenuItems': [
                        {'title': '热门评论', 'serviceEndpoint': {'continuationCommand': {'token': 'TOP'}}},
                        {'title': '最新', 'serviceEndpoint': {'continuationCommand': {'token': 'NEW'}}},
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      ],
    });
    expect((page.count, page.topToken, page.newestToken, page.comments.length), ('1,234 条评论', 'TOP', 'NEW', 0));
  });

  test('reads view-model comments from the entity payloads', () {
    final page = YoutubeComments.parse({
      'onResponseReceivedEndpoints': [
        {
          'reloadContinuationItemsCommand': {
            'continuationItems': [
              {
                'commentThreadRenderer': {
                  'commentViewModel': {
                    'commentViewModel': {'commentKey': 'key-a', 'toolbarStateKey': 'toolbar-a', 'pinnedText': '已置顶'},
                  },
                  'replies': {
                    'commentRepliesRenderer': {
                      'contents': [_continuation('REPLIES-A')],
                    },
                  },
                },
              },
              {
                'commentThreadRenderer': {
                  'commentViewModel': {
                    'commentViewModel': {'commentKey': 'key-b'},
                  },
                },
              },
              _continuation('PAGE-2'),
            ],
          },
        },
      ],
      'frameworkUpdates': {
        'entityBatchUpdate': {
          'mutations': [
            _entity('a', '第一条 1:23', replies: '12'),
            _entity('b', '作者回复'),
            {'entityKey': 'toolbar-a', 'payload': {'engagementToolbarStateEntityPayload': {'heartState': 'TOOLBAR_HEART_STATE_HEARTED'}}},
          ],
        },
      },
    });
    expect(page.comments.map((c) => c.id), ['a', 'b']);
    final a = page.comments.first;
    expect((a.text, a.author, a.likes, a.replyCount, a.repliesToken, a.pinned, a.hearted, a.byUploader), ('第一条 1:23', '@作者a', '1.2万', 12, 'REPLIES-A', true, true, false));
    expect((page.comments[1].repliesToken, page.comments[1].byUploader), (null, true));
    expect(page.continuation, 'PAGE-2');
  });

  test('reads replies and the older comment renderer', () {
    final page = YoutubeComments.parse({
      'onResponseReceivedEndpoints': [
        {
          'appendContinuationItemsAction': {
            'continuationItems': [
              {
                'commentRenderer': {
                  'commentId': 'old',
                  'authorText': {'simpleText': '@old'},
                  'contentText': {'runs': [{'text': '旧格式'}]},
                  'publishedTimeText': {'runs': [{'text': '1年前'}]},
                  'voteCount': {'simpleText': '5'},
                  'authorThumbnail': {'thumbnails': [{'url': '//yt3.example/s.jpg'}, {'url': '//yt3.example/l.jpg'}]},
                  'authorIsChannelOwner': true,
                },
              },
              {
                'continuationItemRenderer': {
                  'button': {
                    'buttonRenderer': {
                      'command': {'continuationCommand': {'token': 'MORE-REPLIES'}},
                    },
                  },
                },
              },
            ],
          },
        },
      ],
    });
    final old = page.comments.single;
    expect((old.author, old.text, old.published, old.likes, old.avatar, old.byUploader), ('@old', '旧格式', '1年前', '5', 'https://yt3.example/l.jpg', true));
    expect(page.continuation, 'MORE-REPLIES');
  });

  test('finds the comment section of a post page', () {
    final data = {
      'contents': [
        {'itemSectionRenderer': {'sectionIdentifier': 'other', 'contents': [_continuation('NO')]}},
        {'itemSectionRenderer': {'sectionIdentifier': 'comment-item-section', 'contents': [_continuation('POST-COMMENTS')]}},
      ],
    };
    expect(YoutubeComments.sectionToken(data), 'POST-COMMENTS');
  });

  test('loads the header, then the chosen sort order', () async {
    final asked = <String>[];
    final comments = YoutubeComments(MockClient((request) async {
      final token = (jsonDecode(request.body) as Map)['continuation'] as String;
      asked.add('${request.url.path} ${token.length > 10 ? 'SECTION' : token}');
      final items = token == 'NEW'
          ? [
              {'commentRenderer': {'commentId': 'n', 'contentText': {'simpleText': '新'}}},
            ]
          : [
              {
                'commentsHeaderRenderer': {
                  'countText': {'simpleText': '2'},
                  'sortMenu': {
                    'sortFilterSubMenuRenderer': {
                      'subMenuItems': [
                        {'serviceEndpoint': {'continuationCommand': {'token': 'TOP'}}},
                        {'serviceEndpoint': {'continuationCommand': {'token': 'NEW'}}},
                      ],
                    },
                  },
                },
              },
            ];
      return http.Response.bytes(utf8.encode(jsonEncode({
        'onResponseReceivedEndpoints': [
          {'reloadContinuationItemsCommand': {'continuationItems': items}},
        ],
      })), 200);
    }));
    final page = await comments.video('dQw4w9WgXcQ', newest: true);
    expect(asked, ['/youtubei/v1/next SECTION', '/youtubei/v1/next NEW']);
    expect((page.count, page.comments.single.text), ('2', '新'));
  });
}
