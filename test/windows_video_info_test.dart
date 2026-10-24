import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/windows_video_info.dart';

void main() {
  test('video information has a non-destructive unknown default', () {
    const info = WindowsVideoInfo();
    expect(info.gpuNames, isEmpty);
    expect(info.vp9Extension, ExtensionStatus.unknown);
    expect(info.av1Extension, ExtensionStatus.unknown);
  });
}
