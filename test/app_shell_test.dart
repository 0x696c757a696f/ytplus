import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/app/app_controller.dart';
import 'package:lumtub/main.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, Size size, {Brightness? platformBrightness}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    if (platformBrightness != null) tester.platformDispatcher.platformBrightnessTestValue = platformBrightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(LumtubApp(controller: AppController()));
    await tester.pump();
  }

  testWidgets('wide windows show the navigation rail and search box', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Lumtub'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow windows switch to a bottom navigation bar', (tester) async {
    await pumpApp(tester, const Size(600, 800));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in the dark theme without layout errors', (tester) async {
    await pumpApp(tester, const Size(1280, 800), platformBrightness: Brightness.dark);
    final context = tester.element(find.byType(NavigationRail));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });
}
