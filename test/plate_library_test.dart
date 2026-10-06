import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/creations.dart';

void main() {
  Memory meal(String id) => Memory(
    id: id,
    scope: 'a',
    createdAt: DateTime(2026, 10, 6, 12, 30),
    original: 'source.jpg',
    venue: 'A restaurant',
    plates: [
      Plate(id: 'salad', mask: 'mask', path: 'salad.png'),
      Plate(id: 'pasta', mask: 'mask', path: 'pasta.png'),
    ],
  );

  test('each cutout retains meal metadata and an independent food review', () {
    final memory = meal('meal')
      ..plateReviews = {
        'salad': const PlateReview(
          stars: 4,
          note: 'Fresh',
          name: 'Green salad',
        ),
        'pasta': const PlateReview(stars: 2, note: 'Too salty'),
      };
    final restored = memory.copy();
    final entries = LibraryPlate.fromMemories([restored]);
    expect(entries.length, 2);
    expect(entries.first.title, 'Green salad');
    expect(entries.first.review.stars, 4);
    expect(entries.last.review.stars, 2);
    expect(entries.first.memory.venue, 'A restaurant');
    expect(entries.last.memory.createdAt.hour, 12);
    expect(restored.rating, isNull); // Segmentation feedback is separate.
    expect(restored.plateReviews['salad']!.note, 'Fresh');
  });

  test('legacy cutouts join the library; photos and archived meals do not', () {
    final legacy = meal('legacy')
      ..plates = []
      ..cutout = 'legacy.png';
    final photoOnly = meal('photo')..plates = [];
    final archived = meal('archived')..archived = true;
    final entries = LibraryPlate.fromMemories([legacy, photoOnly, archived]);
    expect(entries.single.key, 'legacy/__cutout__');
    expect(entries.single.path, 'legacy.png');
    final oldJson = legacy.toJson()..remove('plateReviews');
    expect(Memory.fromJson(oldJson).plateReviews, isEmpty);
  });

  test(
    'saved arrangements mix meals, reopen with transforms, and stay account scoped',
    () async {
      final db = MorslDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = MemoryRepository(db);
      final sourceA = meal('a');
      final sourceB = meal('b')..venue = 'Another restaurant';
      await repository.save(sourceA, enqueue: false);
      await repository.save(sourceB, enqueue: false);
      final creation = PlateCreation(
        id: 'photo',
        updatedAt: DateTime(2026, 10, 6),
        title: 'Favorite bites',
        background: 'sage',
        plates: [
          PlacedPlate(key: 'a/salad', x: .1, y: .2, scale: .3, rotation: .5),
          PlacedPlate(key: 'b/pasta', x: .5, y: .1, scale: .4),
        ],
      );
      final store = CreationStore(repository, 'a');
      await store.save(creation);
      final restored = (await store.list()).single;
      expect(restored.title, 'Favorite bites');
      expect(restored.background, 'sage');
      expect(restored.plates.last.key, 'b/pasta');
      expect(restored.plates.first.rotation, .5);
      expect(await CreationStore(repository, 'b').list(), isEmpty);
      restored.plates.first.x = .6;
      await store.save(restored);
      expect((await store.list()).length, 1);
      expect((await store.list()).single.plates.first.x, .6);
      final sources = await repository.list('a');
      expect(sources.first.plates.first.x, sourceA.plates.first.x);
      expect(sources.last.plates.last.path, 'pasta.png');
    },
  );
}
