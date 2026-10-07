import 'dart:math' as math;

import '../data/models.dart';

/// A compact, layered collage with a diagonal path through the main dishes.
void arrangePlates(List<Plate> plates) {
  if (plates.isEmpty) return;
  final poses = switch (plates.length) {
    1 => [(.50, .42, .76, .60)],
    2 => [(.39, .34, .65, .44), (.65, .54, .56, .40)],
    3 => [(.36, .34, .62, .44), (.72, .35, .40, .32), (.55, .61, .48, .30)],
    4 => [
      (.36, .31, .62, .38),
      (.73, .34, .39, .32),
      (.26, .61, .40, .26),
      (.63, .59, .50, .32),
    ],
    5 => [
      (.36, .31, .62, .38),
      (.73, .29, .40, .30),
      (.22, .57, .34, .25),
      (.54, .59, .44, .30),
      (.80, .60, .28, .26),
    ],
    6 => [
      (.36, .30, .62, .38),
      (.73, .34, .40, .32),
      (.20, .55, .35, .26),
      (.49, .53, .39, .28),
      (.33, .69, .34, .22),
      (.74, .64, .40, .30),
    ],
    _ => <(double, double, double, double)>[],
  };
  final rows = (plates.length / 3).ceil();
  for (var i = 0; i < plates.length; i++) {
    final plate = plates[i];
    final (cx, cy, width, height) = poses.isNotEmpty
        ? poses[i]
        : (
            .21 + i % 3 * .29 + ((i ~/ 3).isOdd ? .015 : -.015),
            .19 + (i ~/ 3 + .5) * (.58 / rows),
            .32,
            .58 / rows * 1.08,
          );
    final angle = const [-.13, .15, -.18, .09, -.07, .17][i % 6];
    final aspect = plate.aspect.isFinite && plate.aspect > 0
        ? plate.aspect
        : 1.0;
    final cos = math.cos(angle).abs(), sin = math.sin(angle).abs();
    final scale = math.min(
      width / (cos + sin / aspect),
      height / (.96 * (sin + cos / aspect)),
    );
    final rotatedWidth = scale * (cos + sin / aspect);
    final rotatedHeight = scale * .96 * (sin + cos / aspect);
    final centerX = cx.clamp(.06 + rotatedWidth / 2, .94 - rotatedWidth / 2);
    final centerY = cy.clamp(.12 + rotatedHeight / 2, .80 - rotatedHeight / 2);
    plate.scale = scale;
    plate.x = centerX - scale / 2;
    plate.y = centerY - scale * .96 / aspect / 2;
    plate.rotation = angle;
  }
}

// Kept solely to recognize the previous automatic layout without touching edits.
void _previousArrangement(List<Plate> plates) {
  if (plates.isEmpty) return;
  final slots = switch (plates.length) {
    1 => [(.16, .14, .68, .58)],
    2 => [(.08, .12, .53, .37), (.43, .43, .49, .30)],
    3 => [(.08, .12, .51, .36), (.61, .19, .31, .28), (.32, .50, .48, .24)],
    4 => [
      (.08, .12, .49, .32),
      (.62, .18, .30, .25),
      (.12, .49, .32, .25),
      (.49, .46, .43, .28),
    ],
    5 => [
      (.08, .12, .49, .29),
      (.62, .18, .30, .22),
      (.09, .45, .27, .22),
      (.41, .43, .34, .24),
      (.76, .52, .16, .22),
    ],
    6 => [
      (.08, .12, .49, .35),
      (.64, .18, .28, .28),
      (.08, .52, .18, .22),
      (.30, .48, .20, .26),
      (.55, .55, .17, .19),
      (.76, .50, .16, .24),
    ],
    _ => <(double, double, double, double)>[],
  };
  final columns = 3;
  final rows = (plates.length / columns).ceil();
  for (var i = 0; i < plates.length; i++) {
    final plate = plates[i];
    final (x, y, width, height) = slots.isNotEmpty
        ? slots[i]
        : (
            .08 + (i % columns) * .28,
            .12 + (i ~/ columns) * (.62 / rows),
            .25,
            .62 / rows * .88,
          );
    final angle = const [-.10, .12, .07, -.08, -.14, .09][i % 6];
    final aspect = plate.aspect.isFinite && plate.aspect > 0
        ? plate.aspect
        : 1.0;
    // Fit the rotated silhouette, not just its unrotated image rectangle.
    final cos = math.cos(angle).abs(), sin = math.sin(angle).abs();
    final scale = math.min(
      width / (cos + sin / aspect),
      height / (.96 * (sin + cos / aspect)),
    );
    plate.scale = scale;
    plate.x = x + (width - scale) / 2;
    plate.y = y + (height - scale * .96 / aspect) / 2;
    plate.rotation = angle;
  }
}

/// Upgrade only the exact former automatic grid. Custom placements stay intact.
List<Plate> displayPlates(List<Plate> plates) {
  if (plates.isEmpty) return plates;
  final previous = plates.map((p) => p.copy()).toList();
  _previousArrangement(previous);
  if (plates.indexed.every((entry) {
    final p = entry.$2, old = previous[entry.$1];
    return (p.x - old.x).abs() < .00001 &&
        (p.y - old.y).abs() < .00001 &&
        (p.scale - old.scale).abs() < .00001 &&
        (p.rotation - old.rotation).abs() < .00001;
  })) {
    arrangePlates(previous);
    return previous;
  }
  final columns = plates.length == 1 ? 1 : (plates.length > 6 ? 3 : 2);
  final rows = (plates.length / columns).ceil();
  final width = .84 / columns, height = .62 / rows;
  for (var i = 0; i < plates.length; i++) {
    final p = plates[i];
    final scale = math.min(width * .91, height * p.aspect);
    final x = .08 + i % columns * width + (width - scale) / 2;
    final y =
        .12 + i ~/ columns * height + (height - scale * .91 / p.aspect) / 2;
    if ((p.scale - scale).abs() > .00001 ||
        (p.x - x).abs() > .00001 ||
        (p.y - y).abs() > .00001 ||
        p.rotation != 0) {
      return plates;
    }
  }
  final arranged = plates.map((p) => p.copy()).toList();
  arrangePlates(arranged);
  return arranged;
}
