import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/ui/comments_view.dart';

void main() {
  testWidgets('posts the text and clears the field once it went through', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CommentComposer(hint: '添加评论…', onSubmit: (text) async {
      sent.add(text);
      return true;
    }))));
    final send = find.widgetWithText(FilledButton, '发布');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  第一条  ');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    expect(sent, ['第一条']);
    expect(find.text('  第一条  '), findsNothing);
  });
}
