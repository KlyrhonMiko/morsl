import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/models.dart';
import '../services/media.dart';
import '../services/plates.dart';
import 'theme.dart';

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Review model suggestions before adding them; each remains an independent mask.
class PlateSuggestions extends StatefulWidget {
  const PlateSuggestions({super.key, required this.plates});
  final List<Plate> plates;
  @override
  State<PlateSuggestions> createState() => _PlateSuggestionsState();
}

class _PlateSuggestionsState extends State<PlateSuggestions> {
  late final Set<String> selected = widget.plates.map((p) => p.id).toSet();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review plates')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Keep the plates you want. If two dishes are joined, select each one from the original photo instead.',
        ),
        const SizedBox(height: 16),
        for (final plate in widget.plates)
          Card(
            child: Column(
              children: [
                SizedBox(
                  height: 180,
                  width: double.infinity,
                  child: ColoredBox(
                    color: Palette.background('sage'),
                    child: Image.file(File(plate.path), fit: BoxFit.contain),
                  ),
                ),
                CheckboxListTile(
                  title: Text('Plate ${widget.plates.indexOf(plate) + 1}'),
                  value: selected.contains(plate.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      selected.add(plate.id);
                    } else {
                      selected.remove(plate.id);
                    }
                  }),
                ),
              ],
            ),
          ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  widget.plates.where((p) => selected.contains(p.id)).toList(),
                ),
          child: const Text('Add selected plates'),
        ),
      ),
    ),
  );
}

class PlatePicker extends StatefulWidget {
  const PlatePicker({
    super.key,
    required this.original,
    required this.directory,
    required this.engine,
    this.guard,
    this.requestCloudUpload,
  });
  final String original, directory;
  final SegmentationEngine engine;
  final Widget Function(Widget child)? guard;
  final Future<bool> Function()? requestCloudUpload;
  @override
  State<PlatePicker> createState() => _PlatePickerState();
}

