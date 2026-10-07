import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/plates.dart';
import 'package:morsl/services/reminders.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeEngine implements SegmentationEngine {
  bool fails = true;
  Completer<void>? wait;
  final started = Completer<void>();
  Future<void> Function()? onAvailable;
  @override
  String get runtime => 'test device / test model';
  @override
  Future<bool> available() async {
    await onAvailable?.call();
    return true;
  }

  @override
  Future<String> process(String original, String output) async {
    if (!started.isCompleted) started.complete();
    if (wait != null) await wait!.future;
    if (fails) throw StateError('Segmentation unavailable');
    await File(original).copy(output);
    return output;
  }
}

class FakePlateEngine extends FakeEngine
    implements MultiSubjectSegmentationEngine {
  @override
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  }) async {
    if (!started.isCompleted) started.complete();
    if (wait != null) await wait!.future;
    return [Plate(id: 'detected', mask: solidPlateMask(), path: original)];
  }
}

class FakeRemoteEngine extends FakeEngine implements RemoteSegmentationEngine {
  @override
  bool authenticated = true;
  @override
  bool uploadsAllowed = false;
}

class TestMedia extends MediaStore {
  TestMedia(this.root);
  final Directory root;
  @override
  Future<Directory> directory(String scope, String id) async =>
      Directory('${root.path}/$scope/$id').create(recursive: true);
}

class FakeCloud extends CloudService {
  FakeCloud(super.client, super.media);
  String current = 'account-a';
  @override
  bool get signedInWithGoogle => true;
  @override
  bool get configured => true;
  bool failPush = true;
  bool failPull = false;
  final Map<String, Memory> remote = {};
  @override
  String? get account => current;
  @override
  Future<Map<String, dynamic>> push(Memory m) async {
    if (failPush) throw StateError('Upload interrupted');
    remote[m.id] = m.copy()
      ..mealRevision = 1
      ..memoryRevision = 1;
    return {'mealRevision': 1, 'memoryRevision': 1};
  }

  @override
  Future<List<Memory>> pull(String account) async {
    if (failPull) {
      throw StateError('A different asset cannot be downloaded');
    }
    return remote.values.map((m) => m.copy()).toList();
  }

  @override
  Future<Set<String>> authorizedIds() async => remote.keys.toSet();
}

class ReferenceCloud extends FakeCloud {
  ReferenceCloud(super.client, super.media);
  Future<void> Function()? duringPull;
  @override
  Future<List<Memory>> pull(String account) async {
    await duringPull?.call();
    return (await super.pull(account)).map((memory) {
      memory.original = MediaStore.remote('${memory.id}/original.jpg');
      memory.plates = memory.plates
          .map(
            (plate) =>
                plate.copy()
                  ..path = MediaStore.remote('${memory.id}/plate.png'),
          )
          .toList();
      return memory;
    }).toList();
  }
}

// Existing persistence fixtures use "guest" as their isolated test scope.
// They now exercise a signed-in controller rather than authorizing real guests.
class TestGoogleCloud extends CloudService {
  TestGoogleCloud(super.client, super.media);
  String? current = 'guest';
  @override
  String? get account => current;
  @override
  bool get signedInWithGoogle => current != null;
}

class DelayedMemoryRepository extends MemoryRepository {
  DelayedMemoryRepository(super.db);
  Completer<void>? delayNextList;
  final delayedListStarted = Completer<void>();

