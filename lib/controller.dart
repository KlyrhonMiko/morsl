import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'data/models.dart';
import 'data/repository.dart';
import 'services/cloud.dart';
import 'services/media.dart';
import 'services/plates.dart';
import 'services/reminders.dart';

final appProvider = Provider<MorslController>(
  (ref) => throw StateError('App not initialized'),
);

class MorslController extends ChangeNotifier {
  MorslController({
    required this.repository,
    required this.media,
    required this.engine,
    required this.cloud,
    required this.reminders,
  });
  final MemoryRepository repository;
  final MediaStore media;
  final SegmentationEngine engine;
  final CloudService cloud;
  final DraftReminders reminders;
  List<Memory> memories = [];
  List<SyncOperation> operations = [];
  String get scope =>
      cloud.signedInWithGoogle ? cloud.account ?? 'guest' : 'guest';
  int destination = 0;
  bool busySync = false, modelReady = false, reminderEnabled = false;
  bool _processing = false;
  bool active = true;
  bool online = true;
  bool get canMutate => cloud.signedInWithGoogle && cloud.account != null;
  void requireGoogleAccount([Memory? memory]) {
    if (!canMutate) throw StateError('Sign in with Google to make changes.');
    if (memory != null && memory.scope != scope) {
      throw StateError('This memory belongs to another scrapbook.');
    }
  }

  bool cloudCutoutsDecided = false;
  bool get usesCloudCutouts => engine is RemoteSegmentationEngine;
  bool get cloudCutoutsAllowed =>
      engine is RemoteSegmentationEngine &&
      (engine as RemoteSegmentationEngine).uploadsAllowed;
  bool get cloudCutoutsSignedIn =>
      engine is! RemoteSegmentationEngine ||
      (engine as RemoteSegmentationEngine).authenticated;
  bool get _canProcess =>
      canMutate &&
      (!usesCloudCutouts ||
          (cloudCutoutsAllowed && cloudCutoutsSignedIn && online));
  int reminderHour = 20, reminderMinute = 0;
  String? syncError, notice, authError;
  Timer? _syncTimer;
  StreamSubscription? _auth;
  StreamSubscription? _connectivity;
  String? _authScope;

