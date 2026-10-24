import 'package:flutter_test/flutter_test.dart';
import 'package:lumtub/ui/linked_text.dart';

void main() {
  test('finds times and links in a description', () {
    final parts = splitLinks('0:00 Intro\n12:34 Main\n1:02:03 End https://example.com/a?b=1&c=2 more');
    final times = parts.whereType<TimePart>().map((p) => p.time).toList();
    expect(times, [Duration.zero, const Duration(minutes: 12, seconds: 34), const Duration(hours: 1, minutes: 2, seconds: 3)]);
    expect(parts.whereType<LinkPart>().single.text, 'https://example.com/a?b=1&c=2');
    expect(parts.map((p) => p.text).join(), '0:00 Intro\n12:34 Main\n1:02:03 End https://example.com/a?b=1&c=2 more');
  });

  test('leaves things that are not times alone', () {
    expect(splitLinks('ratio 1:75, version 1.2:30, 10:00:00:00').whereType<TimePart>(), isEmpty);
    expect(splitLinks('no links here').single, isA<PlainPart>());
  });
}
