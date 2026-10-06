import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
    try {
      final dir = await app.media.directory(memory.scope, memory.id);
      List<Plate>? added;
      if (automatic && app.engine is MultiSubjectSegmentationEngine) {
        final multi = app.engine as MultiSubjectSegmentationEngine;
        final plates = await multi.subjects(memory.original, dir.path);
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
                original: memory.original,
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
        final previousOriginal = memory.useOriginal;
        final generatedIds = added.map((p) => p.id).join(',');
        plateChange(() {
          memory.plates = automatic ? added! : [...memory.plates, ...added!];
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
      if (mounted) setState(() => findingPlates = false);
    }
  }

  Future<void> editPlate() async {
    if (!app.canMutate || app.scope != memory.scope) return;
    final plate = selectedPlate;
    if (plate == null) return;
    final edited = await Navigator.push<Plate>(
      context,
      MaterialPageRoute(
        builder: (_) => _guardPlateTool(
          PlateEdgeEditor(original: memory.original, plate: plate),
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
      final rendered = await renderPlate(memory.original, dir.path, edited);
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
  }

  Future<void> saveMemory() async {
    if (!app.canMutate || app.scope != memory.scope) return;
    debounce?.cancel();
    memory.draft = memory.plates.isEmpty && memory.cutout?.isNotEmpty != true;
    await _persist();
    if (!mounted || !app.canMutate || app.scope != memory.scope) {
      return;
    }
    if (status.startsWith('Could not')) {
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
    message(
      context,
      memory.draft
          ? 'Meal details saved. Finish the cutouts in Drafts.'
          : 'Your plates are in the library.',
    );
    Navigator.of(context).pop();
    unawaited(app.sync());
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
              if (!memory.draft && memory.ownsMeal)
                IconButton(
                  onPressed: () async {
                    debounce?.cancel();
                    await _persist();
                    if (context.mounted) {
                      await showInvite(context, app, memory);
                    }
                  },
                  tooltip: 'Invite someone to this meal',
                  icon: const Icon(Icons.person_add_alt_1_outlined, size: 21),
                ),
              PopupMenuButton<String>(
                tooltip: 'Memory actions',
                onSelected: (v) async {
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
                        maxHeight: 440,
                      ),
                      child: CutoutPhoto(
                        job: findingPlates ? JobStatus.processing : memory.job,
                        child: PlateImage(
                          path:
                              findingPlates ||
                                  memory.job == JobStatus.processing ||
                                  memory.job == JobStatus.queued
                              ? memory.original
                              : selectedPlate?.path ??
                                    memory.cutout ??
                                    memory.original,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Center(
                    child: Text(
                      'Plate cutouts will appear in your library.',
                      style: TextStyle(fontSize: 11, color: Palette.muted),
                    ),
                  ),
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
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 15,
                    color: Palette.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Saved locally. Always yours.',
                      style: TextStyle(fontSize: 10, color: Palette.muted),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: saveMemory,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Save to library'),
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
  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label('Plate cutouts'),
      _plateControls(),
      const SizedBox(height: 20),
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
                        color: memory.feeling == f.$1
                            ? Colors.white
                            : Palette.ink,
                      ),
                    ),
                    selected: memory.feeling == f.$1,
                    onSelected: (_) => change(() => memory.feeling = f.$1),
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
        'Names are little labels. Invite an account to share access.',
        style: TextStyle(fontSize: 10, color: Palette.muted),
      ),
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
        if (memory.plates.isNotEmpty) ...[
          Text(
            '${memory.plates.length} separate plates - select one to edit its edges',
            style: const TextStyle(color: Palette.muted, fontSize: 12),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final plate in memory.plates)
                ChoiceChip(
                  label: Text('Plate ${memory.plates.indexOf(plate) + 1}'),
                  selected: selectedPlate?.id == plate.id,
                  onSelected: (_) => change(() {
                    selectedPlateId = plate.id;
                    photoChoiceEdited = true;
                    memory.useOriginal = false;
                  }),
                ),
            ],
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: findingPlates || memory.original.isEmpty
                  ? null
                  : () => addPlate(),
              icon: const Icon(Icons.crop_free, size: 18),
              label: const Text('Select a plate'),
            ),
            TextButton.icon(
              onPressed:
                  findingPlates ||
                      memory.original.isEmpty ||
                      app.engine is! MultiSubjectSegmentationEngine
                  ? null
                  : () => addPlate(automatic: true),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(
                findingPlates ? 'Separating dishes...' : 'Separate dishes',
              ),
            ),
            if (selectedPlate != null) ...[
              TextButton.icon(
                onPressed: findingPlates ? null : editPlate,
                icon: const Icon(Icons.brush_outlined, size: 18),
                label: const Text('Edit edges'),
              ),
              TextButton.icon(
                onPressed: findingPlates
                    ? null
                    : () => plateChange(() {
                        final id = selectedPlate!.id;
                        memory.plates = memory.plates
                            .where((p) => p.id != id)
                            .toList();
                        selectedPlateId = memory.plates.firstOrNull?.id;
                        if (memory.plates.isEmpty) {
                          photoChoiceEdited = true;
                          memory.useOriginal = true;
                        }
                      }),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Remove plate'),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}
