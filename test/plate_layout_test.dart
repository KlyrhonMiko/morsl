import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/ui/memory_card.dart';
import 'package:morsl/ui/plate_layout.dart';
import 'package:morsl/ui/theme.dart';

void main() {
  test('rotated dishes stay clear of date, caption, and one another', () {
    for (var count = 1; count <= 15; count++) {
      final plates = List.generate(
        count,
        (i) => Plate(id: '$i', mask: '', aspect: const [.7, 1.0, 2.0][i % 3]),
      );
      arrangePlates(plates);
      final bounds = plates.map((p) {
        final cos = math.cos(p.rotation).abs();
        final sin = math.sin(p.rotation).abs();
        return Rect.fromCenter(
          center: Offset(p.x + p.scale / 2, p.y + p.scale * .96 / p.aspect / 2),
          width: p.scale * (cos + sin / p.aspect),
          height: p.scale * .96 * (sin + cos / p.aspect),
        );
      }).toList();
      for (var i = 0; i < bounds.length; i++) {
        expect(bounds[i].left, greaterThanOrEqualTo(.07999));
        expect(bounds[i].right, lessThanOrEqualTo(.92001));
        expect(bounds[i].top, greaterThanOrEqualTo(.11999));
        expect(bounds[i].bottom, lessThanOrEqualTo(.74001));
        for (var j = i + 1; j < bounds.length; j++) {
          expect(
            bounds[i].overlaps(bounds[j]),
            false,
            reason: '$count dishes: $i and $j',
          );
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

  for (final width in [375.0, 720.0]) {
    testWidgets('tabletop preview at $width', (tester) async {
      tester.view.physicalSize = Size(width, width / .96);
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
        for (var i = 0; i < paths.length; i++) {
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
          codec.dispose();
        }
      });
      arrangePlates(plates);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: morslTheme(),
          home: RepaintBoundary(
            key: key,
            child: MemoryCanvas(
              memory: Memory(
                id: 'preview',
                scope: 'guest',
                createdAt: DateTime(2026, 5, 21),
                original: '',
                plates: plates,
                useOriginal: false,
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
          'output/previews/tabletop-${width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}
