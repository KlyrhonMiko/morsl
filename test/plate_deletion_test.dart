import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/plate_library.dart';

class PlateDeletionCloud extends CloudService {
  PlateDeletionCloud() : super(null, MediaStore());
  bool authorized = true;
  @override
  bool get signedInWithGoogle => authorized;
  @override
  String get account => 'account';
}

class PlateDeletionEngine implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async => original;
  @override
  String get runtime => 'test';
}

void main() {
  late MorslDatabase db;
  late MorslController app;
  late PlateDeletionCloud cloud;
  late Memory memory;

  setUp(() async {
    db = MorslDatabase(NativeDatabase.memory());
    cloud = PlateDeletionCloud();
    app = MorslController(
      repository: MemoryRepository(db),
      media: MediaStore(),
      cloud: cloud,
      engine: PlateDeletionEngine(),
      reminders: DraftReminders(),
    );
    final image = File('assets/images/salad.jpg').absolute.path;
    memory = Memory(
      id: 'meal',
      scope: 'account',
      createdAt: DateTime(2026, 10, 7),
      original: image,
      cutout: image,
      draft: false,
      useOriginal: false,
      job: JobStatus.ready,
      venue: 'Our restaurant',
      plates: [
        Plate(id: 'salad', mask: 'mask', path: image),
        Plate(id: 'pasta', mask: 'mask', path: image),
      ],
      plateReviews: {
        'salad': const PlateReview(name: 'Salad', stars: 4, note: 'Fresh'),
        'pasta': const PlateReview(name: 'Pasta', stars: 5),
      },
    );
    await app.repository.save(memory, enqueue: false);
    await app.reload();
  });

  tearDown(() async {
    app.dispose();
    await db.close();
  });

  test(
    'deletes only the chosen plate from the latest saved meal and queues sync',
    () async {
      final plate = LibraryPlate.fromMemories(app.memories).first;
      await app.repository.mutate(memory.id, memory.scope, (current) {
        current.caption = 'New meal caption';
      }, enqueue: false);
      await app.deletePlate(plate);
      final saved = (await app.repository.list('account')).single;
      expect(saved.plates.single.id, 'pasta');
      expect(saved.plateReviews.keys, ['pasta']);
      expect(saved.caption, 'New meal caption');
      expect(saved.venue, memory.venue);
      expect(saved.original, memory.original);
      expect(saved.platesEdited, true);
      expect(LibraryPlate.fromMemories(app.memories).single.plateId, 'pasta');
      final pending = (await app.repository.pending('account')).single;
      expect((pending.payload['plates'] as List).length, 1);
    },
  );

  test(
    'deleting the last plate clears the legacy fallback and keeps the meal',
    () async {
      await app.deletePlate(LibraryPlate.fromMemories(app.memories).first);
      await app.deletePlate(LibraryPlate.fromMemories(app.memories).single);
      await app.reload();
      expect(LibraryPlate.fromMemories(app.memories), isEmpty);
      expect(app.memories.single.cutout, isNull);
      expect(app.memories.single.plateReviews, isEmpty);
      expect(app.memories.single.useOriginal, true);
      expect(app.memories.single.original, memory.original);
    },
  );

  test(
    'legacy cutouts can be deleted without removing the source photo',
    () async {
      memory.plates = [];
      memory.plateReviews = {'__cutout__': const PlateReview(stars: 3)};
      await app.repository.save(memory, enqueue: false);
      await app.reload();
      await app.deletePlate(LibraryPlate.fromMemories(app.memories).single);
      expect(LibraryPlate.fromMemories(app.memories), isEmpty);
      expect(app.memories.single.original, memory.original);
      expect(app.memories.single.plateReviews, isEmpty);
    },
  );

  test(
    'rejects deletion when signed out or the plate belongs to another account',
    () async {
      final plate = LibraryPlate.fromMemories(app.memories).first;
      cloud.authorized = false;
      await expectLater(app.deletePlate(plate), throwsStateError);
      cloud.authorized = true;
      final other = memory.copy()..scope = 'other';
      await expectLater(
        app.deletePlate(LibraryPlate.fromMemories([other]).first),
        throwsStateError,
      );
      expect(
        (await app.repository.list('account')).single.plates,
        hasLength(2),
      );
      expect(await app.repository.pending('account'), isEmpty);
    },
  );

  test('stale deletion cannot overwrite or recreate a removed plate', () async {
    final plate = LibraryPlate.fromMemories(app.memories).first;
    await app.deletePlate(plate);
    await expectLater(app.deletePlate(plate), throwsStateError);
    expect(app.memories.single.plates.single.id, 'pasta');
    await app.repository.remove(memory.id, memory.scope);
    await expectLater(app.deletePlate(plate), throwsStateError);
    expect(await app.repository.list('account'), isEmpty);
  });

  testWidgets(
    'library deletion can be cancelled and returns to the updated library',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlateLibrary(
              app: app,
              onCapture: () {},
              onMealDetails: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Salad'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salad'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete plate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.memories.single.plates, hasLength(2));
      expect(find.byType(PlateDetails), findsOneWidget);
      await tester.tap(find.byTooltip('Delete plate'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Delete plate'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(PlateDetails), findsNothing);
      expect(find.text('Salad'), findsNothing);
      expect(find.text('Pasta'), findsOneWidget);
      expect(find.text('1 plate'), findsOneWidget);
      expect(find.text('Plate deleted.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
