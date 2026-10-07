import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Only replaceable cloud images belong here. Drafts never enter this cache.
class ImageDiskCache {
  ImageDiskCache({this.maxBytes = 100 * 1024 * 1024, this.root});
  final int maxBytes;
  final Directory? root;
  final Map<String, Future<File>> _loading = {};
  final Map<String, int> _pins = {};
  Future<void> _maintenance = Future.value();
  Directory? _resolved;

  Future<Directory> directory() async {
    _resolved ??=
        root ??
        Directory(p.join((await getTemporaryDirectory()).path, 'morsl-images'));
    return _resolved!.create(recursive: true);
  }

  Future<File> acquire(
    String identity,
    Future<Uint8List> Function() load,
  ) async {
    final name = sha256.convert(utf8.encode(identity)).toString();
    _pins[name] = (_pins[name] ?? 0) + 1;
    try {
      final file = await (_loading[name] ??= _fetch(name, load));
      await file.setLastModified(DateTime.now());
      return file;
    } catch (_) {
      release(identity);
      rethrow;
    } finally {
      _loading.remove(name);
    }
  }

  Future<File> _fetch(String name, Future<Uint8List> Function() load) async {
    final file = File(p.join((await directory()).path, name));
    if (!await file.exists()) {
      final bytes = await load();
      final partial = File('${file.path}.partial');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    }
    return file;
  }

  void release(String identity) {
    final name = sha256.convert(utf8.encode(identity)).toString();
    final count = (_pins[name] ?? 1) - 1;
    if (count == 0) {
      _pins.remove(name);
    } else {
      _pins[name] = count;
    }
  }

  Future<void> remove(String identity) async {
    if (_resolved == null && root == null) return;
    final name = sha256.convert(utf8.encode(identity)).toString();
    try {
      await _loading[name];
    } catch (_) {
      /* Discard incomplete downloads too. */
    }
    final directoryPath = (await directory()).path;
    for (final suffix in ['', '.partial']) {
      final file = File(p.join(directoryPath, '$name$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> trim() {
    if (_resolved == null && root == null) return Future.value();
    final task = _maintenance.catchError((Object _) {}).then((_) async {
      final files = <(File, FileStat)>[];
      await for (final entity in (await directory()).list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        files.add((entity, stat));
      }
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var size = files.fold<int>(0, (sum, entry) => sum + entry.$2.size);
      for (final entry in files) {
        final name = p.basename(entry.$1.path);
        if (_pins.containsKey(name) ||
            _loading.containsKey(name.replaceAll('.partial', ''))) {
          continue;
        }
        if (size <= maxBytes && !name.endsWith('.partial')) continue;
        try {
          await entry.$1.delete();
          size -= entry.$2.size;
        } on FileSystemException {
          /* Next pass retries. */
        }
      }
    });
    _maintenance = task;
    return task;
  }
}
