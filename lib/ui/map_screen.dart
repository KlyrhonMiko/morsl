import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../controller.dart';
import '../data/models.dart';
import 'theme.dart';

class MealMap extends StatefulWidget {
  const MealMap({super.key, required this.app, required this.onOpen});
  final MorslController app;
  final void Function(Memory) onOpen;
  @override
  State<MealMap> createState() => _MealMapState();
}

class _MealMapState extends State<MealMap> {
  bool bookmarked = false;
  String companion = 'Everyone';
  bool preview = false;
  @override
  Widget build(BuildContext context) {
    final meals = widget.app.memories
        .where(
          (m) =>
              !m.draft &&
              !m.archived &&
              m.hasLocation &&
              (!bookmarked || m.bookmarked) &&
              (companion == 'Everyone' || m.companions.contains(companion)),
        )
        .toList();
    final ready =
        const String.fromEnvironment('GOOGLE_MAPS_API_KEY').isNotEmpty &&
        (Platform.isAndroid || Platform.isIOS) &&
        !preview &&
        widget.app.online;
    final people = {
      'Everyone',
      ...widget.app.memories.expand((m) => m.companions),
    }.toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Places that became memories'),
          const SizedBox(height: 12),
          const Handwriting(
            'A little map of your life.',
            size: 39,
            color: Palette.forest,
          ),
          const SizedBox(height: 8),
          const Text(
            'Every pin is a meal. Every meal has a story.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: Text(
                  'Would go again',
                  style: TextStyle(
                    color: bookmarked ? Colors.white : Palette.ink,
                  ),
                ),
                selected: bookmarked,
                onSelected: (v) => setState(() => bookmarked = v),
              ),
              DropdownButton<String>(
                value: people.contains(companion) ? companion : 'Everyone',
                items: people
                    .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                    .toList(),
                onChanged: (v) => setState(() => companion = v!),
              ),
              if (ready || preview)
                TextButton(
                  onPressed: () => setState(() => preview = !preview),
                  child: Text(preview ? 'Try online map' : 'Use offline list'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (!widget.app.online)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Offline · your saved memories and locations are available below.',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
            ),
          SizedBox(
            height: 380,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ready
                  ? GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: meals.isEmpty
                            ? const LatLng(14.5547, 121.0244)
                            : LatLng(
                                meals.first.latitude!,
                                meals.first.longitude!,
                              ),
                        zoom: 13,
                      ),
                      clusterManagers: {
                        ClusterManager(
                          clusterManagerId: const ClusterManagerId('meals'),
                        ),
                      },
                      markers: meals
                          .map(
                            (m) => Marker(
                              markerId: MarkerId(m.id),
                              clusterManagerId: const ClusterManagerId('meals'),
                              position: LatLng(m.latitude!, m.longitude!),
                              infoWindow: InfoWindow(
                                title: m.venue.isEmpty
                                    ? 'A little meal'
                                    : m.venue,
                                snippet: m.caption,
                                onTap: () => widget.onOpen(m),
                              ),
                              onTap: () => widget.onOpen(m),
                            ),
                          )
                          .toSet(),
                      myLocationButtonEnabled: false,
                      mapToolbarEnabled: false,
                      zoomControlsEnabled: false,
                    )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: MapPreviewPainter()),
                        ),
                        ...meals
                            .take(6)
                            .indexed
                            .map(
                              (entry) => Positioned(
                                left: 40 + entry.$1 % 3 * 85.0,
                                top: 70 + entry.$1 ~/ 3 * 100.0,
                                child: IconButton.filled(
                                  onPressed: () => widget.onOpen(entry.$2),
                                  tooltip: entry.$2.venue,
                                  style: IconButton.styleFrom(
                                    backgroundColor: Palette.terracotta,
                                  ),
                                  icon: const Icon(Icons.restaurant, size: 20),
                                ),
                              ),
                            ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            margin: const EdgeInsets.all(16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Palette.paper,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'Illustrated preview · locations listed below\nConnect Google Maps for a geographic map.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: Palette.muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '${meals.length} confirmed meal locations',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (meals.isEmpty)
            const EmptyState(
              icon: Icons.place_outlined,
              title: 'A memory doesn’t need a pin.',
              message: 'Confirm a meal location in Plating to see it here. All your memories are still in History.',
            ),
          ...meals.map(
            (m) => ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Palette.sage,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.place_outlined, color: Palette.forest),
              ),
              title: Text(
                m.venue.isEmpty ? 'Confirmed location' : m.venue,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                '${m.latitude!.toStringAsFixed(4)}, ${m.longitude!.toStringAsFixed(4)} · ${m.companions.join(', ')}',
                style: const TextStyle(fontSize: 11, color: Palette.muted),
              ),
              trailing: const Icon(Icons.arrow_forward_rounded, size: 18),
              onTap: () => widget.onOpen(m),
            ),
          ),
        ],
      ),
    );
  }
}

class MapPreviewPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFE8EBDD),
    );
    final block = Paint()..color = const Color(0xFFDCE3CE);
    for (var y = 0.0; y < size.height; y += 90) {
      for (var x = 0.0; x < size.width; x += 120) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + 10, y + 12, 93, 65),
            const Radius.circular(8),
          ),
          block,
        );
      }
    }
    final road = Paint()
      ..color = const Color(0xFFFAF9F1)
      ..strokeWidth = 14;
    for (var x = 0.0; x < size.width; x += 120) {
      canvas.drawLine(Offset(x, 0), Offset(x + 50, size.height), road);
    }
    for (var y = 0.0; y < size.height; y += 90) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y + 30), road);
    }
    canvas.drawLine(
      Offset(size.width * .75, -20),
      Offset(size.width * .25, size.height + 20),
      Paint()
        ..color = const Color(0xFFD7DFCD)
        ..strokeWidth = 36,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
