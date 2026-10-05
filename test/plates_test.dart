import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:morsl/data/models.dart';
import 'package:morsl/services/plates.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/ui/memory_card.dart';
import 'package:morsl/ui/plate_tools.dart';

class OfflineEngine implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> prepare() async => false;
  @override
  Future<String> process(String original, String output) async =>
      throw StateError('offline');
  @override
  String get runtime => 'offline';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String original;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('morsl-plates-');
    original = '${directory.path}/original.png';
    final source = img.Image(width: 20, height: 20, numChannels: 3);
    for (final pixel in source) {
      pixel.setRgb(pixel.x * 10, pixel.y * 10, 70);
    }
    await File(original).writeAsBytes(img.encodePng(source));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(plateChannel, null);
    await directory.delete(recursive: true);
  });

  test(
    'plate masks persist with independent transforms and portable backup data',
    () {
      final memory = Memory(
        id: 'm',
        scope: 'guest',
        createdAt: DateTime(2026),
        original: original,
        plates: [
          Plate(
            id: 'one',
            mask: solidPlateMask(),
            path: '/local/one',
            x: .12,
            rotation: .5,
          ),
          Plate(
            id: 'two',
            mask: solidPlateMask(),
            path: '/local/two',
            x: .7,
            scale: .3,
          ),
        ],
        useOriginal: false,
      );
      final restored = Memory.fromJson(jsonDecode(memory.encode()));
      expect(restored.displaysCutout, true);
      restored.plates.first.x = .6;
      expect(restored.plates.last.x, .7);
      expect(memory.plates.first.x, .12);
      expect(restored.plates.last.scale, .3);
      expect(restored.plates.first.rotation, .5);
      expect(
        restored.plates.first.toJson(local: false).containsKey('path'),
        false,
      );
      final legacy = memory.toJson()
        ..remove('plates')
        ..remove('platesEdited');
      expect(Memory.fromJson(legacy).plates, isEmpty);
    },
  );

  test(
    'automatic layout fits four dishes without overlap or caption clipping',
    () {
      final plates = [2.0, 0.9, 0.7, 0.75].indexed
          .map(
            (entry) => Plate(
              id: '${entry.$1}',
              mask: solidPlateMask(),
              aspect: entry.$2,
            ),
          )
          .toList();
      arrangePlates(plates);
      final bounds = plates
          .map(
            (p) => Rect.fromLTWH(p.x, p.y, p.scale, p.scale * .91 / p.aspect),
          )
          .toList();
      for (var i = 0; i < bounds.length; i++) {
        expect(bounds[i].left, greaterThanOrEqualTo(.08));
        expect(bounds[i].right, lessThanOrEqualTo(.92));
        expect(bounds[i].top, greaterThanOrEqualTo(.12));
        expect(bounds[i].bottom, lessThanOrEqualTo(.74));
        for (var j = i + 1; j < bounds.length; j++) {
          expect(bounds[i].overlaps(bounds[j]), isFalse);
        }
      }
    },
  );

  test(
    'rendering retains original RGB pixels and crops only the selected region',
    () async {
      final alpha = img.Image(width: 10, height: 10, numChannels: 4);
      for (final pixel in alpha) {
        pixel.setRgba(255, 255, 255, pixel.x < 5 ? 0 : 255);
      }
      final plate = Plate(
        id: 'one',
        mask: base64Encode(img.encodePng(alpha)),
        left: .5,
        top: .5,
        width: .5,
        height: .5,
      );
      final output = img.decodePng(
        renderPlateBytes({'original': original, 'plate': plate.toJson()}),
      )!;
      expect(output.width, 10);
      expect(output.height, 10);
      expect(output.getPixel(1, 1).a, 0);
      expect(output.getPixel(8, 8).a, 255);
      expect(output.getPixel(8, 8).r, 180);
      expect(output.getPixel(8, 8).g, 180);
      expect(output.getPixel(8, 8).b, 70);
      final rendered = await renderPlate(original, directory.path, plate);
      final restored = await renderPlate(
        original,
        directory.path,
        Plate.fromJson(plate.toJson(local: false)),
      );
      expect(rendered.path, restored.path);
      expect(await File(rendered.path).exists(), true);
      expect(img.decodePng(await File(original).readAsBytes())!.width, 20);
    },
  );

  test(
    'multiple model masks map from a selection back to original coordinates',
    () async {
      final alpha = img.Image(width: 4, height: 6, numChannels: 4);
      for (final pixel in alpha) {
        pixel.setRgba(255, 255, 255, 255);
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(plateChannel, (call) async {
            expect(call.method, 'subjects');
            expect(await File((call.arguments as Map)['path']).exists(), true);
            return [
              {
                'mask': img.encodePng(alpha),
                'bounds': [.1, .2, .4, .6],
              },
              {
                'mask': img.encodePng(alpha),
                'bounds': [.5, .1, .3, .5],
              },
            ];
          });
      final plates = await detectPlates(
        original,
        directory.path,
        region: Plate(
          id: 'region',
          mask: solidPlateMask(),
          left: .2,
          top: .1,
          width: .5,
          height: .8,
        ),
      );
      expect(plates.length, 2);
      expect(plates[0].left, closeTo(.25, .001));
      expect(plates[0].top, closeTo(.26, .001));
      expect(plates[0].width, closeTo(.2, .001));
      expect(plates[1].left, closeTo(.45, .001));
      expect(plates[0].id, isNot(plates[1].id));
      expect(await File(plates[1].path).exists(), true);
      expect(
        directory.listSync().where((f) => f.path.contains('selection-')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'erase and restore change alpha; undo reproduces the previous mask',
    (tester) async {
      late ui.Codec codec;
      late ui.Image mask;
      await tester.runAsync(() async {
        codec = await ui.instantiateImageCodec(base64Decode(solidPlateMask()));
        mask = (await codec.getNextFrame()).image;
      });
      Future<img.Image> pixels(List<MaskStroke> strokes) async {
        final recorder = ui.PictureRecorder();
        paintMask(Canvas(recorder), const Size(100, 100), mask, strokes);
        final picture = recorder.endRecording();
        final result = await picture.toImage(100, 100);
        final data = await result.toByteData(format: ui.ImageByteFormat.png);
        result.dispose();
        picture.dispose();
        return img.decodePng(data!.buffer.asUint8List())!;
      }

      await tester.runAsync(() async {
        final erased = MaskStroke(
          erase: true,
          width: .3,
          points: [const Offset(.5, .5)],
        );
        final restored = MaskStroke(
          erase: false,
          width: .1,
          points: [const Offset(.5, .5)],
        );
        expect((await pixels([erased])).getPixel(50, 50).a, 0);
        final output = await pixels([erased, restored]);
        expect(output.getPixel(50, 50).a, 255);
        expect(output.getPixel(60, 50).a, 0);
        expect((await pixels([])).getPixel(50, 50).a, 255);
      });
      mask.dispose();
      codec.dispose();
    },
  );

  testWidgets('manual selection and edge save work with no model', (
    tester,
  ) async {
    List<Plate>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.push<List<Plate>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PlatePicker(
                      original: original,
                      directory: directory.path,
                      engine: OfflineEngine(),
                    ),
                  ),
                );
              },
              child: const Text('Select'),
            ),
          ),
        ),
      ),
    );
    Future<void> awaitCanvas(String key) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byKey(ValueKey(key)).evaluate().isNotEmpty) return;
      }
      fail('The $key did not finish loading');
    }

    await tester.tap(find.text('Select'));
    await tester.pump(const Duration(milliseconds: 400));
    await awaitCanvas('plate-selection-canvas');
    await tester.tap(find.text('Edit selection by hand'));
    await tester.pump(const Duration(milliseconds: 400));
    await awaitCanvas('plate-edge-canvas');
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('plate-edge-canvas'))),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Undo brush stroke'));
    await tester.pump();
    await tester.tap(find.text('Keep these edges'));
    for (var attempt = 0; result == null && attempt < 100; attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(result, hasLength(1));
    expect(
      await tester.runAsync(() => File(result!.single.path).exists()),
      true,
    );
    expect(result!.single.width, .8);
    expect(result!.single.mask, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each plate has its own drag transform', (tester) async {
    final one = Plate(
      id: 'one',
      mask: solidPlateMask(),
      path: original,
      x: .05,
      y: .1,
      scale: .3,
    );
    final two = Plate(
      id: 'two',
      mask: solidPlateMask(),
      path: original,
      x: .6,
      y: .2,
      scale: .3,
    );
    final memory = Memory(
      id: 'm',
      scope: 'guest',
      createdAt: DateTime(2026),
      original: original,
      useOriginal: false,
      plates: [one, two],
    );
    String? moved;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 360,
            height: 400,
            child: MemoryCanvas(
              memory: memory,
              onPlateTransform: (id, x, y, s, r) {
                moved = id;
                one.x = x;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.bySemanticsLabel('Plate 1'), const Offset(30, 20));
    expect(moved, 'one');
    expect(one.x, greaterThan(.05));
    expect(two.x, .6);
    expect(tester.takeException(), isNull);
  });
}
