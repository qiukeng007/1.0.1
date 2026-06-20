import 'package:flutter_test/flutter_test.dart';
import 'package:smart_eye_stock/app.dart';

void main() {
  testWidgets('App builds smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartEyeApp());
    expect(find.text('智慧眼'), findsOneWidget);
  });
}