  Future<void> initialize({bool seedExamples = true}) async {
    try {
      online = !(await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.none,
      );
      _connectivity = Connectivity().onConnectivityChanged.listen((results) {
        final wasOffline = !online;
        online = !results.contains(ConnectivityResult.none);
        notifyListeners();
        if (online && wasOffline && active) {
          unawaited(sync());
          unawaited(processQueue());
        }
      });
    } catch (_) {
      /* Manual retry and local history remain available. */
    }
    if (seedExamples && await repository.preference('seeded') == null) {
      await _seed();
      await repository.setPreference('seeded', 'true');
    }
    if (seedExamples) {
      await _upgradeExampleCutouts();
    }
    await reload();
    await _loadCloudCutoutChoice();
    reminderEnabled = await repository.preference('reminders:$scope') == 'true';
    final time = (await repository.preference('reminderTime:$scope') ?? '20:0')
        .split(':');
    reminderHour = int.parse(time[0]);
    reminderMinute = int.parse(time[1]);
    try {
      modelReady = await engine.available();
    } catch (_) {
      modelReady = false;
    }
    try {
      await reminders.initialize(() {
        destination = 2;
        notifyListeners();
      });
      await _schedule();
    } catch (e) {
      notice =
          'Reminders are unavailable on this device. Your drafts are always here.';
    }
    _authScope = scope;
    _auth = cloud.client?.auth.onAuthStateChange.listen(
      (_) {
        authError = null;
        if (_authScope != scope) {
          _authScope = scope;
          unawaited(_accountChanged());
        }
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        // Callback errors can contain OAuth codes. Keep those out of the UI.
        authError = 'Google sign-in could not be completed. Please try again.';
        notifyListeners();
      },
    );
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (active) {
        unawaited(sync());
      }
    });
    unawaited(processQueue());
    unawaited(sync());
  }

  Future<void> _accountChanged() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    destination = 0;
    // Revoke the previous account's upload choice before any asynchronous work.
    if (engine case RemoteSegmentationEngine remote) {
      remote.uploadsAllowed = false;
    }
    modelReady = false;
    await _loadCloudCutoutChoice();
    reminderEnabled = await repository.preference('reminders:$scope') == 'true';
    final time = (await repository.preference('reminderTime:$scope') ?? '20:0')
        .split(':');
    reminderHour = int.parse(time[0]);
    reminderMinute = int.parse(time[1]);
    await reload();
    await _schedule();
    unawaited(sync());
    unawaited(processQueue());
  }

  Future<void> signInWithGoogle() async {
    authError = null;
    notifyListeners();
    await cloud.signInWithGoogle();
  }

  Future<void> reload() async {
    final account = scope;
    final items = await repository.list(account);
    final pending = await repository.pending(account);
    if (account != scope) {
      return;
    }
    memories = items;
    operations = pending;
    notifyListeners();
  }

  Future<void> _loadCloudCutoutChoice() async {
    if (engine case RemoteSegmentationEngine remote) {
      final account = scope;
      final choice = await repository.preference('cloudCutouts:v1:$account');
      if (scope != account) return;
      cloudCutoutsDecided = choice != null;
      remote.uploadsAllowed = choice == 'true';
    }
  }

  Future<void> setCloudCutoutsAllowed(bool allowed) async {
    requireGoogleAccount();
    if (engine case RemoteSegmentationEngine remote) {
      if (allowed && !remote.authenticated) {
        throw StateError('Sign in to use cloud cutouts.');
      }
      final account = scope;
      remote.uploadsAllowed = allowed;
      cloudCutoutsDecided = true;
      modelReady = false;
      notifyListeners();
      await repository.setPreference('cloudCutouts:v1:$account', '$allowed');
      if (scope != account) return;
      if (allowed) unawaited(processQueue());
    }
  }

  Future<void> save(Memory m, {bool enqueue = true}) async {
    requireGoogleAccount(m);
    await repository.save(m, enqueue: enqueue);
    await reload();
    await _schedule();
  }

  Future<void> toggleBookmark(Memory memory) async {
    requireGoogleAccount(memory);
    await repository.mutate(
      memory.id,
      memory.scope,
      (current) => current.bookmarked = !current.bookmarked,
    );
    await reload();
  }

  void navigate(int index) {
    destination = index;
    notifyListeners();
  }

  void lifecycle(bool foreground) {
    active = foreground;
    if (foreground) {
      unawaited(processQueue());
      unawaited(sync());
    }
  }

  Future<Memory?> capture(ImageSource source, {bool locate = false}) async {
    requireGoogleAccount();
    final account = scope;
    final photo = await ImagePicker().pickImage(
      source: source,
      imageQuality: 95,
    );
    if (photo == null) {
      return null;
    }
    if (scope != account) throw StateError('Account changed during capture.');
    return importPhoto(
      photo,
      locate: locate,
      readMetadata: source == ImageSource.gallery,
    );
  }

  Future<Memory> importPhoto(
    XFile photo, {
    bool locate = false,
    bool readMetadata = false,
  }) async {
    requireGoogleAccount();
    final account = scope;
    final id = const Uuid().v4();
    final original = await media.preserve(photo, account, id);
    requireGoogleAccount();
    if (scope != account) throw StateError('Account changed during import.');
    final m = Memory(
      id: id,
      assetId: id,
      scope: account,
      creator: cloud.account,
      createdAt: DateTime.now(),
      original: original,
      useOriginal: false,
    );
    // The first database commit precedes all optional work.
    await repository.save(m);
    await reload();
    await _schedule();
    notice = 'Saved for later. Your original is safe.';
    notifyListeners();
    if (locate) {
      unawaited(_locate(m));
    }
    if (readMetadata) {
      unawaited(_readMetadata(m));
    }
    unawaited(_thumbnail(m));
    unawaited(processQueue());
    return m;
  }

  Future<void> recoverLostCapture() async {
    if (!Platform.isAndroid || !canMutate) {
      return;
    }
    final lost = await ImagePicker().retrieveLostData();
    for (final file in lost.files ?? <XFile>[]) {
      await importPhoto(file);
    }
  }

  Future<void> _readMetadata(Memory m) async {
    await media.beginWork(m.scope, m.id);
    try {
      final metadata = await media.metadata(m.original);
      await repository.mutate(m.id, m.scope, (current) {
        if (metadata['createdAt'] != null && current.createdAt == m.createdAt) {
          current.createdAt = DateTime.parse(metadata['createdAt']);
        }
        if (!current.locationConfirmed &&
            current.latitude == null &&
            metadata['latitude'] != null) {
          current.latitude = metadata['latitude'];
          current.longitude = metadata['longitude'];
          current.measuredAt = current.createdAt;
        }
      });
      await reload();
    } catch (_) {
      /* Missing capture metadata is an ordinary imported photo. */
    } finally {
      await media.endWork(m.scope, m.id);
    }
  }

  Future<void> _thumbnail(Memory m) async {
    await media.beginWork(m.scope, m.id);
    try {
      final path = await media.thumbnail(m.original);
      await repository.mutate(
        m.id,
        m.scope,
        (current) => current.thumbnail = path,
      );
      await reload();
    } catch (_) {
      /* Originals remain sufficient for editing. */
    } finally {
      await media.endWork(m.scope, m.id);
    }
  }

  Future<void> _locate(Memory m) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 4),
        ),
      );
      await repository.mutate(m.id, m.scope, (current) {
        if (current.locationConfirmed) {
          return;
        }
        current.latitude = pos.latitude;
        current.longitude = pos.longitude;
        current.accuracy = pos.accuracy;
        current.measuredAt = pos.timestamp;
      });
      await reload();
    } catch (_) {
      /* Optional GPS cannot block the durable draft. */
    }
  }

  Future<void> processQueue() async {
    if (_processing || !active || !_canProcess) {
      return;
    }
    _processing = true;
    try {
      final account = scope;
      final jobs = await repository.list(account);
      for (final m in jobs.where((m) => m.job == JobStatus.processing)) {
        m.job = JobStatus.queued;
        m.error = 'Interrupted processing recovered.';
        await repository.save(m, enqueue: false);
      }
      for (final m in jobs.where((m) => m.job == JobStatus.queued && !m.demo)) {
        if (!active || scope != account || !_canProcess) {
          break;
        }
        m.job = JobStatus.processing;
        m.attempts++;
        m.error = null;
        await repository.save(m, enqueue: false);
        await reload();
        final watch = Stopwatch()..start();
        String? output, error;
        List<Plate>? plates;
        MediaLease? source;
        try {
          source = await media.acquire(m.original);
          final dir = await media.directory(m.scope, m.id);
          if (engine case MultiSubjectSegmentationEngine multi) {
            plates = await multi.subjects(source.file.path, dir.path);
            if (plates.isEmpty) {
              error = 'No separate plates found. Select a plate to cut it out.';
            }
          } else {
            output = await engine.process(
              source.file.path,
              p.join(dir.path, 'cutout.png'),
            );
          }
        } catch (e) {
          error = e.toString();
        } finally {
          await source?.close();
        }
        if (scope != account || !_canProcess) {
          await repository.mutate(m.id, m.scope, (current) {
            current.job = JobStatus.queued;
            current.error = null;
          }, enqueue: false);
          break;
        }
        if (usesCloudCutouts) modelReady = error == null;
        watch.stop();
        final current = await repository.mutate(m.id, m.scope, (current) {
          // Select the first successful cutout, while preserving a photo choice
          // made during processing and any choice made before a later retry.
          if ((output != null || plates?.isNotEmpty == true) &&
              current.cutout == null &&
              current.plates.isEmpty &&
              !current.platesEdited &&
              current.useOriginal == m.useOriginal) {
            current.useOriginal = false;
          }
          if (plates?.isNotEmpty == true &&
              !current.platesEdited &&
              current.plates.isEmpty) {
            current.plates = plates!;
          }
          current.job = output != null || current.plates.isNotEmpty
              ? JobStatus.ready
              : JobStatus.failed;
          current.cutout = output ?? current.cutout;
          current.error = error;
          current.durationMs = watch.elapsedMilliseconds;
          current.runtime = engine.runtime;
          current.attempts = m.attempts;
        });
        if (current != null) {
          await repository.evaluate(current);
        }
        await reload();
      }
    } finally {
      _processing = false;
      if (active &&
          _canProcess &&
          (await repository.list(scope)).any(
            (m) =>
                !m.demo &&
                (m.job == JobStatus.queued || m.job == JobStatus.processing),
          )) {
        unawaited(processQueue());
      }
    }
  }

  Future<void> retry(Memory m) async {
    requireGoogleAccount(m);
    await repository.mutate(m.id, m.scope, (current) {
      current.job = JobStatus.queued;
      current.error = null;
    }, enqueue: false);
    await reload();
    await processQueue();
  }

  Future<void> rate(Memory m, String rating, String? category) async {
    requireGoogleAccount(m);
    final current = await repository.mutate(m.id, m.scope, (current) {
      current.rating = rating;
      current.failureCategory = category;
    });
    if (current != null) {
      await repository.evaluate(current);
    }
    await reload();
  }

  Future<String> exportEvaluations() async {
    requireGoogleAccount();
    final dir = await media.directory(scope, 'exports');
    final file = File(
      p.join(
        dir.path,
        'morsl-evaluation-${DateTime.now().millisecondsSinceEpoch}.json',
      ),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'evaluations': await repository.evaluations(scope),
        'events': await repository.events(scope),
      }),
      flush: true,
    );
    return file.path;
  }

  Future<void> setReminder(bool enabled, int hour, int minute) async {
    requireGoogleAccount();
    if (enabled && !await reminders.requestPermission()) {
      throw StateError(
        'Notification permission was not granted. You can still finish memories in Drafts.',
      );
    }
    reminderEnabled = enabled;
    reminderHour = hour;
    reminderMinute = minute;
    await repository.setPreference('reminders:$scope', enabled.toString());
    await repository.setPreference('reminderTime:$scope', '$hour:$minute');
    await _schedule();
    notifyListeners();
  }

  Future<void> _schedule() => reminders.schedule(
    enabled: canMutate && reminderEnabled,
    hasDrafts: memories.any((m) => m.draft && !m.archived),
    hour: reminderHour,
    minute: reminderMinute,
  );

  Future<void> sync({bool manual = false}) async {
    if (manual) requireGoogleAccount();
    if (!canMutate || !cloud.configured) return;
    if (busySync || cloud.account == null || !online) {
      return;
    }
    busySync = true;
    syncError = null;
    notifyListeners();
    final account = scope;
    try {
      final allowed = await cloud.authorizedIds();
      // A successful authorization check revokes cached access even if a
      // different memory's asset download fails later in the same sync.
      for (final m in await repository.list(account)) {
        if (scope != account) {
          break;
        }
        if (!allowed.contains(m.id) && (!m.ownsMeal || m.mealRevision > 0)) {
          await removeLocal(m);
        }
      }
      final queue = await repository.pending(account);
      for (final op in queue) {
        if (cloud.account != account) {
          break;
        }
        if (!manual && (op.nextAttempt?.isAfter(DateTime.now()) ?? false)) {
          continue;
        }
        try {
          final remote = await cloud.push(Memory.fromJson(op.payload));
          if (scope != account) {
            break;
          }
          final current = (await repository.list(
            account,
          )).where((m) => m.id == op.entity).firstOrNull;
          if (current != null) {
            current.mealRevision = remote['mealRevision'];
            current.memoryRevision = remote['memoryRevision'];
            final latest = (await repository.pending(
              account,
            )).where((q) => q.entity == op.entity).firstOrNull;
            await repository.save(current, enqueue: latest?.id != op.id);
          }
          await repository.complete(op);
        } catch (e) {
          await repository.fail(op, e.toString());
          syncError = e.toString();
          await repository.event(account, 'sync_failed', {
            'mealId': op.entity,
            'attempt': op.attempts + 1,
            'error': e.toString(),
          });
        }
      }
      if (scope == account) {
        final restored = await cloud.pull(account);
        final localIds = (await repository.list(
          account,
        )).map((m) => m.id).toSet();
        for (final m in restored) {
          if (scope != account) {
            break;
          }
          Memory? previous;
          final applied = await repository.db.transaction(() async {
            if (scope != account) return false;
            final pending = await repository.pending(account);
            final before = (await repository.list(
              account,
            )).where((item) => item.id == m.id).firstOrNull;
            previous = before;
            if (pending.any((op) => op.entity == m.id) ||
                before?.job == JobStatus.processing ||
                before?.job == JobStatus.queued) {
              return false;
            }
            await repository.save(m, enqueue: false);
            return true;
          });
          if (applied) {
            if (m.original.isEmpty && previous != null) {
              PaintingBinding.instance.imageCache.clear();
              PaintingBinding.instance.imageCache.clearLiveImages();
              for (final ref in {
                previous!.original,
                previous!.cutout,
                previous!.thumbnail,
                ...previous!.plates.map((plate) => plate.path),
              }.whereType<String>()) {
                await media.revoke(ref);
              }
            }
            // Commit cloud references before pruning files. Recheck pending edits
            // while holding the repository lock so new durable edits remain safe.
            if (!m.demo &&
                (m.original.isEmpty ||
                    (MediaStore.isRemote(m.original) &&
                        m.plates.every(
                          (plate) => MediaStore.isRemote(plate.path),
                        )))) {
              await repository.db.transaction(() async {
                if (scope == account &&
                    !(await repository.pending(
                      account,
                    )).any((op) => op.entity == m.id)) {
                  await media.removeBackedUpFiles(account, m.id);
                }
              });
            }
            if (!localIds.contains(m.id)) {
              await repository.event(account, 'memory_restored', {
                'mealId': m.id,
                'hasOriginal': m.original.isNotEmpty,
              });
            }
          }
        }
        if (scope == account) {
          final allowed = restored.map((m) => m.id).toSet();
          // Revoke shared cached assets only after a successful authorized pull.
          for (final m in await repository.list(account)) {
            if (!m.ownsMeal && !allowed.contains(m.id)) {
              await removeLocal(m);
            }
          }
        }
      }
      await media.cache.trim();
      if (scope == account && cloud.client != null) {
        final last = DateTime.tryParse(
          await repository.preference('imageCleanup:$account') ?? '',
        );
        if (last == null ||
            DateTime.now().difference(last) >= const Duration(days: 1)) {
          try {
            await cloud.cleanupImages();
            await repository.setPreference(
              'imageCleanup:$account',
              DateTime.now().toIso8601String(),
            );
          } catch (_) {
            /* Cleanup retries on the next sync without blocking backup. */
          }
        }
      }
    } catch (e) {
      syncError = e.toString();
    }
    busySync = false;
    await reload();
  }

  Future<void> associateGuest() async {
    requireGoogleAccount();
    if (cloud.account == null) {
      return;
    }
    final account = scope;
    final guests = (await repository.list(
      'guest',
    )).where((m) => !m.demo).toList();
    for (final m in guests) {
      if (scope != account) {
        throw StateError(
          'Account changed. Local memories have not all been associated.',
        );
      }
      final dir = await media.directory(account, m.id);
      final moved = m.copy()
        ..scope = account
        ..creator = account;
      for (final entry in {
        'original': m.original,
        'cutout': m.cutout,
        'thumbnail': m.thumbnail,
      }.entries) {
        if (entry.value == null || entry.value!.isEmpty) {
          continue;
        }
        final target = p.join(dir.path, p.basename(entry.value!));
        await File(entry.value!).copy(target);
        switch (entry.key) {
          case 'original':
            moved.original = target;
          case 'cutout':
            moved.cutout = target;
          case 'thumbnail':
            moved.thumbnail = target;
        }
      }
      moved.plates = await Future.wait(
        moved.plates.map(
          (plate) => renderPlate(moved.original, dir.path, plate),
        ),
      );
      await repository.db.transaction(() async {
        await repository.save(moved);
        await repository.remove(m.id, 'guest');
      });
      final oldDir = await media.directory('guest', m.id);
      if (await oldDir.exists()) {
        await oldDir.delete(recursive: true);
      }
    }
    await reload();
    await sync(manual: true);
  }

  Future<Memory> cloudVersion(String id) async {
    final account = scope;
    final rows = await cloud.pull(account);
    if (scope != account) {
      throw StateError('Account changed. Return to your current scrapbook.');
    }
    final remote = rows.where((m) => m.id == id).firstOrNull;
    if (remote == null) {
      throw StateError('This meal is no longer available.');
    }
    return remote;
  }

  Future<void> resolveConflict(Memory remote, {required bool keepLocal}) async {
    requireGoogleAccount(remote);
    if (scope != remote.scope) {
      throw StateError('Account changed.');
    }
    if (keepLocal) {
      await repository.mutate(remote.id, remote.scope, (current) {
        current.mealRevision = remote.mealRevision;
        current.memoryRevision = remote.memoryRevision;
      });
    } else {
      await repository.db.transaction(() async {
        for (final op in (await repository.pending(
          remote.scope,
        )).where((o) => o.entity == remote.id)) {
          await repository.complete(op);
        }
        await repository.save(remote, enqueue: false);
      });
    }
    await reload();
    await sync(manual: true);
  }

  Future<void> removeLocal(Memory m) async {
    await repository.remove(m.id, m.scope);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    for (final path in {
      m.original,
      m.cutout,
      m.thumbnail,
      ...m.plates.map((plate) => plate.path),
    }.whereType<String>().where((path) => path.isNotEmpty)) {
      if (MediaStore.isRemote(path)) {
        await media.revoke(path);
        continue;
      }
      final provider = FileImage(File(path));
      await provider.evict();
      await ResizeImage(provider, width: 700).evict();
    }
    final managed = await media.directory(m.scope, m.id);
    // Only the app-managed account/meal directory is removed.
    if (await managed.exists()) {
      await managed.delete(recursive: true);
    }
    await reload();
  }

  Future<void> clearExamples() async {
    requireGoogleAccount();
    for (final m in memories.where((m) => m.demo).toList()) {
      await removeLocal(m);
    }
  }

  Future<void> _seed() async {
    final now = DateTime.now();
    final samples = [
      (
        'salad.jpg',
        'The kind of lunch that turns into dinner.',
        'Wildflour Café',
        ['Jamie', 'Alex'],
        'sage',
        1,
        true,
      ),
      (
        'pasta.jpg',
        'A little pasta, a lot of catching up.',
        'A Mano',
        ['Jamie'],
        'cream',
        3,
        true,
      ),
      (
        'pizza.jpg',
        'One more slice. Always.',
        'Gino’s Brick Oven Pizza',
        ['Alex', 'Sam'],
        'rose',
        5,
        false,
      ),
      (
        'pastry.jpg',
        'Slow mornings & something sweet.',
        'Toby’s Estate',
        ['Just me'],
        'sand',
        8,
        true,
      ),
    ];
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final id = const Uuid().v4();
      final photo = await media.sample('assets/images/${s.$1}', id);
      final cutout = await media.sample(
        'assets/images/${s.$1.replaceAll('.jpg', '-cutout.png')}',
        id,
        filename: 'cutout.png',
      );
      final m = Memory(
        id: id,
        scope: 'guest',
        createdAt: now.subtract(Duration(days: s.$6)),
        original: photo,
        cutout: cutout,
        useOriginal: false,
        caption: s.$2,
        venue: s.$3,
        companions: s.$4,
        background: s.$5,
        draft: false,
        demo: true,
        bookmarked: s.$7,
        job: JobStatus.ready,
        latitude: 14.5547 + i * .004,
        longitude: 121.0244 + i * .003,
        locationConfirmed: true,
        layout: i.isEven ? 'classic' : 'postcard',
      );
      m.thumbnail = await media.thumbnail(photo);
      await repository.save(m, enqueue: false);
    }
    final id = const Uuid().v4();
    final photo = await media.sample('assets/images/shared-table.jpg', id);
    await repository.save(
      Memory(
        id: id,
        scope: 'guest',
        createdAt: now,
        original: photo,
        demo: true,
        venue: 'Sunday at home',
        companions: ['Jamie'],
        job: JobStatus.failed,
        error: 'Example draft. Import a meal to try cloud cutouts.',
      ),
      enqueue: false,
    );
  }

  Future<void> _upgradeExampleCutouts() async {
    if (await repository.preference('exampleCutouts:v1') == 'true') return;
    // Upgrade only the bundled examples still present in this scrapbook.
    // Clearing examples stays permanent; real meals and their edits stay intact.
    const assets = {
      'Wildflour Café': 'salad',
      'A Mano': 'pasta',
      'Gino’s Brick Oven Pizza': 'pizza',
      'Toby’s Estate': 'pastry',
    };
    for (final m in await repository.list('guest')) {
      final asset = assets[m.venue];
      if (!m.demo || m.draft || m.cutout != null || asset == null) continue;
      m.cutout = await media.sample(
        'assets/images/$asset-cutout.png',
        m.id,
        filename: 'cutout.png',
      );
      m.useOriginal = false;
      m.job = JobStatus.ready;
      m.error = null;
      await repository.save(m, enqueue: false);
    }
    await repository.setPreference('exampleCutouts:v1', 'true');
  }

  @override
  void dispose() {
    active = false;
    _syncTimer?.cancel();
    _auth?.cancel();
    _connectivity?.cancel();
    super.dispose();
  }
}
