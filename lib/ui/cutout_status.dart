import 'package:flutter/material.dart';

import '../data/models.dart';
import 'theme.dart';

/// Job feedback stays outside MemoryCanvas so it never appears in exports.
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
        ? 'Your photo is saved. You can keep editing while we work.'
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
