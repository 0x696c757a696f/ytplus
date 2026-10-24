import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/ui/video_card.dart';

void main() {
  test('thumbnails decode at the card size, in steps, between 160 and 480', () {
    expect(thumbnailDecodeWidth(300, 1), 320);
    expect(thumbnailDecodeWidth(301, 1), 320);
    expect(thumbnailDecodeWidth(300, 1.25), 400);
    expect(thumbnailDecodeWidth(100, 1), 160);
    expect(thumbnailDecodeWidth(600, 2), 480);
  });
}
