import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/media.dart';
import '../services/plates.dart';
import 'plate_tools.dart';
import 'theme.dart';
import 'memory_card.dart';
import 'tools.dart';

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
  bool showPosition = false;
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
    memory = widget.memory.copy();
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
          memory.useOriginal = current.useOriginal;
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
    if (app.scope != memory.scope) {
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
    final snapshot = memory.copy();
    final didDateEdit = dateEdited, didLocationEdit = locationEdited;
    final didPlateEdit = platesDirty, didPhotoEdit = photoChoiceEdited;
    saving = saving
        .catchError((Object _) {})
        .then((_) async {
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
            if (didPhotoEdit) current.useOriginal = snapshot.useOriginal;
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
    debounce?.cancel();
    memory.draft = false;
    await _persist();
    if (!mounted) {
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
    message(context, 'A little memory, kept.');
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
      : Scaffold(
          appBar: AppBar(
            title: const Text(
              'Plating',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              IconButton(
                onPressed: () async {
                  debounce?.cancel();
                  await _persist();
                  if (!context.mounted) {
                    return;
                  }
                  await showEvaluation(context, app, memory);
                  final current = app.memories
                      .where((m) => m.id == memory.id)
                      .firstOrNull;
                  if (current != null && mounted) {
                    setState(() {
                      memory.useOriginal = current.useOriginal;
                      memory.rating = current.rating;
                      memory.failureCategory = current.failureCategory;
                    });
                  }
                },
                tooltip: 'Evaluate cutout',
                icon: const Icon(Icons.auto_awesome_outlined, size: 21),
              ),
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
                  const Eyebrow('A little moment, your way'),
                  const SizedBox(height: 10),
                  const Handwriting(
                    'Make yourself a memory.',
                    size: 35,
                    color: Palette.forest,
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: wide ? 440 : 430),
                      child: AspectRatio(
                        aspectRatio: .91,
                        child: MemoryCanvas(
                          memory: memory,
                          selectedPlate: selectedPlate?.id,
                          onPlateSelected: (id) =>
                              setState(() => selectedPlateId = id),
                          onPlateTransform: (id, x, y, s, r) => plateChange(() {
                            selectedPlateId = id;
                            final plate = memory.plates.firstWhere(
                              (p) => p.id == id,
                            );
                            plate.x = x;
                            plate.y = y;
                            plate.scale = s;
                            plate.rotation = r;
                          }),
                          onTransform: (x, y, s, r) => change(() {
                            memory.x = x;
                            memory.y = y;
                            memory.scale = s;
                            memory.rotation = r;
                          }),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Center(
                    child: Text(
                      'Drag, pinch, or use the position controls below.',
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
                    label: const Text('Save memory'),
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
      const Eyebrow('01 / Set the table'),
      _label('Layout'),
      Row(
        children: ['classic', 'postcard', 'centered']
            .map(
              (l) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton(
                    onPressed: () => change(() {
                      memory.layout = l;
                      memory.x = 0;
                      memory.y = 0;
                      memory.scale = l == 'centered' ? .82 : 1;
                      memory.rotation = 0;
                    }),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: memory.layout == l ? Palette.sage : null,
                      side: BorderSide(
                        color: memory.layout == l
                            ? Palette.forest
                            : Palette.line,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 12,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          l == 'classic'
                              ? Icons.photo_outlined
                              : l == 'postcard'
                              ? Icons.web_asset_outlined
                              : Icons.filter_center_focus,
                          size: 22,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          l[0].toUpperCase() + l.substring(1),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
      _label('Paper background'),
      Wrap(
        spacing: 12,
        children: ['cream', 'sage', 'rose', 'sand']
            .map(
              (b) => Semantics(
                label: '$b paper',
                selected: memory.background == b,
                button: true,
                child: InkWell(
                  onTap: () => change(() => memory.background = b),
                  borderRadius: BorderRadius.circular(30),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Palette.background(b),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: memory.background == b
                            ? Palette.forest
                            : Palette.line,
                        width: memory.background == b ? 2 : 1,
                      ),
                    ),
                    child: memory.background == b
                        ? const Icon(
                            Icons.check,
                            size: 18,
                            color: Palette.forest,
                          )
                        : null,
                  ),
                ),
              ),
            )
            .toList(),
      ),
      _label('Your photo'),
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: Text(
              'Original photo',
              style: TextStyle(
                color: !memory.displaysCutout ? Colors.white : Palette.ink,
              ),
            ),
            selected: !memory.displaysCutout,
            onSelected: (_) => change(() {
              photoChoiceEdited = true;
              memory.useOriginal = true;
            }),
          ),
          ChoiceChip(
            label: Text(
              memory.cutout == null && memory.plates.isEmpty
                  ? 'Cutout not ready'
                  : 'Food cutouts',
              style: TextStyle(
                color: memory.cutout == null && memory.plates.isEmpty
                    ? Palette.muted
                    : memory.displaysCutout
                    ? Colors.white
                    : Palette.ink,
              ),
            ),
            selected: memory.displaysCutout,
            onSelected: memory.cutout == null && memory.plates.isEmpty
                ? null
                : (_) => change(() {
                    photoChoiceEdited = true;
                    memory.useOriginal = false;
                  }),
          ),
        ],
      ),
      if (memory.job == JobStatus.failed)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'Select a missed plate below. You can edit its edges offline.',
            style: const TextStyle(fontSize: 11, color: Palette.muted),
          ),
        ),
      _plateControls(),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: () => setState(() => showPosition = !showPosition),
            icon: const Icon(Icons.tune, size: 16),
            label: const Text(
              'Position controls',
              style: TextStyle(fontSize: 11),
            ),
          ),
          TextButton(
            onPressed: () {
              final plate = selectedPlate;
              if (plate != null) {
                plateChange(() {
                  plate.x = .2;
                  plate.y = .15;
                  plate.scale = .6;
                  plate.rotation = 0;
                });
              } else {
                change(() {
                  memory.x = 0;
                  memory.y = 0;
                  memory.scale = 1;
                  memory.rotation = 0;
                });
              }
            },
            child: const Text('Reset layout', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
      if (showPosition && selectedPlate != null) ...[
        _slider('Plate horizontal position', selectedPlate!.x, -.5, 1, (v) {
          platesDirty = true;
          selectedPlate!.x = v;
        }),
        _slider('Plate vertical position', selectedPlate!.y, -.5, 1, (v) {
          platesDirty = true;
          selectedPlate!.y = v;
        }),
        _slider('Plate size', selectedPlate!.scale, .15, 1.4, (v) {
          platesDirty = true;
          selectedPlate!.scale = v;
        }),
        _slider('Plate rotation', selectedPlate!.rotation, -math.pi, math.pi, (
          v,
        ) {
          platesDirty = true;
          selectedPlate!.rotation = v;
        }),
      ] else if (showPosition) ...[
        _slider(
          'Horizontal position',
          memory.x,
          -.35,
          .35,
          (v) => memory.x = v,
        ),
        _slider('Vertical position', memory.y, -.35, .35, (v) => memory.y = v),
        _slider('Image scale', memory.scale, .4, 1.6, (v) => memory.scale = v),
        _slider(
          'Image rotation',
          memory.rotation,
          -math.pi,
          math.pi,
          (v) => memory.rotation = v,
        ),
      ],
      const SizedBox(height: 22),
      const Divider(),
      const SizedBox(height: 20),
      const Eyebrow('02 / Keep the feeling'),
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
      const Eyebrow('03 / Remember the details'),
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
            '${memory.plates.length} separate plates - select one to move or edit',
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

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) set,
  ) => Row(
    children: [
      SizedBox(
        width: 112,
        child: Text(
          label,
          style: const TextStyle(fontSize: 10, color: Palette.muted),
        ),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: value.toStringAsFixed(2),
          onChanged: (v) => change(() => set(v)),
        ),
      ),
    ],
  );
}
