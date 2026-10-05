import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/models.dart';

const plateChannel = MethodChannel('morsl/plates');

Map<String, dynamic>? _normalizedMask(Uint8List bytes) {
  final mask = img.decodePng(bytes);
  if (mask == null) return null;
  final normalized = mask.width <= 768 && mask.height <= 768
      ? mask
      : img.copyResize(
          mask,
          width: mask.width >= mask.height ? 768 : null,
          height: mask.height > mask.width ? 768 : null,
        );
  return {
    'bytes': img.encodePng(normalized),
    'aspect': mask.width / mask.height,
  };
}

Future<List<Plate>> detectPlates(
  String original,
  String directory, {
  Plate? region,
}) async {
  final prepared = await compute(plateRegionBytes, <String, dynamic>{
    'original': original,
    'region': region?.toJson(),
    'limit': 1600,
  });
  final input = File(p.join(directory, 'selection-${const Uuid().v4()}.png'));
  try {
    await input.writeAsBytes(prepared, flush: true);
    final rows =
        await plateChannel.invokeListMethod<dynamic>('subjects', {
          'path': input.path,
        }) ??
        [];
    final plates = <Plate>[];
    for (final row in rows) {
      final data = Map<String, dynamic>.from(row);
      final bounds = List<num>.from(data['bounds']);
      final bytes = data['mask'] as Uint8List;
      final normalized = await compute(_normalizedMask, bytes);
      if (bounds.length != 4 ||
          normalized == null ||
          bounds.any((n) => !n.isFinite) ||
          bounds.any((n) => n < 0 || n > 1) ||
          bounds[0] + bounds[2] > 1.001 ||
          bounds[1] + bounds[3] > 1.001 ||
          bounds[2] <= 0 ||
          bounds[3] <= 0) {
        continue;
      }
      final plate = Plate(
        id: const Uuid().v4(),
        mask: base64Encode(normalized['bytes'] as Uint8List),
        left: (region?.left ?? 0) + bounds[0] * (region?.width ?? 1),
        top: (region?.top ?? 0) + bounds[1] * (region?.height ?? 1),
        width: bounds[2].toDouble() * (region?.width ?? 1),
        height: bounds[3].toDouble() * (region?.height ?? 1),
        aspect: normalized['aspect'] as double,
        x: .12 + (plates.length % 2) * .32,
        y: .13 + (plates.length ~/ 2) * .23,
        scale: .48,
      );
      plates.add(await renderPlate(original, directory, plate));
    }
    arrangePlates(plates);
    return plates;
  } finally {
    if (await input.exists()) await input.delete();
  }
}

/// Fit every detected dish between the date and caption on the .91-aspect card.
void arrangePlates(List<Plate> plates) {
  if (plates.isEmpty) return;
  final columns = plates.length == 1 ? 1 : (plates.length > 6 ? 3 : 2);
  final rows = (plates.length / columns).ceil();
  final cellWidth = .84 / columns;
  final cellHeight = .62 / rows;
  for (var i = 0; i < plates.length; i++) {
    final plate = plates[i];
    plate.scale = math.min(
      cellWidth * .91,
      cellHeight * .91 * plate.aspect / .91,
    );
    plate.x = .08 + (i % columns) * cellWidth + (cellWidth - plate.scale) / 2;
    plate.y =
        .12 +
        (i ~/ columns) * cellHeight +
        (cellHeight - plate.scale * .91 / plate.aspect) / 2;
    plate.rotation = 0;
  }
}

Future<Plate> renderPlate(
  String original,
  String directory,
  Plate plate,
) async {
  final result = plate.copy();
  final sourceDigest = await sha256.bind(File(original).openRead()).first;
  // Content-addressed derivatives prevent stale Flutter image-cache entries.
  final digest = sha256.convert(
    utf8.encode(
      '$sourceDigest:${plate.mask}:${plate.left}:${plate.top}:${plate.width}:${plate.height}',
    ),
  );
  result.path = p.join(directory, 'plate-$digest.png');
  if (!await File(result.path).exists()) {
    final bytes = await compute(renderPlateBytes, {
      'original': original,
      'plate': result.toJson(),
    });
    final partial = File('${result.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(result.path);
  }
  return result;
}

img.Image _region(String original, Map<String, dynamic>? region) {
  final decoded = img.decodeImage(File(original).readAsBytesSync());
  if (decoded == null) throw StateError('This photo could not be opened.');
  final source = img.bakeOrientation(decoded);
  if (region == null) return source;
  final plate = Plate.fromJson(region);
  final left = (plate.left * source.width).round().clamp(0, source.width - 1);
  final top = (plate.top * source.height).round().clamp(0, source.height - 1);
  return img.copyCrop(
    source,
    x: left,
    y: top,
    width: (plate.width * source.width).round().clamp(1, source.width - left),
    height: (plate.height * source.height).round().clamp(
      1,
      source.height - top,
    ),
  );
}

Uint8List plateRegionBytes(Map<String, dynamic> args) {
  var image = _region(args['original'], args['region']);
  final limit = args['limit'] as int? ?? 1600;
  if (image.width > limit || image.height > limit) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? limit : null,
      height: image.height > image.width ? limit : null,
    );
  }
  return img.encodePng(image);
}

Uint8List renderPlateBytes(Map<String, dynamic> args) {
  final plate = Plate.fromJson(Map<String, dynamic>.from(args['plate']));
  final cropped = _region(args['original'], plate.toJson());
  final mask = img.decodePng(base64Decode(plate.mask));
  if (mask == null) throw StateError('The plate edges could not be restored.');
  var rgb = cropped;
  if (rgb.width > 1600 || rgb.height > 1600) {
    rgb = img.copyResize(
      rgb,
      width: rgb.width >= rgb.height ? 1600 : null,
      height: rgb.height > rgb.width ? 1600 : null,
    );
  }
  final alpha = img.copyResize(
    mask,
    width: rgb.width,
    height: rgb.height,
    interpolation: img.Interpolation.linear,
  );
  final output = img.Image(
    width: rgb.width,
    height: rgb.height,
    numChannels: 4,
  );
  for (final pixel in output) {
    final source = rgb.getPixel(pixel.x, pixel.y);
    pixel.setRgba(
      source.r,
      source.g,
      source.b,
      alpha.getPixel(pixel.x, pixel.y).a,
    );
  }
  return img.encodePng(output);
}

String solidPlateMask() {
  final mask = img.Image(width: 1, height: 1, numChannels: 4);
  mask.setPixelRgba(0, 0, 255, 255, 255, 255);
  return base64Encode(img.encodePng(mask));
}