  @override
  Future<List<Memory>> list(String scope) async {
    final delay = delayNextList;
    delayNextList = null;
    final items = await super.list(scope);
    if (delay != null) {
      delayedListStarted.complete();
      await delay.future;
    }
    return items;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late MorslDatabase db;
  late MemoryRepository repo;
  late TestMedia media;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('morsl-test-');
    db = MorslDatabase(NativeDatabase(File('${temp.path}/test.sqlite')));
    repo = MemoryRepository(db);
    media = TestMedia(temp);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Memory meal(String scope) => Memory(
    id: 'meal-1',
    scope: scope,
    creator: scope == 'guest' ? null : scope,
    createdAt: DateTime(2026, 10, 5),
    original: '${temp.path}/original.jpg',
  );

  test(
    'guests cannot capture, edit, extract, bookmark, export, or change settings',
    () async {
      final engine = FakeEngine();
      final app = MorslController(
        repository: repo,
        media: media,
        engine: engine,
        cloud: CloudService(null, media),
        reminders: DraftReminders(),
      );
      final memory = meal('guest');
      await repo.save(memory, enqueue: false);
      expect(app.canMutate, false);
      await expectLater(app.capture(ImageSource.camera), throwsStateError);
      await expectLater(
        app.importPhoto(XFile('missing.png')),
        throwsStateError,
      );
      await expectLater(app.save(memory), throwsStateError);
      await expectLater(app.retry(memory), throwsStateError);
      await expectLater(app.toggleBookmark(memory), throwsStateError);
      await expectLater(app.rate(memory, 'good', null), throwsStateError);
      await expectLater(app.exportEvaluations(), throwsStateError);
      await expectLater(app.setReminder(true, 20, 0), throwsStateError);
      await expectLater(app.setCloudCutoutsAllowed(true), throwsStateError);
      await expectLater(app.clearExamples(), throwsStateError);
      await expectLater(app.sync(manual: true), throwsStateError);
      await app.processQueue();
      expect(engine.started.isCompleted, false);
      expect((await repo.list('guest')).single.bookmarked, memory.bookmarked);
      app.dispose();
    },
  );
  MorslController controller(SegmentationEngine engine, CloudService cloud) =>
      MorslController(
        repository: repo,
        media: media,
        engine: engine,
        cloud: cloud,
        reminders: DraftReminders(),
      );

  test(
    'multiple photos create one durable meal and cutouts use their own source',
    () async {
      final first = File('${temp.path}/first.png');
      final second = File('${temp.path}/second.png');
      await first.writeAsBytes(img.encodePng(img.Image(width: 4, height: 4)));
      await second.writeAsBytes(img.encodePng(img.Image(width: 8, height: 8)));
      final app = controller(FakePlateEngine(), TestGoogleCloud(null, media));
      app.active = false;
      final memory = await app.importPhotos([
        XFile(first.path),
        XFile(second.path),
      ]);
      expect(await repo.list('guest'), hasLength(1));
      final saved = (await repo.list('guest')).single;
      expect(saved.originals, hasLength(2));
      expect(saved.original, isNot(saved.photos.single.original));
      expect(img.decodeJpg(await File(saved.original).readAsBytes())!.width, 4);
      expect(
        img
            .decodeJpg(await File(saved.photos.single.original).readAsBytes())!
            .width,
        8,
      );
      app.active = true;
      await app.processQueue();
      final processed = (await repo.list('guest')).single;
      expect(processed.id, memory.id);
      expect(processed.job, JobStatus.ready);
      expect(processed.plates, hasLength(2));
      expect(processed.plates.map((p) => p.id).toSet(), hasLength(2));
      for (final plate in processed.plates) {
        expect(plate.path, processed.sourceFor(plate));
      }
      expect(
        processed.copy().sourceFor(processed.plates.last),
        processed.photos.single.original,
      );
      app.dispose();
    },
  );

  test(
    'new photo processing preserves existing edited cutouts and retries failures',
    () async {
      final original = File('${temp.path}/original.png');
      await original.writeAsBytes(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      final memory = meal('guest')
        ..original = original.path
        ..originalProcessed = true
        ..platesEdited = true
        ..plates = [
          Plate(id: 'hand-edited', mask: solidPlateMask(), path: original.path),
        ]
        ..photos = [
          MealPhoto(id: 'new-photo', original: '${temp.path}/missing.png'),
        ];
      await repo.save(memory);
      final app = controller(
        FakeEngine()..fails = false,
        TestGoogleCloud(null, media),
      );
      await app.processQueue();
      var saved = (await repo.list('guest')).single;
      expect(saved.job, JobStatus.failed);
      expect(saved.plates.single.id, 'hand-edited');
      expect(saved.photos.single.job, JobStatus.failed);
      await File(
        saved.photos.single.original,
      ).writeAsBytes(await original.readAsBytes());
      await app.retry(saved);
      saved = (await repo.list('guest')).single;
      expect(saved.job, JobStatus.ready);
      expect(saved.plates.map((p) => p.id), contains('hand-edited'));
      expect(saved.plates, hasLength(2));
      expect(saved.photos.single.job, JobStatus.ready);
      app.dispose();
    },
  );

  test(
    'startup loads saved meals when the account is restored during setup',
    () async {
      final saved = meal('account-a')
        ..draft = false
        ..job = JobStatus.ready
        ..cutout = 'saved-cutout.png';
      await repo.save(saved, enqueue: false);
      final draft = Memory.fromJson({
        ...saved.toJson(),
        'id': 'draft',
        'draft': true,
      });
      await repo.save(draft, enqueue: false);
      await repo.setPreference('cloudCutouts:v1:account-a', 'false');
      final cloud = TestGoogleCloud(null, media)..current = null;
      final engine = FakeRemoteEngine()
        ..onAvailable = () async => cloud.current = 'account-a';
      final app = controller(engine, cloud);
      await app.initialize(seedExamples: false);
      expect(app.scope, 'account-a');
      expect(app.memories, hasLength(2));
      expect(LibraryPlate.fromMemories(app.memories), hasLength(1));
      expect(app.memories.where((m) => m.draft), hasLength(1));
      expect(app.cloudCutoutsAllowed, false);
      app.dispose();
    },
  );

  test('a delayed reload cannot replace newly loaded saved meals', () async {
    final repository = DelayedMemoryRepository(db);
    final app = MorslController(
      repository: repository,
      media: media,
      engine: FakeEngine(),
      cloud: TestGoogleCloud(null, media),
      reminders: DraftReminders(),
    );
    final delay = Completer<void>();
    repository.delayNextList = delay;
    final staleReload = app.reload();
    await repository.delayedListStarted.future;
    final saved = meal('guest')
      ..draft = false
      ..cutout = 'saved-cutout.png';
    await repository.save(saved, enqueue: false);
    await app.reload();
    expect(LibraryPlate.fromMemories(app.memories), hasLength(1));
    delay.complete();
    await staleReload;
    expect(LibraryPlate.fromMemories(app.memories), hasLength(1));
    app.dispose();
  });

  test('cloud cutouts default on and preserve an account opt-out', () async {
    final engine = FakeRemoteEngine();
    var app = controller(engine, TestGoogleCloud(null, media));
    await app.initialize(seedExamples: false);
    expect(app.cloudCutoutsAllowed, true);
    await app.setCloudCutoutsAllowed(false);
    app.dispose();

    app = controller(FakeRemoteEngine(), TestGoogleCloud(null, media));
    await app.initialize(seedExamples: false);
    expect(app.cloudCutoutsAllowed, false);
    await app.setCloudCutoutsAllowed(true);
    app.dispose();

    app = controller(FakeRemoteEngine(), TestGoogleCloud(null, media));
    await app.initialize(seedExamples: false);
    expect(app.cloudCutoutsAllowed, true);
    app.dispose();
  });

  test(
    'cloud cutouts remain disabled without an authenticated session',
    () async {
      final app = controller(
        FakeRemoteEngine()..authenticated = false,
        CloudService(null, media),
      );
      await app.initialize(seedExamples: false);
      expect(app.cloudCutoutsAllowed, false);
      app.dispose();
    },
  );

  test(
    'OAuth callback errors are handled and do not expose authorization codes',
    () async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final app = controller(FakeEngine(), CloudService(client, media));
      await app.initialize(seedExamples: false);
      // Exercise the same error stream used by Supabase's deep-link handler.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(
        const AuthException(
          'Unable to exchange external code: private-oauth-code',
          code: 'server_error',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.authError, contains('Google sign-in could not be completed'));
      expect(app.authError, isNot(contains('private-oauth-code')));
      expect(app.canMutate, false);
      app.dispose();
      await client.dispose();
    },
  );

  test('switching accounts discards an in-flight extraction result', () async {
    final cloud = FakeCloud(null, media);
    final memory = meal('account-a');
    await repo.save(memory, enqueue: false);
    final engine = FakePlateEngine()..wait = Completer<void>();
    final app = controller(engine, cloud);
    final processing = app.processQueue();
    await engine.started.future;
    cloud.current = 'account-b';
    engine.wait!.complete();
    await processing;
    final saved = (await repo.list('account-a')).single;
    expect(saved.job, JobStatus.queued);
    expect(saved.plates, isEmpty);
    expect(saved.cutout, isNull);
    app.dispose();
  });

  test('durable draft and exact composition survive database reopen', () async {
    final source = File('${temp.path}/camera-cache.jpg');
    await source.writeAsBytes(
      img.encodeJpg(img.Image(width: 4, height: 4)),
      flush: true,
    );
    final durable = await media.preserve(XFile(source.path), 'guest', 'meal-1');
    final durableBytes = await File(durable).readAsBytes();
    await source.delete();
    final m = meal('guest')
      ..original = durable
      ..caption = 'Our lunch'
      ..x = .17
      ..y = -.08
      ..scale = .79
      ..rotation = .43
      ..background = 'sage'
      ..layout = 'postcard'
      ..draft = false;
    await repo.save(m);
    await db.close();
    db = MorslDatabase(NativeDatabase(File('${temp.path}/test.sqlite')));
    repo = MemoryRepository(db);
    final restored = (await repo.list('guest')).single;
    expect(restored.original, m.original);
    expect(await File(restored.original).readAsBytes(), durableBytes);
    expect(restored.caption, 'Our lunch');
    expect(restored.x, .17);
    expect(restored.y, -.08);
    expect(restored.scale, .79);
    expect(restored.rotation, .43);
    expect(restored.draft, false);
    expect(restored.background, 'sage');
  });
  test(
    'interrupted jobs recover and failures leave an editable original',
    () async {
      final m = meal('guest')..job = JobStatus.processing;
      await repo.save(m);
      final app = controller(FakeEngine(), TestGoogleCloud(null, media));
      await app.processQueue();
      final restored = (await repo.list('guest')).single;
      expect(restored.job, JobStatus.failed);
      expect(restored.original, m.original);
      expect(restored.useOriginal, true);
      restored.caption = 'Still a lovely memory';
      restored.draft = false;
      await app.save(restored);
      expect(
        (await repo.list('guest')).single.caption,
        'Still a lovely memory',
      );
      expect((await repo.evaluations('guest')).single['status'], 'failed');
      app.dispose();
    },
  );
  test('successful automatic cutouts leave the meal in Drafts', () async {
    await File('${temp.path}/original.jpg').writeAsBytes([1, 2, 3]);
    final m = meal('guest');
    await repo.save(m);
    final app = controller(FakePlateEngine(), TestGoogleCloud(null, media));
    await app.processQueue();
    final saved = (await repo.list('guest')).single;
    expect(saved.job, JobStatus.ready);
    expect(saved.plates, hasLength(1));
    expect(saved.draft, true);
    expect(LibraryPlate.fromMemories([saved]), isEmpty);
    await db.close();
    db = MorslDatabase(NativeDatabase(File('${temp.path}/test.sqlite')));
    repo = MemoryRepository(db);
    final reopened = (await repo.list('guest')).single;
    expect(reopened.draft, true);
    expect(reopened.plates, hasLength(1));
    app.dispose();
  });

  test('edits made during extraction survive completion', () async {
    await File('${temp.path}/original.jpg').writeAsBytes([1, 2, 3]);
    final m = meal('guest');
    await repo.save(m);
    final engine = FakeEngine()
      ..fails = false
      ..wait = Completer<void>();
    final app = controller(engine, TestGoogleCloud(null, media));
    final processing = app.processQueue();
    await engine.started.future;
    await repo.mutate(m.id, 'guest', (current) {
      current.caption = 'While it was processing';
      current.scale = .68;
      current.draft = false;
    });
    engine.wait!.complete();
    await processing;
    final restored = (await repo.list('guest')).single;
    expect(restored.job, JobStatus.ready);
    expect(restored.useOriginal, false);
    expect(restored.displayPath, restored.cutout);
    expect(await File(restored.cutout!).exists(), true);
    expect(restored.caption, 'While it was processing');
    expect(restored.scale, .68);
    expect(restored.draft, false);
    app.dispose();
  });
  test(
    'an original selected during extraction survives completion and retry',
    () async {
      await File('${temp.path}/original.jpg').writeAsBytes([1, 2, 3]);
      final m = meal('guest')..useOriginal = false;
      await repo.save(m);
      final engine = FakeEngine()
        ..fails = false
        ..wait = Completer<void>();
      final app = controller(engine, TestGoogleCloud(null, media));
      final processing = app.processQueue();
      await engine.started.future;
      await repo.mutate(m.id, 'guest', (current) => current.useOriginal = true);
      engine.wait!.complete();
      await processing;
      var restored = (await repo.list('guest')).single;
      expect(restored.job, JobStatus.ready);
      expect(restored.useOriginal, true);
      expect(restored.displayPath, restored.original);
      await app.retry(restored);
      restored = (await repo.list('guest')).single;
      expect(restored.useOriginal, true);
      app.dispose();
    },
  );
  test(
    'bundled examples use durable transparent cutouts on first launch',
    () async {
      final app = controller(FakeEngine(), TestGoogleCloud(null, media));
      await app.initialize();
      final examples = (await repo.list(
        'guest',
      )).where((m) => !m.draft).toList();
      expect(examples.length, 4);
      for (final m in examples) {
        expect(m.displaysCutout, true);
        expect(m.job, JobStatus.ready);
        expect(await File(m.original).exists(), true);
        final image = img.decodePng(await File(m.cutout!).readAsBytes())!;
        expect(image.numChannels, 4);
        expect(image.getPixel(0, 0).a, 0);
      }
      app.dispose();
    },
  );
  test(
    'existing examples gain cutouts without restoring cleared examples',
    () async {
      await repo.setPreference('seeded', 'true');
      final m = meal('guest')
        ..demo = true
        ..draft = false
        ..venue = 'Wildflour Café'
        ..caption = 'My edited caption'
        ..scale = .73;
      await repo.save(m);
      final app = controller(FakeEngine(), TestGoogleCloud(null, media));
      await app.initialize();
      final restored = (await repo.list('guest')).single;
      expect(restored.displaysCutout, true);
      expect(restored.caption, 'My edited caption');
      expect(restored.scale, .73);
      app.dispose();
      await repo.remove(m.id, 'guest');
      final next = controller(FakeEngine(), TestGoogleCloud(null, media));
      await next.initialize();
      expect(await repo.list('guest'), isEmpty);
      next.dispose();
    },
  );
  test(
    'photos arriving during extraction are picked up by the active queue',
    () async {
      await File('${temp.path}/original.jpg').writeAsBytes([1, 2, 3]);
      await repo.save(meal('guest'));
      final engine = FakeEngine()
        ..fails = false
        ..wait = Completer<void>();
      final app = controller(engine, TestGoogleCloud(null, media));
      final processing = app.processQueue();
      await engine.started.future;
      await repo.save(
        Memory(
          id: 'meal-2',
          scope: 'guest',
          createdAt: DateTime(2026, 10, 5),
          original: '${temp.path}/original.jpg',
        ),
      );
      await app.processQueue();
      engine.wait!.complete();
      await processing;
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while ((await repo.list('guest')).any((m) => m.job != JobStatus.ready) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        (await repo.list('guest')).every((m) => m.job == JobStatus.ready),
        true,
      );
      app.dispose();
    },
  );
  test(
    'account association is explicit and cache scopes are isolated',
    () async {
      await repo.save(meal('guest'));
      expect(await repo.list('account-a'), isEmpty);
      await repo.associateGuest('account-a');
      expect(await repo.list('guest'), isEmpty);
      expect((await repo.list('account-a')).single.creator, 'account-a');
      expect(await repo.list('account-b'), isEmpty);
      expect((await repo.pending('account-a')).length, 1);
    },
  );
  test(
    'interrupted backup retries do not duplicate meals or drop original',
    () async {
      final m = meal('account-a')..draft = false;
      await repo.save(m);
      final cloud = FakeCloud(null, media);
      final app = controller(FakeEngine(), cloud);
      await app.sync(manual: true);
      expect((await repo.pending('account-a')).single.attempts, 1);
      expect((await repo.list('account-a')).single.original, m.original);
      cloud.failPush = false;
      await app.sync(manual: true);
      await app.sync(manual: true);
      expect(cloud.remote.length, 1);
      expect(await repo.pending('account-a'), isEmpty);
      expect((await repo.list('account-a')).length, 1);
      app.dispose();
    },
  );
  test(
    'a new edit cannot be acknowledged by an older queued operation',
    () async {
      final m = meal('account-a');
      await repo.save(m);
      final op = (await repo.pending('account-a')).single;
      m.caption = 'A newer thought';
      await repo.save(m);
      await repo.complete(op);
      final pending = (await repo.pending('account-a')).single;
      expect(pending.id, isNot(op.id));
      expect(pending.payload['caption'], 'A newer thought');
    },
  );
  test(
    'successful cloud restore commits references before removing backed-up document files',
    () async {
      final dir = await media.directory('account-a', 'meal-1');
      final source = await File(
        '${dir.path}/original.jpg',
      ).writeAsBytes([1, 2, 3]);
      final cutout = await File('${dir.path}/plate.png').writeAsBytes([4, 5]);
      final memory = meal('account-a')
        ..original = source.path
        ..job = JobStatus.ready
        ..plates = [Plate(id: 'plate', mask: 'mask', path: cutout.path)];
      await repo.save(memory);
      final cloud = ReferenceCloud(null, media)..failPush = false;
      final app = controller(FakeEngine(), cloud);
      await app.sync(manual: true);
      expect(app.syncError, null);
      final restored = (await repo.list('account-a')).single;
      expect(MediaStore.isRemote(restored.original), true);
      expect(MediaStore.isRemote(restored.plates.single.path), true);
      expect(await repo.pending('account-a'), isEmpty);
      expect(await source.exists(), false);
      expect(await cutout.exists(), false);
      app.dispose();
    },
  );
  test(
    'an edit queued during restore prevents replacement and document cleanup',
    () async {
      final dir = await media.directory('account-a', 'meal-1');
      final source = await File(
        '${dir.path}/original.jpg',
      ).writeAsBytes([1, 2, 3]);
      final memory = meal('account-a')
        ..original = source.path
        ..job = JobStatus.ready;
      await repo.save(memory);
      final cloud = ReferenceCloud(null, media)..failPush = false;
      cloud.duringPull = () async {
        await repo.mutate(
          memory.id,
          memory.scope,
          (current) => current.caption = 'A newer edit',
        );
      };
      final app = controller(FakeEngine(), cloud);
      await app.sync(manual: true);
      expect(app.syncError, null);
      final restored = (await repo.list('account-a')).single;
      expect(restored.original, source.path);
      expect(restored.caption, 'A newer edit');
      expect(await source.exists(), true);
      expect(await repo.pending('account-a'), hasLength(1));
      app.dispose();
    },
  );
  test(
    'revocation purges shared caches even when another download fails',
    () async {
      final dir = await media.directory('account-a', 'shared');
      final file = File('${dir.path}/original.jpg');
      await file.writeAsBytes([1, 2, 3]);
      final m = Memory(
        id: 'shared',
        scope: 'account-a',
        creator: 'account-b',
        createdAt: DateTime(2026, 10, 5),
        original: file.path,
        mealRevision: 1,
        draft: false,
      );
      await repo.save(m, enqueue: false);
      final cloud = FakeCloud(null, media)..failPull = true;
      final app = controller(FakeEngine(), cloud);
      await app.sync(manual: true);
      expect(await repo.list('account-a'), isEmpty);
      expect(await file.exists(), false);
      expect(app.syncError, contains('cannot be downloaded'));
      app.dispose();
    },
  );
  test(
    'imported EXIF date can be recovered without changing the original',
    () async {
      final image = img.Image(width: 4, height: 4);
      image.exif.exifIfd[0x9003] = img.IfdValueAscii('2026:09:28 18:30:00');
      final file = File('${temp.path}/import.jpg');
      await file.writeAsBytes(img.encodeJpg(image));
      final before = await file.readAsBytes();
      final metadata = await media.metadata(file.path);
      expect(metadata['createdAt'], '2026-09-28T18:30:00.000');
      expect(await file.readAsBytes(), before);
    },
  );
  test(
    'manual plates survive automatic completion and subsequent retries',
    () async {
      final memory = meal('guest');
      await repo.save(memory);
      final engine = FakePlateEngine()..wait = Completer<void>();
      final app = controller(engine, TestGoogleCloud(null, media));
      final processing = app.processQueue();
      await engine.started.future;
      await repo.mutate(memory.id, 'guest', (current) {
        current.plates = [
          Plate(id: 'manual', mask: solidPlateMask(), x: .72, rotation: .3),
        ];
        current.platesEdited = true;
        current.useOriginal = false;
        current.caption = 'My plate';
      });
      engine.wait!.complete();
      await processing;
      await app.retry((await repo.list('guest')).single);
      final saved = (await repo.list('guest')).single;
      expect(saved.plates.single.id, 'manual');
      expect(saved.plates.single.x, .72);
      expect(saved.plates.single.rotation, .3);
      expect(saved.caption, 'My plate');
      expect(saved.job, JobStatus.ready);
      app.dispose();
    },
  );
  test('separate masks and placement survive reopening the database', () async {
    final memory = meal('guest')
      ..plates = [
        Plate(id: 'a', mask: solidPlateMask(), x: .1, y: .2, scale: .4),
        Plate(id: 'b', mask: solidPlateMask(), x: .6, rotation: -.5),
      ]
      ..platesEdited = true;
    await repo.save(memory);
    await db.close();
    db = MorslDatabase(NativeDatabase(File('${temp.path}/test.sqlite')));
    repo = MemoryRepository(db);
    final saved = (await repo.list('guest')).single;
    expect(saved.plates.length, 2);
    expect(saved.plates.first.x, .1);
    expect(saved.plates.first.scale, .4);
    expect(saved.plates.last.rotation, -.5);
    expect(saved.platesEdited, true);
  });
}
