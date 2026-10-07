import 'media_image.dart';
import '../services/media.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/creations.dart';
import 'plate_library.dart';
import 'theme.dart';
import 'tools.dart';

class CompositionEditor extends StatefulWidget {
  const CompositionEditor({
    super.key,
    required this.app,
    this.creation,
    this.initialPlates = const [],
  });
  final MorslController app;
  final PlateCreation? creation;
  final List<LibraryPlate> initialPlates;
  @override
  State<CompositionEditor> createState() => _CompositionEditorState();
}

class _CompositionEditorState extends State<CompositionEditor> {
  final canvasKey = GlobalKey();
  late final String scope;
  late PlateCreation creation;
  late TextEditingController title;
  String? selected;
  bool dirty = false, saving = false, exporting = false, allowPop = false;
  double startScale = 1, startRotation = 0;
  int revision = 0;
  String status = 'Save this photo to keep arranging it later.';

  @override
  void initState() {
    super.initState();
    scope = widget.app.scope;
    creation =
        widget.creation?.copy() ??
        PlateCreation(
          id: const Uuid().v4(),
          updatedAt: DateTime.now(),
          plates: [],
        );
    if (widget.creation == null) {
      for (final entry in widget.initialPlates) {
        _add(entry);
      }
      dirty = true;
    }
    selected = creation.plates.firstOrNull?.key;
    title = TextEditingController(text: creation.title);
    widget.app.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    title.dispose();
    super.dispose();
  }

  bool get authorized => widget.app.canMutate && widget.app.scope == scope;
  bool get busy => saving || exporting;
  List<LibraryPlate> get library =>
      LibraryPlate.fromMemories(widget.app.memories);
  PlacedPlate? get active =>
      creation.plates.where((p) => p.key == selected).firstOrNull;
  void edit(VoidCallback action) {
    if (!authorized || busy) return;
    setState(() {
      action();
      dirty = true;
      revision++;
      status = 'Unsaved changes';
    });
  }

  void _add(LibraryPlate entry) {
    if (creation.plates.any((p) => p.key == entry.key)) return;
    final index = creation.plates.length;
    creation.plates.add(
      PlacedPlate(
        key: entry.key,
        x: .06 + (index % 2) * .46,
        y: .06 + ((index ~/ 2) % 2) * .46,
      ),
    );
    selected = entry.key;
  }

