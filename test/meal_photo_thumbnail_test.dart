import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:morsl/services/media.dart';
import 'package:morsl/ui/meal_photo_thumbnail.dart';

class PhotoFixtureStore extends MediaStore {
  bool fail = true;
  int reads = 0;

  @override
  Future<Uint8List> read(String ref) async {
    reads++;
    if (fail) throw StateError('Temporary download failure');
    return Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 16)));
  }
}

void main() {
  testWidgets('a failed photo can be downloaded again from its tile', (
    tester,
  ) async {
    final previous = MediaStore.imageStore;
    final store = PhotoFixtureStore();
    MediaStore.imageStore = store;
    addTearDown(() {
      MediaStore.imageStore = previous;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 120,
            child: MealPhotoThumbnail(path: 'morsl-cloud:test-photo'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Retry photo'), findsOneWidget);
    expect(store.reads, 1);

    store.fail = false;
    await tester.tap(find.text('Retry photo'));
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(store.reads, 2);
    expect(find.text('Retry photo'), findsNothing);
    expect(find.text('Loading photo…'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
