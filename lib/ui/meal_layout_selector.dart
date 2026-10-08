import 'package:flutter/material.dart';

import '../data/models.dart';
import 'cutout_image.dart';
import 'plate_layout.dart';
import 'theme.dart';

const mealLayoutStyles = [
  ('editorial', 'Editorial', 'A leading dish, layered with smaller accents.'),
  ('scrapbook', 'Scrapbook', 'Playful angles and a closely gathered collage.'),
  ('clean', 'Clean spread', 'Even spacing, aligned dishes, room to breathe.'),
];

class MealLayoutSelector extends StatelessWidget {
  const MealLayoutSelector({
    super.key,
    required this.memory,
    required this.onSelected,
    this.enabled = true,
  });

  final Memory memory;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final chosen = memory.plateLayout;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Auto layout',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Choose a style to arrange every dish.',
          style: TextStyle(fontSize: 12, color: Palette.muted),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < mealLayoutStyles.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _option(mealLayoutStyles[i], chosen)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Text(
          mealLayoutStyles.where((s) => s.$1 == chosen).firstOrNull?.$3 ??
              'Your current arrangement is kept until you choose a style.',
          style: const TextStyle(fontSize: 12, color: Palette.muted),
        ),
      ],
    );
  }

  Widget _option((String, String, String) style, String chosen) {
    final selected = style.$1 == chosen;
    final plates = memory.plates.map((p) => p.copy()).toList();
    arrangePlates(plates, style: style.$1);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '${style.$2} auto layout',
      onTap: enabled ? () => onSelected(style.$1) : null,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('layout-${style.$1}'),
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? () => onSelected(style.$1) : null,
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Palette.background(memory.background),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? Palette.forest : Palette.line,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  child: AspectRatio(
                    aspectRatio: 1.12,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LayoutBuilder(
                        builder: (context, box) => Stack(
                          children: [
                            for (final p in plates)
                              Positioned(
                                left: p.x * box.maxWidth,
                                top: (p.y - .08) * box.maxWidth / .96,
                                width: p.scale * box.maxWidth,
                                height: p.scale * box.maxWidth / p.aspect,
                                child: Transform.rotate(
                                  angle: p.rotation,
                                  child: CutoutImage(
                                    path: p.path,
                                    cacheWidth: 200,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    style.$2,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Palette.forest : Palette.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
