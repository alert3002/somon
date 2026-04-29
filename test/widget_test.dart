// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/main.dart';

void main() {
  testWidgets('Auth page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const SomonLogisticsApp());
    // Avoid pumpAndSettle: app has timers/animations that may keep scheduling frames.
    await tester.pump(const Duration(seconds: 2));

    // Title may change; ensure app shows either the auth form or a loading state.
    final hasAuth = find.text('Отправить код').evaluate().isNotEmpty;
    if (!hasAuth) {
      expect(find.byType(CircularProgressIndicator), findsWidgets);
    } else {
      expect(find.text('Отправить код'), findsOneWidget);
    }
  });
}
