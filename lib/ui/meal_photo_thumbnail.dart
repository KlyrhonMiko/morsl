import 'package:flutter/material.dart';

import 'media_image.dart';
import 'theme.dart';

/// A source-photo preview that can recover from a failed cloud download.
class MealPhotoThumbnail extends StatefulWidget {
  const MealPhotoThumbnail({super.key, required this.path});

  final String path;

  @override
  State<MealPhotoThumbnail> createState() => _MealPhotoThumbnailState();
}

class _MealPhotoThumbnailState extends State<MealPhotoThumbnail> {
  int attempt = 0;
  bool retrying = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final pixelWidth =
          (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
              .ceil()
              .clamp(1, 1024);
      final provider = ResizeImage.resizeIfNeeded(
        pixelWidth,
        null,
        mediaImage(widget.path),
      );
      return Image(
        key: ValueKey((widget.path, attempt)),
        image: provider,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, synchronous) =>
            synchronous || frame != null
            ? child
            : const Center(
                child: Text(
                  'Loading photo…',
                  style: TextStyle(fontSize: 12, color: Palette.muted),
                ),
              ),
        errorBuilder: (context, error, stack) => Center(
          child: TextButton.icon(
            onPressed: retrying
                ? null
                : () async {
                    setState(() => retrying = true);
                    await provider.evict();
                    await mediaImage(widget.path).evict();
                    if (!mounted) return;
                    setState(() {
                      attempt++;
                      retrying = false;
                    });
                  },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry photo'),
            style: TextButton.styleFrom(foregroundColor: Palette.ink),
          ),
        ),
      );
    },
  );
}