  Future<void> _save() async {
    if (!authorized || busy || creation.plates.isEmpty) return;
    setState(() => saving = true);
    try {
      final snapshot = creation.copy()..updatedAt = DateTime.now();
      final savedRevision = revision;
      await CreationStore(widget.app.repository, scope).save(snapshot);
      if (mounted && authorized && revision == savedRevision) {
        setState(() {
          creation.updatedAt = snapshot.updatedAt;
          dirty = false;
          status = 'Photo saved on this device';
        });
      }
    } catch (e) {
      if (mounted) message(context, 'Could not save this photo: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _export() async {
    if (!authorized || busy) return;
    await _save();
    if (!mounted || !authorized || dirty) return;
    setState(() => exporting = true);
    ui.Image? rendered;
    try {
      final sources = {for (final plate in library) plate.key: plate};
      for (final placed in creation.plates) {
        final source = sources[placed.key];
        if (source == null) throw StateError('A plate is no longer available.');
        Object? loadError;
        if (!mounted || !authorized) return;
        await precacheImage(
          mediaImage(source.path),
          context,
          onError: (error, stack) => loadError = error,
        );
        if (loadError != null) {
          throw StateError('A plate image could not be opened.');
        }
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !authorized) return;
      final boundary =
          canvasKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      rendered = await boundary.toImage(pixelRatio: 1600 / boundary.size.width);
      final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Photo could not be rendered.');
      final directory = await widget.app.media.directory(scope, 'exports');
      final file = File(p.join(directory.path, 'morsl-${creation.id}.png'));
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      if (mounted && authorized) {
        setState(
          () => status = 'Photo exported. Your editable version is saved.',
        );
        await shareFile(context, file.path, creation.title);
      }
    } catch (e) {
      if (mounted) message(context, 'Could not export this photo: $e');
    } finally {
      rendered?.dispose();
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> _pick() async {
    final items = library
        .where((p) => !creation.plates.any((placed) => placed.key == p.key))
        .toList();
    final entry = await showModalBottomSheet<LibraryPlate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Add a plate',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (items.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text('All your plates are in this photo.'),
                  ),
                )
              else
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 230,
                          mainAxisExtent: 300,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                    itemCount: items.length,
                    itemBuilder: (_, i) => PlateTile(
                      plate: items[i],
                      onTap: () => Navigator.pop(context, items[i]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (entry != null && mounted) edit(() => _add(entry));
  }

  Future<void> _leave(bool didPop, Object? result) async {
    if (didPop || busy) return;
    if (!dirty ||
        !authorized ||
        await confirm(
          context,
          'Leave without saving?',
          'Your latest arrangement changes will be lost.',
          'Leave',
        )) {
      if (!mounted) return;
      setState(() => allowPop = true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = {for (final plate in library) plate.key: plate};
    final missing = creation.plates
        .where(
          (plate) =>
              entries[plate.key] == null ||
              (!MediaStore.isRemote(entries[plate.key]!.path) &&
                  !File(entries[plate.key]!.path).existsSync()),
        )
        .toList();
    final plate = active;
    final preview = AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, c) {
          final side = c.maxWidth;
          return Stack(
            children: [
              RepaintBoundary(
                key: canvasKey,
                child: ClipRect(
                  child: ColoredBox(
                    color: Palette.background(creation.background),
                    child: SizedBox.expand(
                      child: Stack(
                        children: [
                          for (final placed in creation.plates)
                            if (entries[placed.key] case final entry?)
                              Positioned(
                                left: placed.x * side,
                                top: placed.y * side,
                                width: placed.scale * side,
                                height: placed.scale * side,
                                child: Transform.rotate(
                                  angle: placed.rotation,
                                  child: GestureDetector(
                                    onTap: !authorized || busy
                                        ? null
                                        : () => setState(
                                            () => selected = placed.key,
                                          ),
                                    onScaleStart: !authorized || busy
                                        ? null
                                        : (_) {
                                            setState(
                                              () => selected = placed.key,
                                            );
                                            startScale = placed.scale;
                                            startRotation = placed.rotation;
                                          },
                                    onScaleUpdate: !authorized || busy
                                        ? null
                                        : (details) => edit(() {
                                            placed.scale =
                                                (startScale * details.scale)
                                                    .clamp(.12, .9);
                                            placed.x =
                                                (placed.x +
                                                        details
                                                                .focalPointDelta
                                                                .dx /
                                                            side)
                                                    .clamp(0, 1 - placed.scale);
                                            placed.y =
                                                (placed.y +
                                                        details
                                                                .focalPointDelta
                                                                .dy /
                                                            side)
                                                    .clamp(0, 1 - placed.scale);
                                            placed.rotation =
                                                (startRotation +
                                                        details.rotation)
                                                    .clamp(-math.pi, math.pi);
                                          }),
                                    child: PlateImage(path: entry.path),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (!exporting && plate != null && entries.containsKey(plate.key))
                Positioned(
                  left: plate.x * side,
                  top: plate.y * side,
                  width: plate.scale * side,
                  height: plate.scale * side,
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: plate.rotation,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Palette.forest),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    return PopScope(
      canPop: allowPop || (!dirty && !busy),
      onPopInvokedWithResult: _leave,
      child: Scaffold(
        appBar: AppBar(title: const Text('Arrange plates')),
        body: !authorized
            ? const EmptyState(
                icon: Icons.lock_outline,
                title: 'This photo belongs to your library.',
                message: 'Sign in to that account to continue editing.',
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final controls = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: title,
                              enabled: !busy,
                              maxLength: 80,
                              decoration: const InputDecoration(
                                labelText: 'Photo name',
                              ),
                              onChanged: (v) => edit(
                                () => creation.title = v.trim().isEmpty
                                    ? 'My plate photo'
                                    : v.trim(),
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: busy ? null : _pick,
                              icon: const Icon(Icons.add),
                              label: const Text('Add from library'),
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              'Background',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 10,
                              children: [
                                for (final background in [
                                  'cream',
                                  'sage',
                                  'rose',
                                  'sand',
                                ])
                                  Semantics(
                                    label: '$background background',
                                    selected: creation.background == background,
                                    button: true,
                                    child: InkWell(
                                      onTap: busy
                                          ? null
                                          : () => edit(
                                              () => creation.background =
                                                  background,
                                            ),
                                      borderRadius: BorderRadius.circular(24),
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: Palette.background(background),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color:
                                                creation.background ==
                                                    background
                                                ? Palette.forest
                                                : Palette.line,
                                          ),
                                        ),
                                        child: creation.background == background
                                            ? const Icon(Icons.check, size: 20)
                                            : null,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            const Text(
                              'Plates in this photo',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final placed in creation.plates)
                                  InputChip(
                                    label: Text(
                                      entries[placed.key]?.title ??
                                          'Unavailable plate',
                                    ),
                                    selected: selected == placed.key,
                                    labelStyle: TextStyle(
                                      color: selected == placed.key
                                          ? Colors.white
                                          : Palette.ink,
                                    ),
                                    deleteIconColor: selected == placed.key
                                        ? Colors.white
                                        : Palette.ink,
                                    onPressed: busy
                                        ? null
                                        : () => setState(
                                            () => selected = placed.key,
                                          ),
                                    onDeleted: busy
                                        ? null
                                        : () => edit(() {
                                            creation.plates.remove(placed);
                                            selected = creation
                                                .plates
                                                .firstOrNull
                                                ?.key;
                                          }),
                                  ),
                              ],
                            ),
                            if (missing.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  '${missing.length} plate cutouts are unavailable. Remove them before exporting.',
                                  style: const TextStyle(
                                    color: Palette.terracotta,
                                  ),
                                ),
                              ),
                            if (creation.plates.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 16),
                                child: Text(
                                  'Add a plate from your library to start arranging.',
                                ),
                              ),
                            if (plate != null) ...[
                              const SizedBox(height: 16),
                              _slider(
                                'Horizontal position',
                                plate.x,
                                0,
                                1 - plate.scale,
                                (v) => plate.x = v,
                              ),
                              _slider(
                                'Vertical position',
                                plate.y,
                                0,
                                1 - plate.scale,
                                (v) => plate.y = v,
                              ),
                              _slider('Size', plate.scale, .12, .9, (v) {
                                plate.scale = v;
                                plate.x = plate.x.clamp(0, 1 - v);
                                plate.y = plate.y.clamp(0, 1 - v);
                              }),
                              _slider(
                                'Rotation',
                                plate.rotation,
                                -math.pi,
                                math.pi,
                                (v) => plate.rotation = v,
                              ),
                              TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => edit(() {
                                        creation.plates.remove(plate);
                                        creation.plates.add(plate);
                                      }),
                                icon: const Icon(Icons.flip_to_front),
                                label: const Text('Bring to front'),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Text(
                              status,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Palette.muted,
                              ),
                            ),
                          ],
                        );
                        final canvas = Column(
                          children: [
                            preview,
                            const SizedBox(height: 12),
                            const Text(
                              'Drag a plate. Pinch to resize and rotate.',
                              style: TextStyle(color: Palette.muted),
                            ),
                            const SizedBox(height: 24),
                          ],
                        );
                        return constraints.maxWidth > 800
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: canvas),
                                  const SizedBox(width: 32),
                                  Expanded(flex: 2, child: controls),
                                ],
                              )
                            : Column(children: [canvas, controls]);
                      },
                    ),
                  ),
                ),
              ),
        bottomNavigationBar: !authorized
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy || creation.plates.isEmpty
                            ? null
                            : _save,
                        child: Text(saving ? 'Saving…' : 'Save photo'),
                      ),
                      FilledButton.icon(
                        onPressed:
                            busy ||
                                creation.plates.isEmpty ||
                                missing.isNotEmpty
                            ? null
                            : _export,
                        icon: const Icon(Icons.ios_share),
                        label: Text(exporting ? 'Exporting…' : 'Export photo'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: busy ? null : (v) => edit(() => change(v)),
      ),
    ],
  );
}
