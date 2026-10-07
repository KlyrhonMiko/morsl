import 'dart:math' as math;

import '../data/models.dart';

/// Compose silhouettes as a compact spread, with balanced visual weight.
void arrangePlates(List<Plate> plates, {String style = 'editorial'}) {
  if (style == 'clean') {
    _cleanSpread(plates);
    return;
  }
  if (style != 'scrapbook') {
    _editorialSpread(plates);
    return;
  }
  if (plates.isEmpty || plates.length > 6) {
    _scatteredArrangement(plates);
    return;
  }
  // Follow an irregular path around a central anchor, without row baselines.
  final centers = switch (plates.length) {
    1 => [(.50, .43)],
    2 => [(.37, .34), (.63, .56)],
    3 => [(.32, .32), (.68, .36), (.49, .61)],
    4 => [(.29, .30), (.67, .32), (.37, .56), (.73, .61)],
    5 => [(.31, .28), (.70, .30), (.49, .46), (.24, .63), (.72, .65)],
    _ => [
      (.30, .30),
      (.67, .27),
      (.49, .45),
      (.22, .59),
      (.58, .66),
      (.79, .53),
    ],
  };
  for (var i = 0; i < plates.length; i++) {
    final plate = plates[i];
    final aspect = plate.aspect.isFinite && plate.aspect > 0
        ? plate.aspect
        : 1.0;
    final angle = const [-.22, .19, -.11, .16, -.20, .14][i];
    final cos = math.cos(angle).abs(), sin = math.sin(angle).abs();
    final rw = cos + sin / aspect;
    final rh = .96 * (sin + cos / aspect);
    final area = plates.length < 4
        ? .22 / math.sqrt(plates.length)
        : const [.105, .085, .115, .085, .095, .085][i];
    final scale = math.min(
      math.sqrt(area / (rw * rh)),
      math.min(
        (plates.length < 4 ? .60 : .43) / rw,
        (plates.length < 4 ? .42 : .35) / rh,
      ),
    );
    final (cx, cy) = centers[i];
    final x = cx.clamp(.06 + scale * rw / 2, .94 - scale * rw / 2);
    final y = cy.clamp(.12 + scale * rh / 2, .80 - scale * rh / 2);
    plate.scale = scale;
    plate.x = x - scale / 2;
    plate.y = y - scale * .96 / aspect / 2;
    plate.rotation = angle;
  }
}

void _cleanSpread(List<Plate> plates) {
  if (plates.isEmpty) return;
  final columns = plates.length <= 3
      ? plates.length
      : plates.length == 4
      ? 2
      : 3;
  final rows = (plates.length / columns).ceil();
  final cellWidth = .86 / columns;
  final cellHeight = .60 / rows;
  for (var i = 0; i < plates.length; i++) {
    final p = plates[i];
    final aspect = p.aspect.isFinite && p.aspect > 0 ? p.aspect : 1.0;
    final inRow = math.min(columns, plates.length - i ~/ columns * columns);
    final cx = .5 + (i % columns - (inRow - 1) / 2) * cellWidth;
    final cy = .15 + (i ~/ columns + .5) * cellHeight;
    final scale = math.min(cellWidth * .92, cellHeight * .90 * aspect / .96);
    p.scale = scale;
    p.x = cx - scale / 2;
    p.y = cy - scale * .96 / aspect / 2;
    p.rotation = 0;
  }
}

void _editorialSpread(List<Plate> plates) {
  if (plates.length < 4 || plates.length > 6) {
    _scatteredArrangement(plates);
    return;
  }
  // One leading dish and a second anchor, connected by smaller accents.
  final poses = switch (plates.length) {
    4 => [
      (.32, .32, .53, .39),
      (.74, .30, .33, .29),
      (.24, .64, .32, .26),
      (.62, .59, .51, .37),
    ],
    5 => [
      (.32, .31, .52, .38),
      (.74, .27, .32, .26),
      (.76, .48, .30, .27),
      (.22, .62, .30, .27),
      (.53, .62, .44, .31),
    ],
    _ => [
      (.31, .30, .50, .37),
      (.73, .25, .31, .25),
      (.72, .47, .38, .30),
      (.19, .59, .28, .29),
      (.48, .63, .42, .31),
      (.80, .69, .26, .20),
    ],
  };
  for (var i = 0; i < plates.length; i++) {
    final p = plates[i];
    final aspect = p.aspect.isFinite && p.aspect > 0 ? p.aspect : 1.0;
    final angle = const [-.06, .08, -.10, .07, -.05, .10][i];
    final cos = math.cos(angle).abs(), sin = math.sin(angle).abs();
    final rw = cos + sin / aspect, rh = .96 * (sin + cos / aspect);
    final (cx, cy, width, height) = poses[i];
    final scale = math.min(width / rw, height / rh);
    final x = cx.clamp(.06 + scale * rw / 2, .94 - scale * rw / 2);
    final y = cy.clamp(.12 + scale * rh / 2, .80 - scale * rh / 2);
    p.scale = scale;
    p.x = x - scale / 2;
    p.y = y - scale * .96 / aspect / 2;
    p.rotation = angle;
  }
}

// Recognize the former fixed-slot collage so existing automatic meals upgrade.
void _scatteredArrangement(List<Plate> plates) {
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
List<Plate> displayPlates(
  List<Plate> plates, {
  bool edited = false,
  String style = '',
}) {
  if (edited) return plates;
  if (style.isNotEmpty) {
    final arranged = plates.map((p) => p.copy()).toList();
    arrangePlates(arranged, style: style);
    return arranged;
  }
  if (plates.length > 1) {
    final groups = <String?, List<Plate>>{};
    for (final plate in plates) {
      (groups[plate.photoId] ??= []).add(plate);
    }
    // Older meals saved the automatic arrangement of each source photo.
    // Recognize those exact poses rather than guessing from overlap, which
    // could overwrite an intentional composition.
    if (groups.length > 1 && groups.values.every(_isAutomaticGroup)) {
      final arranged = plates.map((p) => p.copy()).toList();
      arrangePlates(arranged);
      return arranged;
    }
  }
  return _refreshPreviousArrangement(plates);
}

bool _samePose(Plate p, Plate other) =>
    (p.x - other.x).abs() < .00001 &&
    (p.y - other.y).abs() < .00001 &&
    (p.scale - other.scale).abs() < .00001 &&
    (p.rotation - other.rotation).abs() < .00001;

bool _isAutomaticGroup(List<Plate> plates) {
  final expected = plates.map((p) => p.copy()).toList();
  arrangePlates(expected);
  return plates.indexed.every((e) => _samePose(e.$2, expected[e.$1])) ||
      !identical(_refreshPreviousArrangement(plates), plates);
}

List<Plate> _refreshPreviousArrangement(List<Plate> plates) {
  if (plates.isEmpty) return plates;
  final scattered = plates.map((p) => p.copy()).toList();
  _scatteredArrangement(scattered);
  if (plates.indexed.every((e) => _samePose(e.$2, scattered[e.$1]))) {
    arrangePlates(scattered);
    return scattered;
  }
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
