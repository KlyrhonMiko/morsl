import 'media_image.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import 'theme.dart';
import 'cutout_status.dart';

class MemoryCanvas extends StatefulWidget {
  const MemoryCanvas({
    super.key,
    required this.memory,
    this.preview = false,
    this.onTransform,
    this.selectedPlate,
    this.onPlateSelected,
    this.onPlateTransform,
  });
  final Memory memory;
  final bool preview;
  final void Function(double x, double y, double scale, double rotation)?
  onTransform;
  final String? selectedPlate;
  final ValueChanged<String>? onPlateSelected;
  final void Function(
    String id,
    double x,
    double y,
    double scale,
    double rotation,
  )?
  onPlateTransform;
  @override
  State<MemoryCanvas> createState() => _MemoryCanvasState();
}

class _MemoryCanvasState extends State<MemoryCanvas> {
  double _startScale = 1, _startRotation = 0;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final memory = widget.memory;
      final preview = widget.preview;
      final onTransform = widget.onTransform;
      final w = c.maxWidth;
      final h = c.maxHeight;
      final unit = w / 360;
      final compact = memory.layout == 'postcard';
      final cutout = memory.displaysCutout;
      final centered = memory.layout == 'centered';
      final imageHeight = h * (cutout ? .62 : .54);
      final photo = memory.displayPath;
      final Widget image = photo.isEmpty
          ? const Center(
              child: Text(
                'Photo removed by its contributor',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Palette.muted),
              ),
            )
          : Image(
              image: ResizeImage.resizeIfNeeded(
                preview ? 700 : null,
                null,
                mediaImage(
                  preview && !cutout ? memory.thumbnail ?? photo : photo,
                ),
              ),
              fit: BoxFit.contain,

              errorBuilder: (c, e, s) => const Center(
                child: Icon(
                  Icons.restaurant_outlined,
                  size: 48,
                  color: Palette.muted,
                ),
              ),
            );
      return MediaQuery.withNoTextScaling(
        child: Semantics(
          image: true,
          label:
              '${memory.title}, ${memory.venue}, ${DateFormat('MMM d, yyyy').format(memory.createdAt)}',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Palette.background(memory.background),
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PaperPainter(memory.background),
                    ),
                  ),
                  Positioned(
                    top: 20 * unit,
                    left: 22 * unit,
                    child: Eyebrow(
                      DateFormat('MMM d, yyyy').format(memory.createdAt),
                    ),
                  ),
                  Positioned(
                    top: 15,
                    right: 16,
                    child: Icon(
                      memory.bookmarked
                          ? Icons.bookmark_rounded
                          : Icons.auto_awesome_outlined,
                      size: 19,
                      color: Palette.forest,
                    ),
                  ),
                  if (cutout && memory.plates.isNotEmpty)
                    for (final plate in memory.plates)
                      Positioned(
                        left: plate.x * w,
                        top: plate.y * h,
                        width: plate.scale * w,
                        height: plate.scale * w / plate.aspect,
                        child: Transform.rotate(
                          angle: plate.rotation,
                          child: GestureDetector(
                            onTap: widget.onPlateSelected == null
                                ? null
                                : () => widget.onPlateSelected!(plate.id),
                            onScaleStart: widget.onPlateTransform == null
                                ? null
                                : (_) {
                                    widget.onPlateSelected?.call(plate.id);
                                    _startScale = plate.scale;
                                    _startRotation = plate.rotation;
                                  },
                            onScaleUpdate: widget.onPlateTransform == null
                                ? null
                                : (d) => widget.onPlateTransform!(
                                    plate.id,
                                    (plate.x + d.focalPointDelta.dx / w).clamp(
                                      -.5,
                                      1,
                                    ),
                                    (plate.y + d.focalPointDelta.dy / h).clamp(
                                      -.5,
                                      1,
                                    ),
                                    (_startScale * d.scale).clamp(.15, 1.4),
                                    (_startRotation + d.rotation).clamp(
                                      -math.pi,
                                      math.pi,
                                    ),
                                  ),
                            child: Semantics(
                              label:
                                  'Plate ${memory.plates.indexOf(plate) + 1}',
                              child: Container(
                                decoration: widget.selectedPlate == plate.id
                                    ? BoxDecoration(
                                        border: Border.all(
                                          color: Palette.forest.withValues(
                                            alpha: .4,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      )
                                    : null,
                                child: Image(
                                  image: ResizeImage.resizeIfNeeded(
                                    preview ? 700 : null,
                                    null,
                                    mediaImage(plate.path),
                                  ),
                                  fit: BoxFit.contain,

                                  errorBuilder: (c, e, s) => const Center(
                                    child: Icon(Icons.restaurant_outlined),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  if (!cutout || memory.plates.isEmpty)
                    Positioned(
                      left: w * (compact ? .08 : .1) + memory.x * w,
                      top: h * (centered ? .12 : .13) + memory.y * h,
                      width: w * (compact ? .84 : .8),
                      height: imageHeight,
                      child: Transform.rotate(
                        angle: memory.rotation + (compact ? -.045 : 0),
                        child: Transform.scale(
                          scale: memory.scale,
                          child: GestureDetector(
                            onScaleStart: onTransform == null
                                ? null
                                : (_) {
                                    _startScale = memory.scale;
                                    _startRotation = memory.rotation;
                                  },
                            onScaleUpdate: onTransform == null
                                ? null
                                : (d) {
                                    onTransform(
                                      (memory.x + d.focalPointDelta.dx / w)
                                          .clamp(-.35, .35),
                                      (memory.y + d.focalPointDelta.dy / h)
                                          .clamp(-.35, .35),
                                      (_startScale * d.scale).clamp(.4, 1.6),
                                      (_startRotation + d.rotation).clamp(
                                        -math.pi,
                                        math.pi,
                                      ),
                                    );
                                  },
                            child: cutout
                                ? image
                                : ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: image,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    bottom: 24 * unit,
                    left: 24 * unit,
                    right: 24 * unit,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Handwriting(
                          memory.caption.isEmpty
                              ? 'A little bite of today.'
                              : memory.caption,
                          size: (compact ? 26.0 : 28.0) * unit,
                          maxLines: 2,
                          align: TextAlign.center,
                        ),
                        if (memory.venue.isNotEmpty) ...[
                          const SizedBox(height: 9),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.place_outlined,
                                size: 13,
                                color: Palette.muted,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  memory.venue,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Palette.muted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class PaperPainter extends CustomPainter {
  PaperPainter(this.kind);
  final String kind;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.ink.withValues(alpha: .045)
      ..strokeWidth = .5;
    if (kind == 'sand') {
      for (var y = 12.0; y < size.height; y += 24) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    } else {
      for (var y = 8.0; y < size.height; y += 12) {
        for (var x = 8.0; x < size.width; x += 12) {
          canvas.drawCircle(Offset(x, y), .55, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(PaperPainter old) => old.kind != kind;
}

class MemoryCard extends StatelessWidget {
  const MemoryCard({
    super.key,
    required this.memory,
    required this.onOpen,
    required this.onBookmark,
    required this.pending,
  });
  final Memory memory;
  final VoidCallback onOpen, onBookmark;
  final bool pending;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(6),
          child: Semantics(
            label: 'Open ${memory.title}',
            button: true,
            child: AspectRatio(
              aspectRatio: .96,
              child: MemoryCanvas(memory: memory, preview: true),
            ),
          ),
        ),
      ),
      const SizedBox(height: 13),
      if (memory.job == JobStatus.processing ||
          memory.job == JobStatus.queued) ...[
        CutoutStatus(job: memory.job, compact: true),
        const SizedBox(height: 13),
      ],
      Row(
        children: [
          Expanded(
            child: Text(
              memory.companions.isEmpty
                  ? 'A moment for you'
                  : 'With ${memory.companions.join(', ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ),
          IconButton(
            onPressed: onBookmark,
            tooltip: memory.bookmarked
                ? 'Remove would go again'
                : 'Would go again',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(
              memory.bookmarked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              size: 17,
              color: memory.bookmarked ? Palette.terracotta : Palette.muted,
            ),
          ),
        ],
      ),
      Text(
        memory.demo
            ? 'EXAMPLE MEMORY'
            : pending
            ? 'PENDING BACKUP'
            : memory.scope == 'guest'
            ? 'SAVED ON THIS DEVICE'
            : 'BACKED UP',
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Palette.muted,
        ),
      ),
    ],
  );
}
