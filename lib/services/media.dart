import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'image_cache.dart';

export 'cloud_segmentation.dart';
export 'segmentation.dart';

class MediaStore {
  MediaStore({ImageDiskCache? cache}) : cache = cache ?? ImageDiskCache();
  final ImageDiskCache cache;
  static MediaStore? imageStore;
  String Function()? accountIdentity;
  Future<Uint8List> Function(String key)? download;
  final Map<String, int> _localPins = {};
  final Map<String, int> _work = {};
  final Set<String> _revoked = {};
  static bool isRemote(String path) => path.startsWith('morsl-cloud:');
  static String remote(String key) => 'morsl-cloud:$key';
  static String key(String ref) => ref.substring('morsl-cloud:'.length);
  String _identity(String ref) => '${accountIdentity?.call() ?? 'guest'}:$ref';
  void authorize(String ref) => _revoked.remove(_identity(ref));
  Future<void> revoke(String ref) async {
    if (!isRemote(ref)) return;
    final identity = _identity(ref);
    _revoked.add(identity);
    await cache.remove(identity);
  }

  Future<Uint8List> _load(String ref) async {
    if (download == null) throw StateError('Connect to load this image.');
    return download!(key(ref));
  }

  Future<MediaLease> acquire(String ref) async {
    if (!isRemote(ref)) {
      _localPins[ref] = (_localPins[ref] ?? 0) + 1;
      return MediaLease(File(ref), () async {
        final count = (_localPins[ref] ?? 1) - 1;
        if (count <= 0) {
          _localPins.remove(ref);
        } else {
          _localPins[ref] = count;
        }
      });
    }
    final identity = _identity(ref);
    if (_revoked.contains(identity)) {
      throw StateError('This image is no longer available.');
    }
    final file = await cache.acquire(identity, () => _load(ref));
    if (identity != _identity(ref) || _revoked.contains(identity)) {
      cache.release(identity);
      throw StateError('Account changed.');
    }
    return MediaLease(file, () async {
      cache.release(identity);
      await cache.trim();
    });
  }

  Future<void> beginWork(String scope, String id) async {
    final dir = (await directory(scope, id)).path;
    _work[dir] = (_work[dir] ?? 0) + 1;
  }

  Future<void> endWork(String scope, String id) async {
    final dir = (await directory(scope, id)).path;
    final count = (_work[dir] ?? 1) - 1;
    if (count <= 0) {
      _work.remove(dir);
    } else {
      _work[dir] = count;
    }
  }

  Future<Uint8List> read(String ref) async {
    final identity = _identity(ref);
    final lease = await acquire(ref);
    try {
      final bytes = await lease.file.readAsBytes();
      if (isRemote(ref) &&
          (identity != _identity(ref) || _revoked.contains(identity))) {
        throw StateError('This image is no longer available.');
      }
      return bytes;
    } finally {
      await lease.close();
    }
  }

  /// Restored backups are durable app files, independent of the image cache.
  Future<String> restoreBackup(
    String ref,
    String scope,
    String id, {
    String? existing,
  }) async {
    if (!isRemote(ref)) return ref;
    if (existing != null &&
        existing.isNotEmpty &&
        !isRemote(existing) &&
        await File(existing).exists()) {
      final expected = RegExp(
        r'-([0-9a-f]{64})\.',
      ).firstMatch(p.basename(key(ref)))?.group(1);
      if (expected == null ||
          sha256.convert(await File(existing).readAsBytes()).toString() ==
              expected) {
        return existing;
      }
    }
    final dir = await directory(scope, id);
    final digest = sha256.convert(utf8.encode(ref));
    final file = File(
      p.join(dir.path, 'backup-$digest${p.extension(key(ref))}'),
    );
    if (await file.exists()) return file.path;
    final bytes = await read(ref);
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(file.path);
    return file.path;
  }

  /// Call only after committed cloud restore, with no pending edits/jobs.
  Future<void> removeBackedUpFiles(String scope, String id) async {
    final dir = await directory(scope, id);
    if (_work.containsKey(dir.path) ||
        _localPins.keys.any((path) => p.isWithin(dir.path, path))) {
      return;
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && !_localPins.containsKey(entity.path)) {
        try {
          await entity.delete();
        } on FileSystemException {
          /* Open image handles are retried on the next sync. */
        }
      }
    }
  }

  Future<Directory> directory(String scope, String id) async {
    final root = await getApplicationDocumentsDirectory();
    return Directory(
      p.join(root.path, 'morsl', scope, id),
    ).create(recursive: true);
  }

  Future<String> preserve(XFile photo, String scope, String id) async {
    final dir = await directory(scope, id);
    return compute(_preserveStill, {
      'source': photo.path,
      'target': p.join(dir.path, 'original.jpg'),
    });
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

/// Re-encoding pixels produces a still JPEG with no appended video or animation.
/// Do not fall back to copying an unsupported source: it could retain motion data.
String _preserveStill(Map<String, String> paths) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(
      File(paths['source']!).readAsBytesSync(),
      frame: 0,
    );
  } catch (_) {
    throw StateError(
      'This photo could not be converted. Export it as a JPEG or PNG and try again.',
    );
  }
  if (decoded == null) {
    throw StateError(
      'This photo could not be converted. Export it as a JPEG or PNG and try again.',
    );
  }
  // Retain only the metadata used for meal dates and optional venue suggestions.
  // This excludes motion-photo XMP, maker notes, embedded thumbnails and videos.
  final metadata = img.ExifData();
  final date = decoded.exif.exifIfd[0x9003];
  if (date != null) metadata.exifIfd[0x9003] = date.clone();
  for (final tag in [1, 2, 3, 4]) {
    final value = decoded.exif.gpsIfd[tag];
    if (value != null) metadata.gpsIfd[tag] = value.clone();
  }
  var still = img.bakeOrientation(decoded);
  if (still.width > 2048 || still.height > 2048) {
    still = img.copyResize(
      still,
      width: still.width >= still.height ? 2048 : null,
      height: still.height > still.width ? 2048 : null,
      interpolation: img.Interpolation.average,
    );
  }
  still.exif = metadata;
  still.iccProfile = null;
  still.textData = null;
  final target = File(paths['target']!);
  final partial = File('${target.path}.partial');
  try {
    partial.writeAsBytesSync(img.encodeJpg(still, quality: 85), flush: true);
    partial.renameSync(target.path);
  } finally {
    if (partial.existsSync()) partial.deleteSync();
  }
  return target.path;
}

class MediaLease {
  MediaLease(this.file, this._release);
  final File file;
  final Future<void> Function() _release;
  bool _closed = false;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _release();
  }
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
