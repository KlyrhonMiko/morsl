import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/ui/memory_card.dart';
import 'package:morsl/ui/meal_layout_selector.dart';
import 'package:morsl/ui/plate_layout.dart';
import 'package:morsl/ui/theme.dart';

void main() {
  test(
    'auto layouts and overlap order do not depend on photo selection order',
    () {
      for (final style in ['editorial', 'scrapbook', 'clean']) {
        for (final count in [1, 2, 3, 4, 5, 6, 7, 12]) {
          final originals = List.generate(
            count,
            (i) => Plate(
              id: 'dish-$i',
              mask: 'silhouette-$i',
              photoId: 'photo-$i',
              aspect: const [1.4, .62, .95, .48, .60, .42][i % 6],
              rotationSteps: i == 1 ? 2 : 0,
            ),
          );
          final expected = originals.map((p) => p.copy()).toList();
          arrangePlates(expected, style: style);
          final random = math.Random(42);
          for (var attempt = 0; attempt < 20; attempt++) {
            final shuffled = originals.map((p) => p.copy()).toList()
              ..shuffle(random);
            arrangePlates(shuffled, style: style);
            expect(
              shuffled.map((p) => p.toJson()).toList(),
              expected.map((p) => p.toJson()).toList(),
              reason: '$style: $count dishes, shuffle $attempt',
            );
            // Running the arranger again must not drift or change layering.
            arrangePlates(shuffled, style: style);
            expect(
              shuffled.map((p) => p.toJson()).toList(),
              expected.map((p) => p.toJson()).toList(),
            );
          }
        }
      }
    },
  );

  test('scrapbook assigns broad and round dishes to its anchors', () {
    final plates = [
      Plate(id: 'narrow', mask: '', aspect: .4),
      Plate(id: 'side', mask: '', aspect: .55),
      Plate(id: 'medium', mask: '', aspect: .8),
      Plate(id: 'portrait', mask: '', aspect: .72),
      Plate(id: 'round', mask: '', aspect: 1.0),
      Plate(id: 'broad', mask: '', aspect: 1.35),
    ];
    arrangePlates(plates, style: 'scrapbook');
    expect(plates.first.id, 'broad');
    expect(plates[2].id, 'round');
    expect(plates.last.id, 'narrow');
  });

  test('painting a saved auto layout does not reassign rotated plates', () {
    for (final style in ['', 'editorial', 'scrapbook', 'clean']) {
      final plates = [
        Plate(id: 'broad', mask: '', aspect: 1.4),
        Plate(id: 'round', mask: '', aspect: 1),
        Plate(id: 'narrow', mask: '', aspect: .45),
      ];
      arrangePlates(plates, style: style.isEmpty ? 'editorial' : style);
      plates.first.rotationSteps = 2;
      final saved = plates.map((plate) => plate.toJson()).toList();
      expect(identical(displayPlates(plates, style: style), plates), isTrue);
      expect(plates.map((plate) => plate.toJson()).toList(), saved);
    }
  });

  test(
    'returning to Editorial restores its original poses after cutout turns',
    () {
      final plates = [
        Plate(id: 'dessert', mask: '', aspect: 1.4),
        Plate(id: 'roast', mask: '', aspect: .7),
        Plate(id: 'bowl', mask: '', aspect: 1),
        Plate(id: 'fries', mask: '', aspect: .6),
        Plate(id: 'salad', mask: '', aspect: .5),
        Plate(id: 'chips', mask: '', aspect: .45),
      ];
      arrangePlates(plates, style: 'editorial');
      final original = plates.map((plate) => plate.copy()).toList();
      plates.firstWhere((plate) => plate.id == 'roast').rotationSteps = 2;
      plates.firstWhere((plate) => plate.id == 'chips').rotationSteps = 1;
      arrangePlates(plates, style: 'scrapbook');
      arrangePlates(plates, style: 'editorial');
      for (var i = 0; i < plates.length; i++) {
        expect(plates[i].id, original[i].id);
        expect(plates[i].x, closeTo(original[i].x, .00001));
        expect(plates[i].y, closeTo(original[i].y, .00001));
        expect(plates[i].scale, closeTo(original[i].scale, .00001));
        expect(plates[i].rotation, closeTo(original[i].rotation, .00001));
      }
    },
  );

  test(
    '45-degree orientation is saved and older 90-degree turns still load',
    () {
      final plate = Plate(id: 'dish', mask: '', aspect: .55, rotationSteps: 1);
      expect(plate.orientedAspect, closeTo(1, .0001));
      expect(Plate.fromJson(plate.toJson()).rotationSteps, 1);

      final legacy = Plate.fromJson({
        'id': 'older-dish',
        'mask': '',
        'aspect': .55,
        'quarterTurns': 1,
      });
      expect(legacy.rotationSteps, 2);
      expect(legacy.orientedAspect, closeTo(1 / .55, .0001));
    },
  );

  test('six independently arranged photos become one meal collage', () {
    final plates = List.generate(6, (i) {
      final group = [
        Plate(
          id: '$i',
          mask: '',
          photoId: i == 0 ? null : 'photo-$i',
          aspect: const [.7, 1.0, 2.0][i % 3],
        ),
      ];
      arrangePlates(group);
      return group.single;
    });
    final saved = plates.map((p) => p.toJson()).toList();
    final expected = plates.map((p) => p.copy()).toList();
    arrangePlates(expected);
    expect(
      displayPlates(plates).map((p) => p.toJson()).toList(),
      expected.map((p) => p.toJson()).toList(),
    );
    expect(plates.map((p) => p.toJson()).toList(), saved);
    expect(identical(displayPlates(plates, edited: true), plates), isTrue);
    plates.first.x += .03;
    expect(identical(displayPlates(plates), plates), isTrue);
  });

  test('multiple dishes per source photo are composed together', () {
    final plates = <Plate>[];
    for (var photo = 0; photo < 3; photo++) {
      final group = List.generate(
        2,
        (i) => Plate(id: '$photo-$i', mask: '', photoId: 'photo-$photo'),
      );
      arrangePlates(group);
      plates.addAll(group);
    }
    final expected = plates.map((p) => p.copy()).toList();
    arrangePlates(expected);
    expect(
      displayPlates(plates).map((p) => p.toJson()).toList(),
      expected.map((p) => p.toJson()).toList(),
    );
  });

  test('collage keeps rotated dishes between date and caption', () {
    for (final style in ['editorial', 'scrapbook', 'clean']) {
      for (final aspects in const [
        [.7, 1.0, 2.0],
        [1.4, .62, .95, .48, .60, .42],
      ]) {
        for (var count = 1; count <= 15; count++) {
          final plates = List.generate(
            count,
            (i) =>
                Plate(id: '$i', mask: '', aspect: aspects[i % aspects.length]),
          );
          arrangePlates(plates, style: style);
          final bounds = plates.map((p) {
            final cos = math.cos(p.rotation).abs();
            final sin = math.sin(p.rotation).abs();
            return Rect.fromCenter(
              center: Offset(
                p.x + p.scale / 2,
                p.y + p.scale * .96 / p.aspect / 2,
              ),
              width: p.scale * (cos + sin / p.aspect),
              height: p.scale * .96 * (sin + cos / p.aspect),
            );
          }).toList();
          for (var i = 0; i < bounds.length; i++) {
            expect(bounds[i].left, greaterThanOrEqualTo(.05999));
            expect(bounds[i].right, lessThanOrEqualTo(.94001));
            expect(bounds[i].top, greaterThanOrEqualTo(.11999));
            expect(bounds[i].bottom, lessThanOrEqualTo(.80001));
            for (var j = i + 1; j < bounds.length; j++) {
              final overlap = bounds[i].intersect(bounds[j]);
              if (!overlap.isEmpty) {
                final smaller = math.min(
                  bounds[i].width * bounds[i].height,
                  bounds[j].width * bounds[j].height,
                );
                expect(
                  overlap.width * overlap.height / smaller,
                  lessThan(.5),
                  reason:
                      '$style: $count dishes: $i and $j remain recognizable',
                );
              }
            }
          }
        }
      }
    }
  });

  test('old grids refresh without mutating saved or custom positions', () {
    final plates = List.generate(
      6,
      (i) => Plate(
        id: '$i',
        mask: '',
        x: .08 + i % 2 * .42 + (.42 - .62 / 3) / 2,
        y: .12 + i ~/ 2 * (.62 / 3) + (.62 / 3 - .62 / 3 * .91) / 2,
        scale: .62 / 3,
      ),
    );
    final refreshed = displayPlates(plates);
    expect(refreshed.first.rotation, isNonZero);
    expect(plates.first.rotation, 0);
    plates.first.x += .03;
    expect(identical(displayPlates(plates), plates), true);
  });

  for (final (width, count, style) in [
    (375.0, 6, 'editorial'),
    (720.0, 6, 'editorial'),
    (375.0, 6, 'scrapbook'),
    (375.0, 6, 'clean'),
    (375.0, 2, 'editorial'),
    (375.0, 3, 'editorial'),
  ]) {
    testWidgets('$style $count plate collage at $width', (tester) async {
      tester.view.physicalSize = Size(width, width / .96 + width / 3 + 190);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final paths = ['pasta', 'salad', 'pastry', 'pizza', 'salad', 'pastry'];
      final plates = <Plate>[];
      await tester.runAsync(() async {
        for (final font in ['Quicksand', 'Caveat']) {
          await (FontLoader(
            font,
          )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
        }
        for (var i = 0; i < count; i++) {
          final path = 'assets/images/${paths[i]}-cutout.png';
          final codec = await ui.instantiateImageCodec(
            await File(path).readAsBytes(),
          );
          final frame = await codec.getNextFrame();
          plates.add(
            Plate(
              id: '$i',
              mask: '',
              path: path,
              aspect: frame.image.width / frame.image.height,
            ),
          );
          final provider = FileImage(File(path));
          PaintingBinding.instance.imageCache.putIfAbsent(
            await provider.obtainKey(const ImageConfiguration()),
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image)),
            ),
          );
          final thumbnail = ResizeImage.resizeIfNeeded(200, null, provider);
          PaintingBinding.instance.imageCache.putIfAbsent(
            await thumbnail.obtainKey(const ImageConfiguration()),
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image.clone())),
            ),
          );
          codec.dispose();
        }
      });
      arrangePlates(plates, style: style);
      final memory = Memory(
        id: 'preview',
        scope: 'guest',
        createdAt: DateTime(2026, 5, 21),
        original: '',
        plates: plates,
        useOriginal: false,
        plateLayout: style,
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: morslTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: Palette.paper,
                child: Column(
                  children: [
                    SizedBox(
                      height: width / .96,
                      child: MemoryCanvas(memory: memory),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: MealLayoutSelector(
                        memory: memory,
                        onSelected: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('output/previews').create(recursive: true);
        await File(
          'output/previews/collage-$style-$count-${width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
