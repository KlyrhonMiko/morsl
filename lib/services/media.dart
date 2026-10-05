import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../data/models.dart';
import 'plates.dart';

abstract interface class SegmentationEngine {
  Future<bool> available();
  Future<bool> prepare();
  Future<String> process(String original, String output);
  String get runtime;
}

abstract interface class MultiSubjectSegmentationEngine {
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  });
}

class NativeSegmentation
    implements SegmentationEngine, MultiSubjectSegmentationEngine {
  @override
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  }) async {
    if (!await available()) {
      throw StateError(
        'Download the dish models once in Settings, then retry offline.',
      );
    }
    return detectPlates(original, directory, region: region);
  }

  String device = '';
  Future<void> inspectDevice() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        device =
            '${android.manufacturer} ${android.model}; API ${android.version.sdkInt}; ';
      }
    } catch (_) {
      /* OS details remain available on unsupported platforms. */
    }
  }

  bool get supported => Platform.isAndroid;
  @override
  String get runtime =>
      '$device${Platform.operatingSystem} ${Platform.operatingSystemVersion}; ${Platform.isAndroid ? 'Grounding DINO Tiny + MobileSAM; dish pipeline v1' : 'automatic cutouts unavailable'}';
  @override
  Future<bool> available() async =>
      supported &&
      (await plateChannel.invokeMethod<bool>('available') ?? false);
  @override
  Future<bool> prepare() async =>
      supported && (await plateChannel.invokeMethod<bool>('prepare') ?? false);
  @override
  Future<String> process(String original, String output) async {
    if (!supported) {
      throw StateError(
        'Automatic cutouts are available on Android. You can select a plate and edit its edges by hand.',
      );
    }
    if (!await available()) {
      throw StateError(
        'Model not ready. Prepare it online, then retry. Your original is safe.',
      );
    }
    final plates = await subjects(original, p.dirname(output));
    if (plates.isEmpty) throw StateError('No dishes found in this photo.');
    await File(plates.first.path).copy(output);
    return output;
  }
}

class MediaStore {
  Future<Directory> directory(String scope, String id) async {
    final root = await getApplicationDocumentsDirectory();
    return Directory(
      p.join(root.path, 'morsl', scope, id),
    ).create(recursive: true);
  }

  Future<String> preserve(XFile photo, String scope, String id) async {
    final dir = await directory(scope, id);
    final extension = p.extension(photo.path).toLowerCase();
    final target = p.join(
      dir.path,
      'original${extension.isEmpty ? '.jpg' : extension}',
    );
    await File(photo.path).copy(target);
    return target;
  }

  Future<String> sample(
    String asset,
    String id, {
    String filename = 'original.jpg',
  }) async {
    final dir = await directory('guest', id);
    final output = p.join(dir.path, filename);
    final bytes = await rootBundle.load(asset);
    await File(output).writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return output;
  }

  Future<String?> thumbnail(String original) => compute(_thumbnail, original);
  Future<Map<String, dynamic>> metadata(String original) =>
      compute(_metadata, original);
}

Map<String, dynamic> _metadata(String original) {
  try {
    final image = img.decodeImage(File(original).readAsBytesSync());
    if (image == null) {
      return {};
    }
    final result = <String, dynamic>{};
    final text = image.exif.exifIfd[0x9003]?.toString();
    if (text != null && text.length >= 19) {
      final normalized =
          '${text.substring(0, 10).replaceAll(':', '-')}T${text.substring(11, 19)}';
      final date = DateTime.tryParse(normalized);
      if (date != null) {
        result['createdAt'] = date.toIso8601String();
      }
    }
    final gps = image.exif.gpsIfd;
    double? coordinate(int tag, int ref) {
      final value = gps[tag];
      if (value == null || value.length < 3) {
        return null;
      }
      final number =
          value.toDouble(0) + value.toDouble(1) / 60 + value.toDouble(2) / 3600;
      final direction = gps[ref]?.toString();
      return (direction == 'S' || direction == 'W') ? -number : number;
    }

    final lat = coordinate(2, 1), lng = coordinate(4, 3);
    if (lat != null &&
        lng != null &&
        lat.isFinite &&
        lng.isFinite &&
        lat.abs() <= 90 &&
        lng.abs() <= 180) {
      result['latitude'] = lat;
      result['longitude'] = lng;
    }
    return result;
  } catch (_) {
    return {};
  }
}

String? _thumbnail(String original) {
  final image = img.decodeImage(File(original).readAsBytesSync());
  if (image == null) {
    return null;
  }
  final output = p.join(p.dirname(original), 'thumbnail.jpg');
  File(output).writeAsBytesSync(
    img.encodeJpg(
      img.copyResize(img.bakeOrientation(image), width: 600),
      quality: 82,
    ),
    flush: true,
  );
  return output;
}
