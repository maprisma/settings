import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sidebar scrolls and every entry can be dragged (Settings too, so it isn't pinned at the
/// bottom any more): scrolls the list itself until [key]'s entry is built, then shows it.
Future<void> showNavEntry(WidgetTester tester, String key) async {
  final entry = find.byKey(ValueKey(key));
  if (entry.evaluate().isEmpty) {
    final list = tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('sidebar')), matching: find.byType(Scrollable)).first);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pump();
  }
  await tester.ensureVisible(entry);
  await tester.pump();
}
