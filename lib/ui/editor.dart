import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/media.dart';
import '../services/plates.dart';
import 'plate_tools.dart';
import 'theme.dart';
import 'plate_library.dart';
import 'tools.dart';
import 'cloud_cutouts.dart';
import 'account_gate.dart';
import 'cutout_status.dart';
import 'plate_preview_pager.dart';

class PlatingEditor extends ConsumerStatefulWidget {
  const PlatingEditor({super.key, required this.memory});
  final Memory memory;
  @override
  ConsumerState<PlatingEditor> createState() => _PlatingEditorState();
}

class _PlatingEditorState extends ConsumerState<PlatingEditor> {
  late Memory memory;
  late MorslController app;
  late TextEditingController caption, venue, companions;
  Timer? debounce;
  Future<void> saving = Future.value();
  String status = 'All edits saved on this device';
  bool dateEdited = false, locationEdited = false;
  bool photoChoiceEdited = false;
  bool platesDirty = false, findingPlates = false;
  String? selectedPlateId;
  String? selectedPhotoId;
  bool addingPhotos = false;
  String get selectedOriginal => selectedPhotoId == null
      ? memory.original
      : memory.photos
                .where((p) => p.id == selectedPhotoId)
                .firstOrNull
                ?.original ??
            memory.original;
  Plate? get selectedPlate => memory.displaysCutout
      ? memory.plates.where((p) => p.id == selectedPlateId).firstOrNull ??
            memory.plates.firstOrNull
      : null;
  bool unavailable = false;
  final Stopwatch editing = Stopwatch()..start();
  @override
  void initState() {
    super.initState();
    app = ref.read(appProvider);
    memory = widget.memory.copy()..useOriginal = false;
    caption = TextEditingController(text: memory.caption);
    venue = TextEditingController(text: memory.venue);
    companions = TextEditingController(text: memory.companions.join(', '));
    app.addListener(_processed);
  }

  void _processed() {
    if (app.scope != memory.scope) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    final current = app.memories.where((m) => m.id == memory.id).firstOrNull;
    if (current == null && mounted) {
      setState(() => unavailable = true);
      return;
    }
    if (current != null && mounted) {
      setState(() {
        if (!photoChoiceEdited &&
            memory.cutout == null &&
            memory.plates.isEmpty &&
            (current.cutout != null || current.plates.isNotEmpty)) {
          memory.useOriginal = false;
        }
        memory.cutout = current.cutout;
        memory.original = current.original;
        memory.photos = current.copy().photos;
        memory.originalProcessed = current.originalProcessed;
        memory.thumbnail = current.thumbnail;
        if (current.original.isEmpty) {
          memory.plates = [];
          platesDirty = false;
        }
        if (!platesDirty) {
          memory.plates = current.plates.map((p) => p.copy()).toList();
          memory.platesEdited = current.platesEdited;
        }
        memory.job = current.job;
        memory.error = current.error;
        memory.durationMs = current.durationMs;
        memory.runtime = current.runtime;
        if (!dateEdited) {
          memory.createdAt = current.createdAt;
        }
        if (!locationEdited) {
          memory.latitude = current.latitude;
          memory.longitude = current.longitude;
          memory.accuracy = current.accuracy;
          memory.measuredAt = current.measuredAt;
        }
      });
    }
  }

