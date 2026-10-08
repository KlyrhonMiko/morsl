import 'package:flutter/material.dart';

import '../data/models.dart';
import 'plate_library.dart';
import 'theme.dart';

class PlatePreviewPager extends StatefulWidget {
  const PlatePreviewPager({
    super.key,
    required this.plates,
    required this.selectedId,
    required this.onSelected,
  });
  final List<Plate> plates;
  final String? selectedId;
  final ValueChanged<String> onSelected;

  @override
  State<PlatePreviewPager> createState() => _PlatePreviewPagerState();
}

class _PlatePreviewPagerState extends State<PlatePreviewPager> {
  late PageController controller;
  late int index;

  int get selectedIndex {
    final found = widget.plates.indexWhere(
      (plate) => plate.id == widget.selectedId,
    );
    return found < 0 ? 0 : found;
  }

  @override
  void initState() {
    super.initState();
    index = selectedIndex;
    controller = PageController(initialPage: index, keepPage: false);
  }

  @override
  void didUpdateWidget(PlatePreviewPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = selectedIndex;
    if (target != index ||
        oldWidget.plates.map((p) => p.id).join(',') !=
            widget.plates.map((p) => p.id).join(',')) {
      index = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.hasClients) {
          controller.jumpToPage(selectedIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void go(int target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.jumpToPage(target);
    } else {
      controller.animateToPage(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      AspectRatio(
        aspectRatio: 1,
        child: PageView.builder(
          key: const ValueKey('plate-preview-pages'),
          controller: controller,
          itemCount: widget.plates.length,
          onPageChanged: (value) {
            setState(() => index = value);
            widget.onSelected(widget.plates[value].id);
          },
          itemBuilder: (context, value) => Semantics(
            label: 'Plate ${value + 1} of ${widget.plates.length}',
            image: true,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: PlateImage(
                path: widget.plates[value].path,
                aspect: widget.plates[value].aspect,
                rotationSteps: widget.plates[value].rotationSteps,
              ),
            ),
          ),
        ),
      ),
      if (widget.plates.length > 1) ...[
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              onPressed: index > 0 ? () => go(index - 1) : null,
              tooltip: 'Previous plate',
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    'Plate ${index + 1} of ${widget.plates.length}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Swipe to view plates',
                    style: TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                  if (widget.plates.length <= 8) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var dot = 0; dot < widget.plates.length; dot++)
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: dot == index ? 16 : 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: dot == index
                                  ? Palette.forest
                                  : Palette.line,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              onPressed: index + 1 < widget.plates.length
                  ? () => go(index + 1)
                  : null,
              tooltip: 'Next plate',
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ],
    ],
  );
}
