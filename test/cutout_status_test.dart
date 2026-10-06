import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/ui/cutout_status.dart';
import 'package:morsl/ui/theme.dart';

void main() {
  Widget host(JobStatus job, {bool reducedMotion = false, double scale = 1}) =>
      MaterialApp(
        theme: morslTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              disableAnimations: reducedMotion,
              textScaler: TextScaler.linear(scale),
            ),
            child: Center(
              child: SizedBox(width: 280, child: CutoutStatus(job: job)),
            ),
          ),
        ),
      );

  testWidgets('queued, active, finished and failed states stay accurate', (
    tester,
  ) async {
    await tester.pumpWidget(host(JobStatus.queued));
    expect(find.text('Waiting for cutout'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(host(JobStatus.processing));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Creating your cutout…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final semantics = tester.widgetList<Semantics>(find.byType(Semantics));
    expect(semantics.any((node) => node.properties.liveRegion == true), isTrue);

    for (final job in [JobStatus.ready, JobStatus.failed]) {
      await tester.pumpWidget(host(job));
      await tester.pumpAndSettle();
      expect(find.text('Creating your cutout…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
  });

  testWidgets('reduced motion keeps feedback and large text fits', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(JobStatus.processing, reducedMotion: true, scale: 2),
    );
    await tester.pumpAndSettle();
    expect(find.text('Creating your cutout…'), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
