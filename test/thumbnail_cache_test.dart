import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/thumbnail_cache.dart';

void main() {
  test('cache files are named after the video id', () {
    final file = CachedThumbnail.fileFor(Directory('cache'), 'dQw4w9WgXcQ');
    expect(file.path, endsWith('dQw4w9WgXcQ.jpg'));
  });

  test('providers for the same video share an image cache key', () {
    final a = CachedThumbnail('https://i.ytimg.com/vi/x/hqdefault.jpg', File('a.jpg'));
    final b = CachedThumbnail('https://i.ytimg.com/vi/x/hqdefault.jpg', File('a.jpg'));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