class _PlatePickerState extends State<PlatePicker> {
  ui.Image? photo;
  Rect selection = const Rect.fromLTWH(.1, .1, .8, .8);
  Offset? start;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final image = await _decode(
        await compute(plateRegionBytes, {'original': widget.original}),
      );
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => photo = image);
    } catch (e) {
      if (mounted) setState(() => error = 'Could not open this photo: $e');
    }
  }

  Plate get region => Plate(
    id: const Uuid().v4(),
    mask: solidPlateMask(),
    left: selection.left,
    top: selection.top,
    width: selection.width,
    height: selection.height,
    aspect: selection.width * photo!.width / (selection.height * photo!.height),
  );
  Future<void> _select(bool automatic) async {
    if (automatic &&
        widget.engine is RemoteSegmentationEngine &&
        widget.requestCloudUpload != null &&
        !await widget.requestCloudUpload!()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      List<Plate>? added;
      if (automatic && widget.engine is MultiSubjectSegmentationEngine) {
        final multi = widget.engine as MultiSubjectSegmentationEngine;
        final plates = await multi.subjects(
          widget.original,
          widget.directory,
          region: region,
        );
        if (plates.isEmpty) {
          throw StateError(
            'No plate found here. Try editing this selection by hand.',
          );
        }
        if (!mounted) return;
        added = await Navigator.push<List<Plate>>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                widget.guard?.call(PlateSuggestions(plates: plates)) ??
                PlateSuggestions(plates: plates),
          ),
        );
      } else {
        if (!mounted) return;
        final edited = await Navigator.push<Plate>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                widget.guard?.call(
                  PlateEdgeEditor(original: widget.original, plate: region),
                ) ??
                PlateEdgeEditor(original: widget.original, plate: region),
          ),
        );
        if (edited != null) {
          added = [
            await renderPlate(widget.original, widget.directory, edited),
          ];
        }
      }
      if (added != null && mounted) Navigator.pop(context, added);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    photo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Select a plate')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Drag a box around one plate, including its rim. You can repeat this for every dish.',
            ),
          ),
          Expanded(
            child: photo == null
                ? Center(
                    child: error == null
                        ? const CircularProgressIndicator()
                        : Text(error!),
                  )
                : Center(
                    child: AspectRatio(
                      aspectRatio: photo!.width / photo!.height,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          Offset point(Offset p) => Offset(
                            (p.dx / constraints.maxWidth).clamp(0, 1),
                            (p.dy / constraints.maxHeight).clamp(0, 1),
                          );
                          void update(Offset p) => setState(
                            () => selection = Rect.fromPoints(start!, point(p)),
                          );
                          return GestureDetector(
                            key: const ValueKey('plate-selection-canvas'),
                            onPanStart: busy
                                ? null
                                : (d) {
                                    start = point(d.localPosition);
                                    update(d.localPosition);
                                  },
                            onPanUpdate: busy
                                ? null
                                : (d) => update(d.localPosition),
                            child: CustomPaint(
                              painter: _SelectionPainter(photo!, selection),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
          if (error != null && photo != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: const TextStyle(color: Palette.terracotta),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed:
                      busy || photo == null || selection.shortestSide < .01
                      ? null
                      : () => _select(false),
                  child: const Text('Edit selection by hand'),
                ),
                FilledButton(
                  onPressed:
                      busy ||
                          photo == null ||
                          selection.shortestSide < .01 ||
                          widget.engine is! MultiSubjectSegmentationEngine
                      ? null
                      : () => _select(true),
                  child: Text(busy ? 'Finding plate…' : 'Find in selection'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.photo, this.selection);
  final ui.Image photo;
  final Rect selection;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawImageRect(
      photo,
      Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()),
      rect,
      Paint(),
    );
    final box = Rect.fromLTWH(
      selection.left * size.width,
      selection.top * size.height,
      selection.width * size.width,
      selection.height * size.height,
    );
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        Path()..addRect(box),
      ),
      Paint()..color = Colors.black.withValues(alpha: .55),
    );
    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.selection != selection || old.photo != photo;
}

class MaskStroke {
  MaskStroke({required this.erase, required this.width, required this.points});
  final bool erase;
  final double width;
  final List<Offset> points;
}

/// Paint alpha only. Restore always reveals the original pixels.
void paintMask(
  Canvas canvas,
  Size size,
  ui.Image mask,
  List<MaskStroke> strokes,
) {
  canvas.drawImageRect(
    mask,
    Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
    Offset.zero & size,
    Paint(),
  );
  for (final stroke in strokes) {
    final paint = Paint()
      ..color = Colors.white
      ..blendMode = stroke.erase ? BlendMode.clear : BlendMode.src
      ..strokeWidth = stroke.width * size.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    if (stroke.points.isEmpty) continue;
    final path = Path();
    final first = stroke.points.first;
    path.moveTo(first.dx * size.width, first.dy * size.height);
    for (final point in stroke.points.skip(1)) {
      path.lineTo(point.dx * size.width, point.dy * size.height);
    }
    if (stroke.points.length == 1) {
      canvas.drawCircle(
        Offset(first.dx * size.width, first.dy * size.height),
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
    } else {
      canvas.drawPath(path, paint);
    }
  }
}

class PlateEdgeEditor extends StatefulWidget {
  const PlateEdgeEditor({
    super.key,
    required this.original,
    required this.plate,
  });
  final String original;
  final Plate plate;
  @override
  State<PlateEdgeEditor> createState() => _PlateEdgeEditorState();
}

class _PlateEdgeEditorState extends State<PlateEdgeEditor> {
  ui.Image? photo, mask;
  final strokes = <MaskStroke>[], redo = <MaskStroke>[];
  bool erase = true, zoom = false, saving = false;
  double brush = .05;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rgb = await _decode(
        await compute(plateRegionBytes, {
          'original': widget.original,
          'region': widget.plate.toJson(),
          'limit': 1200,
        }),
      );
      final alpha = await _decode(base64Decode(widget.plate.mask));
      if (!mounted) {
        rgb.dispose();
        alpha.dispose();
        return;
      }
      setState(() {
        photo = rgb;
        mask = alpha;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Could not open the plate edges: $e');
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final w = math.max(
        1,
        (photo!.width *
                math.min(1, 768 / math.max(photo!.width, photo!.height)))
            .round(),
      );
      final h = math.max(1, (w * photo!.height / photo!.width).round());
      final recorder = ui.PictureRecorder();
      paintMask(
        Canvas(recorder),
        Size(w.toDouble(), h.toDouble()),
        mask!,
        strokes,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final plate = widget.plate.copy()
        ..mask = base64Encode(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        )
        ..aspect = photo!.width / photo!.height;
      if (mounted) Navigator.pop(context, plate);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Could not save the edges: $e';
          saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    photo?.dispose();
    mask?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Edit plate edges'),
      actions: [
        IconButton(
          tooltip: 'Undo brush stroke',
          onPressed: strokes.isEmpty || saving
              ? null
              : () => setState(() => redo.add(strokes.removeLast())),
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: 'Redo brush stroke',
          onPressed: redo.isEmpty || saving
              ? null
              : () => setState(() => strokes.add(redo.removeLast())),
          icon: const Icon(Icons.redo),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Erase the table around the plate. Restore brings back pixels from the original photo. Pinch to zoom in Zoom mode.',
            ),
          ),
          Expanded(
            child: photo == null || mask == null
                ? Center(
                    child: error == null
                        ? const CircularProgressIndicator()
                        : Text(error!),
                  )
                : InteractiveViewer(
                    panEnabled: zoom,
                    scaleEnabled: zoom,
                    maxScale: 5,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: photo!.width / photo!.height,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            Offset point(Offset p) => Offset(
                              (p.dx / constraints.maxWidth).clamp(0, 1),
                              (p.dy / constraints.maxHeight).clamp(0, 1),
                            );
                            return GestureDetector(
                              key: const ValueKey('plate-edge-canvas'),
                              onPanStart: zoom || saving
                                  ? null
                                  : (d) => setState(() {
                                      redo.clear();
                                      strokes.add(
                                        MaskStroke(
                                          erase: erase,
                                          width: brush,
                                          points: [point(d.localPosition)],
                                        ),
                                      );
                                    }),
                              onPanUpdate: zoom || saving
                                  ? null
                                  : (d) => setState(
                                      () => strokes.last.points.add(
                                        point(d.localPosition),
                                      ),
                                    ),
                              onTapUp: zoom || saving
                                  ? null
                                  : (d) => setState(() {
                                      redo.clear();
                                      strokes.add(
                                        MaskStroke(
                                          erase: erase,
                                          width: brush,
                                          points: [point(d.localPosition)],
                                        ),
                                      );
                                    }),
                              child: CustomPaint(
                                painter: _EdgePainter(
                                  photo!,
                                  mask!,
                                  List.of(strokes),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
          ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Erase'),
                      selected: erase && !zoom,
                      onSelected: saving
                          ? null
                          : (_) => setState(() {
                              erase = true;
                              zoom = false;
                            }),
                    ),
                    ChoiceChip(
                      label: const Text('Restore'),
                      selected: !erase && !zoom,
                      onSelected: saving
                          ? null
                          : (_) => setState(() {
                              erase = false;
                              zoom = false;
                            }),
                    ),
                    ChoiceChip(
                      label: const Text('Zoom'),
                      selected: zoom,
                      onSelected: saving
                          ? null
                          : (v) => setState(() => zoom = v),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Text('Brush size'),
                    Expanded(
                      child: Slider(
                        value: brush,
                        min: .01,
                        max: .2,
                        semanticFormatterCallback: (v) =>
                            '${(v * 100).round()} percent',
                        onChanged: saving
                            ? null
                            : (v) => setState(() => brush = v),
                      ),
                    ),
                  ],
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: saving || mask == null ? null : _save,
                    child: Text(saving ? 'Saving…' : 'Keep these edges'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.photo, this.mask, this.strokes);
  final ui.Image photo, mask;
  final List<MaskStroke> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    for (var y = 0.0; y < size.height; y += 16) {
      for (var x = 0.0; x < size.width; x += 16) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, 16, 16).intersect(rect),
          Paint()
            ..color = ((x ~/ 16 + y ~/ 16) % 2 == 0
                ? const Color(0xfff0f0e9)
                : const Color(0xffd3d7cc)),
        );
      }
    }
    canvas.saveLayer(rect, Paint());
    canvas.drawImageRect(
      photo,
      Rect.fromLTWH(0, 0, photo.width.toDouble(), photo.height.toDouble()),
      rect,
      Paint(),
    );
    canvas.saveLayer(rect, Paint()..blendMode = BlendMode.dstIn);
    paintMask(canvas, size, mask, strokes);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}
