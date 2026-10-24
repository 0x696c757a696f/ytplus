import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';

void main() {
  test('accepts watch, short and shorts links', () {
    expect(AppController.parseYoutubeId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3'), 'dQw4w9WgXcQ');
    expect(AppController.parseYoutubeId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(AppController.parseYoutubeId('https://youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
  });

  test('treats other input as a search query', () {
    expect(AppController.parseYoutubeId('lofi hip hop'), isNull);
    expect(AppController.parseYoutubeId('http://www.youtube.com/watch?v=dQw4w9WgXcQ'), isNull);
    expect(AppController.parseYoutubeId('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
  });
}
