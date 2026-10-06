import 'package:flutter/material.dart';

import '../data/models.dart';
import 'theme.dart';

/// Job feedback stays outside exported photo canvases.
class CutoutStatus extends StatelessWidget {
  const CutoutStatus({super.key, required this.job, this.compact = false});

  final JobStatus job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (job != JobStatus.processing && job != JobStatus.queued) {
      return const SizedBox.shrink();
    }
    final processing = job == JobStatus.processing;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final title = processing ? 'Creating your cutout…' : 'Waiting for cutout';
    final detail = processing
        ? 'Your photo is saved. You can add meal details while we work.'
        : 'Your original is saved. The cutout will start when processing is available.';

    return Semantics(
      liveRegion: true,
      label: '$title. ${compact ? 'Your original is saved.' : detail}',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(compact ? 12 : 16),
          decoration: BoxDecoration(
            color: Palette.sage,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: processing && !reduceMotion
                      ? const CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Palette.forest,
                        )
                      : Icon(
                          processing ? Icons.hourglass_top : Icons.schedule,
                          size: 18,
                          color: Palette.forest,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Palette.forest,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Palette.ink,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Read-only source preview with processing feedback attached to the photo.
/// This component is never used by the photo export canvas.
class CutoutPhoto extends StatefulWidget {
  const CutoutPhoto({super.key, required this.job, required this.child});
  final JobStatus job;
  final Widget child;
  @override
  State<CutoutPhoto> createState() => _CutoutPhotoState();
}

class _CutoutPhotoState extends State<CutoutPhoto>
    with SingleTickerProviderStateMixin {
  // A slow, linear sweep communicates ongoing work without flashing the photo.
  late final AnimationController shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  bool get pending =>
      widget.job == JobStatus.processing || widget.job == JobStatus.queued;
  void _updateMotion() {
    final reduce =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (widget.job == JobStatus.processing &&
        !reduce &&
        TickerMode.valuesOf(context).enabled) {
      if (!shimmer.isAnimating) shimmer.repeat();
    } else {
      shimmer.stop();
      shimmer.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(CutoutPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void dispose() {
    shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final title = widget.job == JobStatus.processing
        ? 'Creating your cutout…'
        : 'Waiting for cutout';
    final photo = IgnorePointer(child: RepaintBoundary(child: widget.child));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.loose,
        children: [
          if (widget.job == JobStatus.processing && !reduce)
            AnimatedBuilder(
              animation: shimmer,
              child: photo,
              builder: (context, child) => ShaderMask(
                key: const ValueKey('cutout-photo-shimmer'),
                blendMode: BlendMode.srcATop,
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment(-3 + shimmer.value * 6, -1),
                  end: Alignment(-1 + shimmer.value * 6, 1),
                  colors: [
                    Colors.white.withValues(alpha: .04),
                    Colors.white.withValues(alpha: .32),
                    Colors.white.withValues(alpha: .04),
                  ],
                  stops: const [0, .5, 1],
                ).createShader(rect),
                child: child,
              ),
            )
          else
            photo,
          if (pending)
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Semantics(
                liveRegion: true,
                label:
                    '$title. Your photo is saved. You can add meal details while you wait.',
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Palette.paper.withValues(alpha: .96),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.job == JobStatus.processing
                              ? Icons.auto_awesome_outlined
                              : Icons.schedule,
                          size: 18,
                          color: Palette.forest,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Palette.forest,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
