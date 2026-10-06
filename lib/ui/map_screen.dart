import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../controller.dart';
import '../data/models.dart';
import 'theme.dart';
import 'geoapify_attribution.dart';

class MealMap extends StatefulWidget {
  const MealMap({
    super.key,
    required this.app,
    required this.onOpen,
    this.apiKey = const String.fromEnvironment('GEOAPIFY_MAPS_API_KEY'),
    this.tileProvider,
  });
  final MorslController app;
  final void Function(Memory) onOpen;
  final String apiKey;
  final TileProvider? tileProvider;
  @override
  State<MealMap> createState() => _MealMapState();
}

class _MealMapState extends State<MealMap> {
  bool bookmarked = false;
  String companion = 'Everyone';
  bool preview = false;
  bool tileError = false;
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
    final ready = widget.apiKey.isNotEmpty && !preview && widget.app.online;
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
                  onPressed: () => setState(() {
                    preview = !preview;
                    tileError = false;
                  }),
                  child: Text(preview ? 'Try online map' : 'Use offline list'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (ready && tileError)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'The map is unavailable right now. Your saved locations are below, or use the offline list.',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
            ),
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
                  ? Stack(
                      children: [
                        FlutterMap(
                          options: MapOptions(
                            initialCenter: meals.isEmpty
                                ? const LatLng(14.5547, 121.0244)
                                : LatLng(
                                    meals.first.latitude!,
                                    meals.first.longitude!,
                                  ),
                            initialZoom: 13,
                            minZoom: 2,
                            maxZoom: 19,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://maps.geoapify.com/v1/tile/osm-carto/{z}/{x}/{y}.png?apiKey=${Uri.encodeQueryComponent(widget.apiKey)}',
                              tileProvider: widget.tileProvider,
                              userAgentPackageName: 'com.example.morsl',
                              maxNativeZoom: 19,
                              panBuffer: 0,
                              errorTileCallback: (_, _, _) {
                                if (mounted && !tileError) {
                                  setState(() => tileError = true);
                                }
                              },
                            ),
                            MarkerClusterLayerWidget(
                              options: MarkerClusterLayerOptions(
                                maxClusterRadius: 45,
                                size: const Size(44, 44),
                                padding: const EdgeInsets.all(48),
                                maxZoom: 17,
                                markers: meals
                                    .map(
                                      (m) => Marker(
                                        key: ValueKey(m.id),
                                        point: LatLng(
                                          m.latitude!,
                                          m.longitude!,
                                        ),
                                        width: 44,
                                        height: 44,
                                        child: IconButton.filled(
                                          tooltip: m.venue.isEmpty
                                              ? 'A little meal'
                                              : m.venue,
                                          style: IconButton.styleFrom(
                                            backgroundColor: Palette.terracotta,
                                          ),
                                          icon: const Icon(
                                            Icons.restaurant,
                                            size: 20,
                                          ),
                                          onPressed: () => widget.onOpen(m),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                builder: (context, markers) => Container(
                                  decoration: const BoxDecoration(
                                    color: Palette.terracotta,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '${markers.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: GeoapifyAttribution(),
                        ),
                      ],
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
                              'Illustrated preview · locations listed below\nGeoapify provides the online map.',
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
              message:
                  'Confirm a meal location in Plating to see it here. All your memories are still in History.',
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
