import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'media_image.dart';
import 'theme.dart';

/// Fits a cutout and its rotated bounds inside the available space.
class OrientedCutoutImage extends StatelessWidget {
  const OrientedCutoutImage({
    super.key,
    required this.path,
    required this.aspect,
    required this.rotationSteps,
    this.cacheWidth,
  });

  final String path;
  final double aspect;
  final int rotationSteps;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
        return CutoutImage(path: path, cacheWidth: cacheWidth);
      }
      final ratio = aspect.isFinite && aspect > 0 ? aspect : 1.0;
      final angle = rotationSteps * math.pi / 4;
      final cosine = math.cos(angle).abs();
      final sine = math.sin(angle).abs();
      final height = math.min(
        constraints.maxWidth / (ratio * cosine + sine),
        constraints.maxHeight / (ratio * sine + cosine),
      );
      return Center(
        child: Transform.rotate(
          angle: angle,
          child: SizedBox(
            width: ratio * height,
            height: height,
            child: CutoutImage(path: path, cacheWidth: cacheWidth),
          ),
        ),
      );
    },
  );
}

/// A paper-thin rim and contact shadow derived from the photo's alpha.
/// Straight cropped edges receive the same finish as curved plate edges.
class CutoutImage extends StatefulWidget {
  const CutoutImage({super.key, required this.path, this.cacheWidth});
  final String path;
  final int? cacheWidth;

  @override
  State<CutoutImage> createState() => _CutoutImageState();
}

class _CutoutImageState extends State<CutoutImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  late ImageStreamListener _listener;
  late ImageProvider _provider;

  @override
  void initState() {
    super.initState();
    _listener = ImageStreamListener(
      (info, synchronous) {
        final old = _info;
        if (synchronous) {
          _info = info;
        } else if (mounted) {
          setState(() => _info = info);
        } else {
          info.dispose();
        }
        old?.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        // The foreground Image owns the visible error state.
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(CutoutImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.cacheWidth != widget.cacheWidth) {
      _resolve();
    }
  }

  void _resolve() {
    _provider = ResizeImage.resizeIfNeeded(
      widget.cacheWidth,
      null,
      mediaImage(widget.path),
    );
    final next = _provider.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == next.key) return;
    _stream?.removeListener(_listener);
    _info?.dispose();
    _info = null;
    _stream = next..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final rim = (constraints.maxWidth / 100).clamp(1.2, 3.0);
      final inset = rim * 3;
      return CustomPaint(
        painter: _CutoutFinish(_info?.image, rim, inset),
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: Image(
            image: _provider,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Center(
              child: Icon(Icons.broken_image_outlined, color: Palette.muted),
            ),
          ),
        ),
      );
    },
  );
}

class _CutoutFinish extends CustomPainter {
  const _CutoutFinish(this.image, this.rim, this.inset);
  final ui.Image? image;
  final double rim, inset;

  @override
  void paint(Canvas canvas, Size size) {
    final source = image;
    if (source == null) return;
    final src = Rect.fromLTWH(
      0,
      0,
      source.width.toDouble(),
      source.height.toDouble(),
    );
    final available = Size(
      math.max(0, size.width - inset * 2),
      math.max(0, size.height - inset * 2),
    );
    final fitted = applyBoxFit(BoxFit.contain, src.size, available);
    final dst = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final shadow = Paint()
      ..colorFilter = ColorFilter.mode(
        Palette.ink.withValues(alpha: .20),
        BlendMode.srcIn,
      );
    canvas.saveLayer(
      dst.inflate(inset * 2),
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: rim * 1.7,
          sigmaY: rim * 1.7,
        ),
    );
    canvas.drawImageRect(
      source,
      src,
      dst.shift(Offset(rim * .6, rim * 1.7)),
      shadow,
    );
    canvas.restore();
    final paper = Paint()
      ..colorFilter = const ColorFilter.mode(
        Color(0xFFFFFCF5),
        BlendMode.srcIn,
      );
    // Dilate the alpha silhouette; no rectangular frame or guessed circle.
    for (var i = 0; i < 16; i++) {
      final angle = i * math.pi / 8;
      canvas.drawImageRect(
        source,
        src,
        dst.shift(Offset(math.cos(angle) * rim, math.sin(angle) * rim)),
        paper,
      );
    }
  }

  @override
  bool shouldRepaint(_CutoutFinish old) =>
      old.image != image || old.rim != rim || old.inset != inset;
}
