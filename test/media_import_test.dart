import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:morsl/services/media.dart';
import 'package:path/path.dart' as p;

class ImportMedia extends MediaStore {
  ImportMedia(this.root);
  final Directory root;
  @override
  Future<Directory> directory(String scope, String id) =>
      Directory(p.join(root.path, scope, id)).create(recursive: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ImportMedia media;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('morsl-import-');
    media = ImportMedia(root);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'motion photo import saves only a still JPEG and leaves gallery bytes untouched',
    () async {
      final image = img.Image(width: 32, height: 24);
      image.exif.exifIfd[0x927c] = img.IfdValueAscii('MotionPhoto maker data');
      final motion = [
        ...img.encodeJpg(image),
        ...utf8.encode('ftypmp42-motion-video'),
        ...List<int>.filled(50000, 123),
      ];
      final source = await File(
        p.join(root.path, 'live.jpg'),
      ).writeAsBytes(motion);
      final saved = await media.preserve(XFile(source.path), 'account', 'meal');
      final bytes = await File(saved).readAsBytes();
      expect(p.basename(saved), 'original.jpg');
      expect(img.decodeJpg(bytes), isNotNull);
      expect(bytes.sublist(bytes.length - 2), [0xff, 0xd9]);
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('motion-video')),
      );
      expect(img.decodeJpg(bytes)!.exif.exifIfd[0x927c], isNull);
      expect(bytes.length, lessThan(motion.length));
      expect(await source.readAsBytes(), motion);
      expect(
        (await media.directory('account', 'meal')).listSync(),
        hasLength(1),
      );
    },
  );

  for (final size in [(2050, 1025), (1025, 2050)]) {
    test(
      'large ${size.$1} by ${size.$2} photo is capped without changing its aspect',
      () async {
        final source = await File(p.join(root.path, 'large.png')).writeAsBytes(
          img.encodePng(img.Image(width: size.$1, height: size.$2)),
        );
        final saved = await media.preserve(
          XFile(source.path),
          'account',
          'meal',
        );
        final result = img.decodeJpg(await File(saved).readAsBytes())!;
        expect(result.width, size.$1 > size.$2 ? 2048 : 1024);
        expect(result.height, size.$2 > size.$1 ? 2048 : 1024);
      },
    );
  }

  test(
    'small photos keep their size and EXIF orientation, date and GPS are handled correctly',
    () async {
      final image = img.Image(width: 32, height: 16);
      image.exif.imageIfd.orientation = 6;
      image.exif.exifIfd[0x9003] = img.IfdValueAscii('2026:09:28 18:30:00');
      image.exif.gpsIfd[1] = img.IfdValueAscii('N');
      image.exif.gpsIfd[2] = img.IfdValueRational(14, 1)
        ..value.addAll(img.IfdValueRational(30, 1).value)
        ..value.addAll(img.IfdValueRational(0, 1).value);
      image.exif.gpsIfd[3] = img.IfdValueAscii('E');
      image.exif.gpsIfd[4] = img.IfdValueRational(121, 1)
        ..value.addAll(img.IfdValueRational(0, 1).value)
        ..value.addAll(img.IfdValueRational(0, 1).value);
      final source = await File(
        p.join(root.path, 'rotated.jpg'),
      ).writeAsBytes(img.encodeJpg(image));
      final saved = await media.preserve(XFile(source.path), 'account', 'meal');
      final result = img.decodeJpg(await File(saved).readAsBytes())!;
      expect((result.width, result.height), (16, 32));
      expect(result.exif.imageIfd.orientation, isNull);
      final metadata = await media.metadata(saved);
      expect(metadata['createdAt'], '2026-09-28T18:30:00.000');
      expect(metadata['latitude'], 14.5);
      expect(metadata['longitude'], 121);
    },
  );

  test('animated images keep a single still frame', () async {
    final image = img.Image(width: 16, height: 16);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    final second = img.Image(width: 16, height: 16);
    img.fill(second, color: img.ColorRgb8(0, 0, 255));
    image.addFrame(second);
    final source = await File(
      p.join(root.path, 'animated.gif'),
    ).writeAsBytes(img.encodeGif(image));
    final saved = await media.preserve(XFile(source.path), 'account', 'meal');
    final result = img.decodeJpg(await File(saved).readAsBytes())!;
    expect(result.numFrames, 1);
    expect(result.getPixel(8, 8).r, greaterThan(200));
    expect(result.getPixel(8, 8).b, lessThan(30));
  });

  test(
    'unsupported images are rejected rather than retaining potentially embedded video',
    () async {
      final source = await File(
        p.join(root.path, 'invalid.heic'),
      ).writeAsBytes([1, 2, 3]);
      await expectLater(
        media.preserve(XFile(source.path), 'account', 'meal'),
        throwsStateError,
      );
      expect((await media.directory('account', 'meal')).listSync(), isEmpty);
      expect(await source.readAsBytes(), [1, 2, 3]);
    },
  );
}