  void change(VoidCallback update) {
    if (!app.canMutate || app.scope != memory.scope) {
      return;
    }
    setState(() {
      update();
      status = 'Saving your little changes…';
    });
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), _persist);
  }

  Future<void> _persist() {
    if (!app.canMutate || app.scope != memory.scope) return Future.value();
    final snapshot = memory.copy();
    final didDateEdit = dateEdited, didLocationEdit = locationEdited;
    final didPlateEdit = platesDirty;
    saving = saving
        .catchError((Object _) {})
        .then((_) async {
          if (!app.canMutate || app.scope != snapshot.scope) return;
          await app.repository.mutate(snapshot.id, snapshot.scope, (current) {
            current.caption = snapshot.caption;
            current.feeling = snapshot.feeling;
            current.bookmarked = snapshot.bookmarked;
            current.draft = snapshot.draft;
            current.archived = snapshot.archived;
            current.background = snapshot.background;
            current.layout = snapshot.layout;
            current.x = snapshot.x;
            current.y = snapshot.y;
            current.scale = snapshot.scale;
            current.rotation = snapshot.rotation;
            current.useOriginal = false;
            if (didPlateEdit && current.original.isNotEmpty) {
              current.plates = snapshot.plates;
              current.platesEdited = true;
            }
            if (current.ownsMeal) {
              current.venue = snapshot.venue;
              current.placeId = snapshot.placeId;
              current.companions = snapshot.companions;
              if (didDateEdit) {
                current.createdAt = snapshot.createdAt;
              }
              current.locationConfirmed = snapshot.locationConfirmed;
              // Do not discard a GPS result that arrived while the editor was open.
              if (didLocationEdit) {
                current.latitude = snapshot.latitude;
                current.longitude = snapshot.longitude;
              }
            }
          });
          await app.reload();
          if (mounted) {
            setState(() => status = 'All edits saved on this device');
          }
        })
        .catchError((Object e) {
          if (mounted) {
            setState(() => status = 'Could not save: $e');
          }
        });
    return saving;
  }

  void plateChange(VoidCallback update) => change(() {
    platesDirty = true;
    memory.platesEdited = true;
    update();
  });

  Widget _guardPlateTool(Widget child) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      final available =
          app.canMutate &&
          app.scope == memory.scope &&
          app.memories.any((m) => m.id == memory.id && m.original.isNotEmpty);
      return available
          ? child
          : Scaffold(
              appBar: AppBar(),
              body: const Center(
                child: Text(
                  'This photo is no longer available in this scrapbook.',
                ),
              ),
            );
    },
  );

  Future<void> addPlate({bool automatic = false}) async {
    if (!app.canMutate || app.scope != memory.scope) return;
    if (automatic && !await requestCloudCutouts(context, app)) return;
    if (!mounted) return;
    setState(() => findingPlates = true);
    final sourceRef = selectedOriginal;
    final photoId = selectedPhotoId;
    MediaLease? source;
    await app.media.beginWork(memory.scope, memory.id);
    try {
      source = await app.media.acquire(sourceRef);
      final dir = await app.media.directory(memory.scope, memory.id);
      List<Plate>? added;
      if (automatic && app.engine is MultiSubjectSegmentationEngine) {
        final multi = app.engine as MultiSubjectSegmentationEngine;
        final plates = await multi.subjects(source.file.path, dir.path);
        if (plates.isEmpty) {
          throw StateError(
            'No dishes found. Your existing cutouts have been kept.',
          );
        }
        if (!mounted) return;
        added = plates;
      } else {
        if (!mounted) return;
        added = await Navigator.push<List<Plate>>(
          context,
          MaterialPageRoute(
            builder: (_) => _guardPlateTool(
              PlatePicker(
                original: source!.file.path,
                directory: dir.path,
                engine: app.engine,
                requestCloudUpload: () => requestCloudCutouts(context, app),
                guard: _guardPlateTool,
              ),
            ),
          ),
        );
      }
      if (added != null &&
          added.isNotEmpty &&
          mounted &&
          app.scope == memory.scope &&
          !unavailable) {
        final previous = memory.plates.map((p) => p.copy()).toList();
        for (final plate in added) {
          plate.photoId = photoId;
        }
        final previousOriginal = memory.useOriginal;
        final generatedIds = added.map((p) => p.id).join(',');
        plateChange(() {
          memory.plates = [
            ...memory.plates.where((p) => !automatic || p.photoId != photoId),
            ...added!,
          ];
          selectedPlateId = added.first.id;
          photoChoiceEdited = true;
          memory.useOriginal = false;
        });
        await _persist();
        if (automatic && mounted && !unavailable && app.scope == memory.scope) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${added.length} dishes separated'),
              duration: const Duration(seconds: 10),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () {
                  if (!mounted ||
                      unavailable ||
                      app.scope != memory.scope ||
                      memory.plates.map((p) => p.id).join(',') !=
                          generatedIds) {
                    return;
                  }
                  plateChange(() {
                    memory.plates = previous;
                    memory.useOriginal = previousOriginal;
                    selectedPlateId = previous.firstOrNull?.id;
                    photoChoiceEdited = true;
                  });
                  unawaited(_persist());
                },
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        message(context, e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      await source?.close();
      await app.media.endWork(memory.scope, memory.id);
      if (mounted) setState(() => findingPlates = false);
    }
  }

  Future<void> editPlate() async {
    if (!app.canMutate || app.scope != memory.scope) return;
    final plate = selectedPlate;
    if (plate == null) return;
    final sourceRef = memory.sourceFor(plate);
    MediaLease? source;
    await app.media.beginWork(memory.scope, memory.id);
    try {
      source = await app.media.acquire(sourceRef);
      if (!mounted || app.scope != memory.scope) return;
      final edited = await Navigator.push<Plate>(
        context,
        MaterialPageRoute(
          builder: (_) => _guardPlateTool(
            PlateEdgeEditor(original: source!.file.path, plate: plate),
          ),
        ),
      );
      if (edited == null ||
          !mounted ||
          unavailable ||
          app.scope != memory.scope) {
        return;
      }
      try {
        final dir = await app.media.directory(memory.scope, memory.id);
        final rendered = await renderPlate(source.file.path, dir.path, edited);
        if (!mounted || unavailable || app.scope != memory.scope) return;
        plateChange(
          () => memory.plates = memory.plates
              .map((p) => p.id == rendered.id ? rendered : p)
              .toList(),
        );
        await _persist();
      } catch (e) {
        if (mounted) message(context, 'Could not save the plate: $e');
      }
    } catch (e) {
      if (mounted) {
        message(context, 'Could not open the original. Connect and try again.');
      }
    } finally {
      await source?.close();
      await app.media.endWork(memory.scope, memory.id);
    }
  }

  Future<void> saveMemory() async {
    if (!app.canMutate || app.scope != memory.scope) return;
    debounce?.cancel();
    if (memory.plates.isEmpty && memory.cutout?.isNotEmpty != true) {
      message(
        context,
        'Your draft is saved. Add a plate cutout before finishing.',
      );
      await _persist();
      return;
    }
    final wasDraft = memory.draft;
    memory.draft = false;
    await _persist();
    if (!mounted || !app.canMutate || app.scope != memory.scope) {
      return;
    }
    if (status.startsWith('Could not')) {
      memory.draft = wasDraft;
      message(context, status);
      return;
    }
    await app.repository.event(memory.scope, 'memory_finished', {
      'mealId': memory.id,
      'editingDurationMs': editing.elapsedMilliseconds,
      'usedOriginal': memory.useOriginal,
      'demo': memory.demo,
    });
    if (!mounted) {
      return;
    }
    app.navigate(0);
    message(context, 'Your plates are in the library.');
    Navigator.of(context).pop();
    unawaited(app.sync());
  }

  Future<void> editLater() async {
    if (!app.canMutate || app.scope != memory.scope) return;
    debounce?.cancel();
    await _persist();
    if (!mounted || !app.canMutate || app.scope != memory.scope) return;
    if (status.startsWith('Could not')) {
      message(context, status);
      return;
    }
    app.navigate(2);
    message(context, 'Draft saved. Come back whenever you’re ready.');
    Navigator.of(context).pop();
    unawaited(app.sync());
  }

  Future<void> shareMeal() async {
    if (!memory.ownsMeal || !app.canMutate || app.scope != memory.scope) return;
    if (memory.draft &&
        memory.plates.isEmpty &&
        memory.cutout?.isNotEmpty != true) {
      message(
        context,
        'Add a plate cutout before finishing and sharing this meal.',
      );
      return;
    }
    debounce?.cancel();
    final wasDraft = memory.draft;
    memory.draft = false;
    await _persist();
    if (!mounted || app.scope != memory.scope) return;
    if (status.startsWith('Could not')) {
      memory.draft = wasDraft;
      message(context, status);
      return;
    }
    setState(() {});
    final invited = await showInvite(context, app, memory);
    if (invited != null &&
        mounted &&
        app.scope == memory.scope &&
        !memory.companions.contains(invited)) {
      change(() {
        memory.companions = [...memory.companions, invited];
        companions.text = memory.companions.join(', ');
      });
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    app.removeListener(_processed);
    unawaited(_persist());
    caption.dispose();
    venue.dispose();
    companions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => app.scope != memory.scope || unavailable
      ? Scaffold(
          appBar: AppBar(),
          body: const EmptyState(
            icon: Icons.lock_outline,
            title: 'This memory is no longer in this scrapbook.',
            message: 'Return to History to browse available memories.',
          ),
        )
      : !app.canMutate
      ? BrowseMemory(memory: memory, app: app)
      : Scaffold(
          appBar: AppBar(
            title: const Text(
              'Meal details',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Memory actions',
                onSelected: (v) async {
                  if (v == 'retry-cutouts') {
                    await addPlate(automatic: true);
                  }
                  if (v == 'archive') {
                    debounce?.cancel();
                    memory.archived = !memory.archived;
                    await _persist();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  }
                  if (v == 'leave') {
                    if (!context.mounted) {
                      return;
                    }
                    final confirmed = await confirm(
                      context,
                      'Leave this shared meal?',
                      'You’ll lose access to shared photos. Other people’s memories stay in their scrapbooks.',
                      'Leave meal',
                    );
                    if (confirmed && context.mounted) {
                      await guarded(context, () async {
                        debounce?.cancel();
                        await app.cloud.leave(memory.id);
                        await app.removeLocal(memory);
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      });
                    }
                  }
                  if (v == 'delete') {
                    if (!context.mounted) {
                      return;
                    }
                    final confirmed = await confirm(
                      context,
                      'Delete this meal for everyone?',
                      'Shared details, invitations, and every participant’s memory will be removed. This cannot be undone.',
                      'Delete meal',
                    );
                    if (confirmed && context.mounted) {
                      await guarded(context, () async {
                        debounce?.cancel();
                        if (memory.scope != 'guest' && !memory.demo) {
                          await app.cloud.deleteMeal(memory.id);
                        }
                        await app.removeLocal(memory);
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      });
                    }
                  }
                  if (v == 'photo') {
                    if (!context.mounted) {
                      return;
                    }
                    final confirmed = await confirm(
                      context,
                      'Remove your shared photo?',
                      'This removes your photo for every participant. Captions and meal details remain.',
                      'Remove photo',
                    );
                    if (confirmed && context.mounted) {
                      await guarded(context, () async {
                        debounce?.cancel();
                        await _persist();
                        await app.sync(manual: true);
                        if (app.operations.any((o) => o.entity == memory.id)) {
                          throw StateError(
                            'Finish backup before removing a shared photo.',
                          );
                        }
                        await app.cloud.removeAsset(memory);
                        await app.sync(manual: true);
                        final current = app.memories
                            .where((m) => m.id == memory.id)
                            .firstOrNull;
                        if (current != null && mounted) {
                          setState(() => memory = current.copy());
                        }
                      });
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (app.engine is MultiSubjectSegmentationEngine &&
                      !findingPlates &&
                      memory.job != JobStatus.processing &&
                      memory.job != JobStatus.queued &&
                      memory.original.isNotEmpty)
                    const PopupMenuItem(
                      value: 'retry-cutouts',
                      child: Text('Regenerate plate cutouts'),
                    ),
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(
                      memory.archived
                          ? 'Unarchive memory'
                          : 'Archive my memory',
                    ),
                  ),
                  if (!memory.ownsMeal)
                    const PopupMenuItem(
                      value: 'leave',
                      child: Text('Leave shared meal'),
                    ),
                  if (memory.ownsMeal &&
                      memory.scope != 'guest' &&
                      !memory.demo &&
                      memory.original.isNotEmpty)
                    const PopupMenuItem(
                      value: 'photo',
                      child: Text('Remove my shared photo'),
                    ),
                  if (memory.ownsMeal)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete meal',
                        style: TextStyle(color: Palette.terracotta),
                      ),
                    ),
                ],
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth > 850;
              final preview = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Handwriting(
                    'Keep the plates. Remember the meal.',
                    size: 35,
                    color: Palette.forest,
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: wide ? 440 : 430,
                        maxHeight:
                            memory.plates.isNotEmpty &&
                                !findingPlates &&
                                memory.job != JobStatus.processing &&
                                memory.job != JobStatus.queued
                            ? double.infinity
                            : 440,
                      ),
                      child: CutoutPhoto(
                        interactive: true,
                        job: findingPlates ? JobStatus.processing : memory.job,
                        child:
                            memory.plates.isNotEmpty &&
                                !findingPlates &&
                                memory.job != JobStatus.processing &&
                                memory.job != JobStatus.queued
                            ? PlatePreviewPager(
                                plates: memory.plates,
                                selectedId: selectedPlate?.id,
                                onSelected: (id) =>
                                    setState(() => selectedPlateId = id),
                              )
                            : PlateImage(
                                path:
                                    findingPlates ||
                                        memory.job == JobStatus.processing ||
                                        memory.job == JobStatus.queued
                                    ? selectedOriginal
                                    : selectedPlate?.path ??
                                          memory.cutout ??
                                          memory.original,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _plateControls(),
                  const SizedBox(height: 16),
                  _photoControls(),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      status,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Palette.muted,
                      ),
                    ),
                  ),
                ],
              );
              final controls = _controls();
              return SingleChildScrollView(
                padding: EdgeInsets.all(wide ? 32 : 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1150),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: preview),
                              const SizedBox(width: 48),
                              Expanded(child: controls),
                            ],
                          )
                        : Column(
                            children: [
                              preview,
                              const SizedBox(height: 32),
                              controls,
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: const BoxDecoration(
                color: Palette.paper,
                border: Border(top: BorderSide(color: Palette.line)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    memory.draft
                        ? 'Draft saved on this device. Finish whenever you’re ready.'
                        : 'All edits saved on this device.',
                    style: const TextStyle(fontSize: 12, color: Palette.muted),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (memory.draft)
                        TextButton(
                          onPressed: editLater,
                          child: const Text('Edit later'),
                        ),
                      FilledButton.icon(
                        onPressed: saveMemory,
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Finish & save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
  Widget _label(String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10, top: 22),
    child: Text(
      value,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );
  Future<void> _addPhotos(ImageSource source) async {
    setState(() => addingPhotos = true);
    try {
      debounce?.cancel();
      await _persist();
      // The saved plates are now the repository's baseline for new cutouts.
      platesDirty = false;
      await app.addPhotos(memory, source);
    } catch (e) {
      if (mounted) {
        message(context, e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => addingPhotos = false);
    }
  }

  Widget _photoControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${memory.originals.length} ${memory.originals.length == 1 ? 'photo' : 'photos'} from this meal',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const SizedBox(height: 8),
      const Text(
        'Add every dish or angle from the same visit. Cutouts stay together.',
        style: TextStyle(color: Palette.muted, fontSize: 12),
      ),
      const SizedBox(height: 10),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < memory.originals.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(
                    'Photo ${i + 1}',
                    style: TextStyle(
                      color:
                          selectedPhotoId ==
                              (i == 0 ? null : memory.photos[i - 1].id)
                          ? Colors.white
                          : Palette.ink,
                    ),
                  ),
                  selected:
                      selectedPhotoId ==
                      (i == 0 ? null : memory.photos[i - 1].id),
                  onSelected: (_) => setState(() {
                    selectedPhotoId = i == 0 ? null : memory.photos[i - 1].id;
                  }),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 110,
        width: 150,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: PlateImage(path: selectedOriginal),
        ),
      ),
      for (final photo in memory.photos.where((p) => p.job == JobStatus.failed))
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Photo ${memory.photos.indexOf(photo) + 2}: cutouts could not be created. Select it for manual cleanup or retry.',
            style: const TextStyle(color: Palette.terracotta, fontSize: 12),
          ),
        ),
      if (memory.ownsMeal)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: addingPhotos || findingPlates
                  ? null
                  : () => _addPhotos(ImageSource.gallery),
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(addingPhotos ? 'Adding photos…' : 'Add photos'),
            ),
            TextButton.icon(
              onPressed: addingPhotos || findingPlates
                  ? null
                  : () => _addPhotos(ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined, size: 18),
              label: const Text('Take another photo'),
            ),
            if (memory.photos.any((p) => p.job == JobStatus.failed))
              TextButton.icon(
                onPressed: findingPlates || addingPhotos
                    ? null
                    : () async {
                        if (!await requestCloudCutouts(context, app)) return;
                        await app.retry(memory);
                      },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry failed photos'),
              ),
          ],
        ),
    ],
  );
  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label('A few words'),
      TextField(
        controller: caption,
        maxLength: 160,
        maxLines: 2,
        onChanged: (v) => change(() => memory.caption = v),
        decoration: const InputDecoration(
          hintText: 'What do you want to remember?',
          counterText: '',
        ),
      ),
      _label('How did it feel?'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            [
                  ('happy', '😊'),
                  ('cozy', '☺️'),
                  ('celebratory', '🥳'),
                  ('comforted', '🥰'),
                  ('adventurous', '🤩'),
                ]
                .map(
                  (f) => ChoiceChip(
                    label: Text(
                      '${f.$2} ${f.$1}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: memory.feeling == f.$1
                            ? Colors.white
                            : Palette.ink,
                      ),
                    ),
                    selected: memory.feeling == f.$1,
                    onSelected: (_) => change(() => memory.feeling = f.$1),
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    backgroundColor: Colors.white.withValues(alpha: .5),
                  ),
                )
                .toList(),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          'Would go again',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: const Text(
          'Keep this one close.',
          style: TextStyle(fontSize: 11, color: Palette.muted),
        ),
        value: memory.bookmarked,
        onChanged: (v) => change(() => memory.bookmarked = v!),
      ),
      const Divider(),
      const SizedBox(height: 20),

      _label('Where was it?'),
      TextField(
        controller: venue,
        readOnly: !memory.ownsMeal,
        onChanged: (v) => change(() {
          memory.venue = v;
          memory.placeId = null;
          memory.locationConfirmed = false;
        }),
        decoration: InputDecoration(
          hintText: 'A restaurant, Home, Picnic…',
          prefixIcon: const Icon(Icons.place_outlined, size: 19),
          suffixIcon: memory.ownsMeal
              ? IconButton(
                  tooltip: 'Confirm venue and location',
                  onPressed: () async {
                    await _persist();
                    if (!mounted) {
                      return;
                    }
                    final result = await showVenue(context, app, memory);
                    if (result != null) {
                      change(() {
                        locationEdited = true;
                        memory = result;
                        venue.text = memory.venue;
                      });
                    }
                  },
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 20),
                )
              : null,
        ),
      ),
      if (memory.latitude != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            memory.locationConfirmed
                ? 'Location confirmed · visible on your map'
                : 'Approximate GPS saved · confirm to add it to the map',
            style: const TextStyle(fontSize: 10, color: Palette.muted),
          ),
        ),
      _label('Who was at the table?'),
      TextField(
        controller: companions,
        readOnly: !memory.ownsMeal,
        onChanged: (v) => change(
          () => memory.companions = v
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
        decoration: const InputDecoration(
          hintText: 'Names, separated by commas',
          prefixIcon: Icon(Icons.people_outline, size: 19),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Keep names here, or share the whole meal with someone on morsl.',
        style: TextStyle(fontSize: 10, color: Palette.muted),
      ),
      if (memory.ownsMeal) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: shareMeal,
          icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
          label: Text(
            memory.draft ? 'Finish & share this meal' : 'Share this meal',
          ),
        ),
      ],
      _label('When was this meal?'),
      OutlinedButton.icon(
        onPressed: !memory.ownsMeal
            ? null
            : () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: memory.createdAt,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (date != null && mounted) {
                  change(() {
                    dateEdited = true;
                    memory.createdAt = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      memory.createdAt.hour,
                      memory.createdAt.minute,
                    );
                  });
                }
              },
        icon: const Icon(Icons.calendar_today_outlined, size: 16),
        label: Text(
          DateFormat('EEEE, MMMM d, yyyy').format(memory.createdAt),
          style: const TextStyle(fontSize: 12),
        ),
      ),
      const SizedBox(height: 30),
    ],
  );
  Widget _plateControls() => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (memory.plates.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              app.usesCloudCutouts && !app.cloudCutoutsAllowed
                  ? 'Cloud cutouts are off. Enable them in Settings or use manual cleanup.'
                  : memory.job == JobStatus.failed
                  ? 'Your photo is safe. Retry the cutouts or clean up a plate yourself.'
                  : 'Plate cutouts appear automatically when processing finishes.',
              style: const TextStyle(color: Palette.muted, fontSize: 12),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (memory.plates.isEmpty &&
                memory.job == JobStatus.failed &&
                app.engine is MultiSubjectSegmentationEngine)
              OutlinedButton.icon(
                onPressed: findingPlates || memory.original.isEmpty
                    ? null
                    : () => addPlate(automatic: true),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry cutouts'),
              ),
            if (selectedPlate != null) ...[
              OutlinedButton.icon(
                onPressed: findingPlates ? null : editPlate,
                icon: const Icon(Icons.brush_outlined, size: 18),
                label: const Text('Clean up edges'),
              ),
              TextButton.icon(
                onPressed: findingPlates
                    ? null
                    : () => plateChange(() {
                        final id = selectedPlate!.id;
                        memory.plates = memory.plates
                            .where((plate) => plate.id != id)
                            .toList();
                        selectedPlateId = memory.plates.firstOrNull?.id;
                        if (memory.plates.isEmpty) {
                          photoChoiceEdited = true;
                          memory.useOriginal = true;
                        }
                      }),
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Remove plate'),
              ),
            ],
            if (memory.job != JobStatus.processing &&
                (memory.job != JobStatus.queued ||
                    !app.cloudCutoutsAllowed ||
                    !app.online))
              TextButton.icon(
                onPressed: findingPlates || memory.original.isEmpty
                    ? null
                    : () => addPlate(),
                icon: const Icon(Icons.crop_free, size: 18),
                label: Text(
                  memory.plates.isNotEmpty
                      ? 'Add a missed plate'
                      : 'Manual cleanup',
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
