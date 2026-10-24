import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/app_window.dart';

void main() {
  test('picture in picture is 280 on its short side and keeps the ratio', () {
    final wide = pipSizeFor(16 / 9);
    expect((wide.height, wide.width.round()), (280, 498));
    final tall = pipSizeFor(9 / 16);
    expect((tall.width, tall.height.round()), (280, 498));
    final square = pipSizeFor(1, shortSide: 160);
    expect((square.width, square.height), (160, 160));
  });

  test('an unknown or extreme ratio falls back to something sensible', () {
    expect(pipAspectOf(0), 16 / 9);
    expect(pipAspectOf(double.nan), 16 / 9);
    expect(pipAspectOf(-1), 16 / 9);
    expect(pipAspectOf(21 / 9), 21 / 9);
    expect(pipAspectOf(10), 3.0);
    expect(pipAspectOf(0.1), 0.4);
  });

  test('without a player the ratio is 16:9 and entering does nothing off Windows', () {
    final controller = AppController();
    expect(controller.videoAspect, 16 / 9);
    controller.updatePipAspect();
    expect(AppWindow.enterPip(aspect: 16 / 9), isFalse);
    expect(AppWindow.exitPip(), isFalse);
    expect(controller.pip, isFalse);
  });
}
