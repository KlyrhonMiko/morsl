import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/editor.dart';
import 'package:morsl/ui/meal_layout_selector.dart';
import 'package:morsl/ui/plate_preview_pager.dart';

class _Cloud extends CloudService {
  _Cloud(MediaStore media) : super(null, media);
  @override
  bool get signedInWithGoogle => true;
  @override
  String get account => 'account';
}

class _Engine implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async => original;
  @override
  String get runtime => 'test';
}

void main() {
  testWidgets('meal editor previews, saves and restores each layout', (
    tester,
  ) async {
    final db = MorslDatabase(NativeDatabase.memory());
    final media = MediaStore();
    final app = MorslController(
      repository: MemoryRepository(db),
      media: media,
      cloud: _Cloud(media),
      engine: _Engine(),
      reminders: DraftReminders(),
    );
    addTearDown(() async {
      app.dispose();
      await db.close();
    });
    final memory = Memory(
      id: 'meal',
      scope: 'account',
      createdAt: DateTime(2026),
      original: File('assets/images/salad.jpg').absolute.path,
      job: JobStatus.ready,
      plates: List.generate(
        6,
        (i) => Plate(
          id: '$i',
          mask: '',
          path: File('assets/images/salad-cutout.png').absolute.path,
          aspect: i.isEven ? .7 : 1.3,
        ),
      ),
    );
    await tester.runAsync(() => app.repository.save(memory, enqueue: false));
    app.memories = [memory];
    Widget editor(Memory m) => ProviderScope(
      overrides: [appProvider.overrideWithValue(app)],
      child: MaterialApp(home: PlatingEditor(memory: m)),
    );
    await tester.pumpWidget(editor(memory));
    await tester.pumpAndSettle();
    final savedPoses = <String>[];
    for (final style in ['editorial', 'scrapbook', 'clean']) {
      final option = find.byKey(ValueKey('layout-$style'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        // Let the editor's debounced database write and reload complete.
        for (var i = 0; i < 30; i++) {
          if ((await app.repository.list('account')).single.plateLayout ==
              style) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      final restored = await tester.runAsync(
        () => app.repository.list('account'),
      );
      expect(restored!.single.plateLayout, style);
      expect(restored.single.platesEdited, isFalse);
      savedPoses.add(
        restored.single.plates
            .map((p) => '${p.x},${p.y},${p.scale},${p.rotation}')
            .join(';'),
      );
    }
    expect(savedPoses.toSet(), hasLength(3));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final restored = await tester.runAsync(
      () => app.repository.list('account'),
    );
    await tester.pumpWidget(editor(restored!.single));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MealLayoutSelector>(find.byType(MealLayoutSelector))
          .memory
          .plateLayout,
      'clean',
    );
    await tester.ensureVisible(find.text('Plate cutouts'));
    await tester.tap(find.text('Plate cutouts'));
    await tester.pumpAndSettle();
    expect(find.byType(PlatePreviewPager), findsOneWidget);
    expect(find.text('Clean up edges'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
