import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/services/image_cache.dart';
import 'package:morsl/services/media.dart';

class TemporaryMedia extends MediaStore {
  TemporaryMedia(this.root, ImageDiskCache cache) : super(cache: cache);
  final Directory root;
  @override
  Future<Directory> directory(String scope, String id) =>
      Directory('${root.path}/$scope/$id').create(recursive: true);
}

void main() {
  late Directory root;
  late ImageDiskCache cache;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('morsl-cache-');
    cache = ImageDiskCache(root: Directory('${root.path}/cache'), maxBytes: 10);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'evicts least recently used bytes and preserves a file in active use',
    () async {
      final older = await cache.acquire('old', () async => Uint8List(8));
      cache.release('old');
      await older.setLastModified(DateTime(2020));
      final active = await cache.acquire('active', () async => Uint8List(8));
      await cache.trim();
      expect(await older.exists(), false);
      expect(await active.exists(), true);
      cache.release('active');
      await cache.trim();
      final files = await (await cache.directory())
          .list()
          .where((f) => f is File)
          .toList();
      var bytes = 0;
      for (final file in files.cast<File>()) {
        bytes += await file.length();
      }
      expect(bytes, lessThanOrEqualTo(10));
    },
  );

  test(
    'concurrent requests share one download, cache hits work offline, and evictions refetch',
    () async {
      var downloads = 0;
      final gate = Completer<Uint8List>();
      Future<Uint8List> load() {
        downloads++;
        return gate.future;
      }

      final first = cache.acquire('same', load);
      final second = cache.acquire('same', load);
      gate.complete(Uint8List(8));
      final files = await Future.wait([first, second]);
      expect(downloads, 1);
      expect(files[0].path, files[1].path);
      cache.release('same');
      cache.release('same');
      await cache.acquire('same', () async => throw StateError('offline'));
      cache.release('same');
      await files[0].setLastModified(DateTime(2020));
      await cache.acquire('other', () async => Uint8List(8));
      cache.release('other');
      await cache.trim();
      expect(await files[0].exists(), false);
      await cache.acquire('same', () async {
        downloads++;
        return Uint8List(8);
      });
      cache.release('same');
      expect(downloads, 2);
    },
  );

  test(
    'account change releases the original cache lease and blocks stale download',
    () async {
      var account = 'a';
      final media = TemporaryMedia(root, cache)
        ..accountIdentity = () => account;
      media.download = (_) async => Uint8List(20);
      final lease = await media.acquire(MediaStore.remote('image'));
      account = 'b';
      await lease.close();
      expect(await lease.file.exists(), false);
      final gate = Completer<Uint8List>();
      media.download = (_) => gate.future;
      final loading = media.read(MediaStore.remote('pending'));
      final assertion = expectLater(loading, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      account = 'c';
      gate.complete(Uint8List(1));
      await assertion;
    },
  );

  test(
    'cache maintenance leaves drafts alone and committed cleanup protects active edits',
    () async {
      final media = TemporaryMedia(root, cache);
      final directory = await media.directory('user', 'meal');
      final original = await File(
        '${directory.path}/original.jpg',
      ).writeAsBytes(Uint8List(20));
      await cache.trim();
      expect(await original.exists(), true);
      await media.beginWork('user', 'meal');
      await media.removeBackedUpFiles('user', 'meal');
      expect(await original.exists(), true);
      await media.endWork('user', 'meal');
      final lease = await media.acquire(original.path);
      await media.removeBackedUpFiles('user', 'meal');
      expect(await original.exists(), true);
      await lease.close();
      await media.removeBackedUpFiles('user', 'meal');
      expect(await original.exists(), false);
    },
  );

  test('failed downloads do not commit files and can be retried', () async {
    await expectLater(
      cache.acquire('failed', () async => throw StateError('offline')),
      throwsStateError,
    );
    final file = await cache.acquire(
      'failed',
      () async => Uint8List.fromList([1, 2]),
    );
    expect(await file.readAsBytes(), [1, 2]);
    cache.release('failed');
  });
  test(
    'restored backup stays local after cache eviction and offline restore',
    () async {
      final media = TemporaryMedia(root, cache);
      var downloads = 0;
      media.download = (_) async {
        downloads++;
        return Uint8List.fromList([1, 2, 3]);
      };
      final ref = MediaStore.remote('meal/original.jpg');
      final saved = await media.restoreBackup(ref, 'user', 'meal');
      expect(MediaStore.isRemote(saved), false);
      expect(await File(saved).readAsBytes(), [1, 2, 3]);
      await cache.remove('guest:$ref');
      media.download = (_) async => throw StateError('offline');
      expect(await media.restoreBackup(ref, 'user', 'meal'), saved);
      expect(await File(saved).readAsBytes(), [1, 2, 3]);
      expect(downloads, 1);
    },
  );
  test(
    'revocation removes cached bytes and blocks reads until an authorized restore',
    () async {
      final media = TemporaryMedia(root, cache)..accountIdentity = () => 'user';
      var downloads = 0;
      media.download = (_) async {
        downloads++;
        return Uint8List.fromList([1, 2]);
      };
      final ref = MediaStore.remote('meal/image');
      expect(await media.read(ref), [1, 2]);
      await media.revoke(ref);
      await expectLater(media.read(ref), throwsStateError);
      expect(downloads, 1);
      media.authorize(ref);
      expect(await media.read(ref), [1, 2]);
      expect(downloads, 2);
    },
  );
}
