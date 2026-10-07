import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/ui/theme.dart';
import 'package:morsl/ui/tools.dart';

void main() {
  testWidgets('import feedback updates before the draft is ready', (
    tester,
  ) async {
    final progress = ValueNotifier<(int, int)?>(null);
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Center(
              child: SizedBox(
                width: 280,
                child: PhotoImportFeedback(progress: progress),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Preparing photos…'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );

    progress.value = (0, 24);
    await tester.pump();
    expect(find.text('Importing 24 photos…'), findsOneWidget);
    progress.value = (12, 24);
    await tester.pump();
    expect(find.text('12 of 24 photos saved'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );

    progress.value = (24, 24);
    await tester.pump();
    expect(find.text('Saving your draft…'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    progress.dispose();
  });
}
