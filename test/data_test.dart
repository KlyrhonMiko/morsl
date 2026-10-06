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
  @override
  String get runtime => 'test device / test model';
  @override
  Future<bool> available() async => true;
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

// Existing persistence fixtures use "guest" as their isolated test scope.
// They now exercise a signed-in controller rather than authorizing real guests.
class TestGoogleCloud extends CloudService {
  TestGoogleCloud(super.client, super.media);
  @override
  String? get account => 'guest';
  @override
  bool get signedInWithGoogle => true;
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
    await source.writeAsBytes([1, 2, 3], flush: true);
    final durable = await media.preserve(XFile(source.path), 'guest', 'meal-1');
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
    expect(await File(restored.original).readAsBytes(), [1, 2, 3]);
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
