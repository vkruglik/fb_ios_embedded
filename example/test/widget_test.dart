import 'package:fb_ios_embedded_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the probe screen shows its buttons', (tester) async {
    await tester.pumpWidget(const ProbeApp());
    for (final t in ['Paths', 'Deploy', 'Create database', 'Attach',
        'Write/read', 'Collation', 'Version', 'Detach']) {
      expect(find.text(t), findsOneWidget);
    }
  });
}
