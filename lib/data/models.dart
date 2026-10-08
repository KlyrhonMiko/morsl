import 'dart:convert';
import 'dart:math' as math;

enum JobStatus { queued, processing, ready, failed }

/// An alpha mask over a region of the unchanged original, and its placement.
/// Masks, coordinates, and R2 object references travel in backup; local paths do not.
class Plate {
  Plate({
    required this.id,
    required this.mask,
    this.path = '',
    this.cloudPath,
    this.photoId,
    this.left = 0,
    this.top = 0,
    this.width = 1,
    this.height = 1,
    this.aspect = 1,
    this.x = .2,
    this.y = .15,
    this.scale = .6,
    this.rotation = 0,
    this.rotationSteps = 0,
  });
  final String id;
  String mask, path;
  String? cloudPath;
  String? photoId;
  double left, top, width, height, aspect, x, y, scale, rotation;

  /// Clockwise orientation in 45-degree steps, separate from layout rotation.
  int rotationSteps;
  double get orientationRadians => rotationSteps * math.pi / 4;
  double get orientedAspect {
    final cosine = math.cos(orientationRadians).abs();
    final sine = math.sin(orientationRadians).abs();
    return (aspect * cosine + sine) / (aspect * sine + cosine);
  }

  Map<String, dynamic> toJson({bool local = true}) => {
    'id': id,
    'mask': mask,
    if (photoId != null) 'photoId': photoId,
    if (cloudPath != null) 'cloudPath': cloudPath,
    if (local) 'path': path,
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'aspect': aspect,
    'x': x,
    'y': y,
    'scale': scale,
    'rotation': rotation,
    'rotationSteps': rotationSteps,
  };
  Plate copy() => Plate.fromJson(toJson());
  factory Plate.fromJson(Map<String, dynamic> j) => Plate(
    id: j['id'],
    mask: j['mask'],
    path: j['path'] ?? '',
    cloudPath: j['cloudPath'],
    photoId: j['photoId'],
    left: (j['left'] as num?)?.toDouble() ?? 0,
    top: (j['top'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toDouble() ?? 1,
    height: (j['height'] as num?)?.toDouble() ?? 1,
    aspect: (j['aspect'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? .2,
    y: (j['y'] as num?)?.toDouble() ?? .15,
    scale: (j['scale'] as num?)?.toDouble() ?? .6,
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
    rotationSteps:
        (j['rotationSteps'] as num?)?.toInt() ??
        ((j['quarterTurns'] as num?)?.toInt() ?? 0) * 2,
  );
}

/// Additional source photos belong to the same meal, with independent jobs.
class MealPhoto {
  MealPhoto({
    required this.id,
    required this.original,
    this.job = JobStatus.queued,
    this.error,
  });
  final String id;
  String original;
  JobStatus job;
  String? error;
  Map<String, dynamic> toJson() => {
    'id': id,
    'original': original,
    'job': job.name,
    'error': error,
  };
  factory MealPhoto.fromJson(Map<String, dynamic> json) => MealPhoto(
    id: json['id'],
    original: json['original'],
    job: JobStatus.values.byName(json['job'] ?? 'queued'),
    error: json['error'],
  );
}

class Memory {
  Memory({
    required this.id,
    required this.scope,
    required this.createdAt,
    required this.original,
    this.thumbnail,
    this.cutout,
    this.plates = const [],
    this.platesEdited = false,
    this.plateLayout = '',
    this.creator,
    this.assetId,
    this.venue = '',
    this.placeId,
    this.caption = '',
    this.companions = const [],
    this.feeling = 'happy',
    this.bookmarked = false,
    this.draft = true,
    this.archived = false,
    this.useOriginal = true,
    this.background = 'cream',
    this.layout = 'classic',
    this.x = 0,
    this.y = 0,
    this.scale = 1,
    this.rotation = 0,
    this.latitude,
    this.longitude,
    this.accuracy,
    this.measuredAt,
    this.locationConfirmed = false,
    this.job = JobStatus.queued,
    this.attempts = 0,
    this.error,
    this.durationMs,
    this.rating,
    this.failureCategory,
    this.runtime,
    this.mealRevision = 0,
    this.memoryRevision = 0,
    this.demo = false,
    this.plateReviews = const {},
    this.photos = const [],
    this.originalProcessed = false,
  });

  final String id;
  String scope;
  String? creator;
  String? assetId;
  DateTime createdAt;
  String original;
  String? thumbnail, cutout;
  List<Plate> plates;
  bool platesEdited;
  String plateLayout;
  String venue, caption, feeling, background, layout;
  String? placeId;
  List<String> companions;
  bool bookmarked, draft, archived, useOriginal, locationConfirmed, demo;
  double x, y, scale, rotation;
  double? latitude, longitude, accuracy;
  DateTime? measuredAt;
  JobStatus job;
  int attempts;
  String? error, rating, failureCategory, runtime;
  int? durationMs;
  int mealRevision, memoryRevision;
  Map<String, PlateReview> plateReviews;
  List<MealPhoto> photos;
  bool originalProcessed;
  List<String> get originals => [original, ...photos.map((p) => p.original)];
  String sourceFor(Plate plate) => plate.photoId == null
      ? original
      : photos.where((p) => p.id == plate.photoId).first.original;
  bool get hasLocation =>
      locationConfirmed && latitude != null && longitude != null;
  bool get ownsMeal => creator == null || creator == scope;
  bool get displaysCutout =>
      !useOriginal && (plates.isNotEmpty || cutout?.isNotEmpty == true);
  String get displayPath =>
      displaysCutout ? (plates.firstOrNull?.path ?? cutout!) : original;
  String get title => caption.isNotEmpty
      ? caption
      : venue.isNotEmpty
      ? 'A little moment at $venue'
      : 'A meal worth remembering';

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope,
    'creator': creator,
    'assetId': assetId,
    'createdAt': createdAt.toIso8601String(),
    'original': original,
    'photos': photos.map((p) => p.toJson()).toList(),
    'originalProcessed': originalProcessed,
    'thumbnail': thumbnail,
    'cutout': cutout,
    'plates': plates.map((plate) => plate.toJson()).toList(),
    'platesEdited': platesEdited,
    'plateLayout': plateLayout,
    'venue': venue,
    'placeId': placeId,
    'caption': caption,
    'companions': companions,
    'feeling': feeling,
    'bookmarked': bookmarked,
    'draft': draft,
    'archived': archived,
    'useOriginal': useOriginal,
    'background': background,
    'layout': layout,
    'x': x,
    'y': y,
    'scale': scale,
    'rotation': rotation,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'measuredAt': measuredAt?.toIso8601String(),
    'locationConfirmed': locationConfirmed,
    'job': job.name,
    'attempts': attempts,
    'error': error,
    'durationMs': durationMs,
    'rating': rating,
    'failureCategory': failureCategory,
    'runtime': runtime,
    'mealRevision': mealRevision,
    'memoryRevision': memoryRevision,
    'demo': demo,
    'plateReviews': plateReviews.map(
      (id, review) => MapEntry(id, review.toJson()),
    ),
  };
  String encode() => jsonEncode(toJson());
  Memory copy() => Memory.fromJson(toJson());
  factory Memory.fromJson(Map<String, dynamic> j) => Memory(
    id: j['id'],
    scope: j['scope'],
    creator: j['creator'],
    assetId: j['assetId'],
    createdAt: DateTime.parse(j['createdAt']),
    original: j['original'],
    photos: (j['photos'] as List? ?? [])
        .map((p) => MealPhoto.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
    originalProcessed:
        j['originalProcessed'] ?? (j['job'] == 'ready' || j['job'] == 'failed'),
    thumbnail: j['thumbnail'],
    cutout: j['cutout'],
    plates: (j['plates'] as List? ?? [])
        .map((p) => Plate.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
    platesEdited: j['platesEdited'] ?? false,
    plateLayout: j['plateLayout'] ?? '',
    venue: j['venue'] ?? '',
    placeId: j['placeId'],
    caption: j['caption'] ?? '',
    companions: List<String>.from(j['companions'] ?? []),
    feeling: j['feeling'] ?? 'happy',
    bookmarked: j['bookmarked'] ?? false,
    draft: j['draft'] ?? true,
    archived: j['archived'] ?? false,
    useOriginal: j['useOriginal'] ?? true,
    background: j['background'] ?? 'cream',
    layout: j['layout'] ?? 'classic',
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
    latitude: (j['latitude'] as num?)?.toDouble(),
    longitude: (j['longitude'] as num?)?.toDouble(),
    accuracy: (j['accuracy'] as num?)?.toDouble(),
    measuredAt: j['measuredAt'] == null
        ? null
        : DateTime.parse(j['measuredAt']),
    locationConfirmed: j['locationConfirmed'] ?? false,
    job: JobStatus.values.byName(j['job'] ?? 'queued'),
    attempts: j['attempts'] ?? 0,
    error: j['error'],
    durationMs: j['durationMs'],
    rating: j['rating'],
    failureCategory: j['failureCategory'],
    runtime: j['runtime'],
    mealRevision: j['mealRevision'] ?? 0,
    memoryRevision: j['memoryRevision'] ?? 0,
    demo: j['demo'] ?? false,
    plateReviews: (j['plateReviews'] as Map<String, dynamic>? ?? {}).map(
      (id, review) =>
          MapEntry(id, PlateReview.fromJson(Map<String, dynamic>.from(review))),
    ),
  );
}

/// Food ratings are independent of segmentation-quality evaluations.
class PlateReview {
  const PlateReview({this.stars, this.note = '', this.name = ''});
  final int? stars;
  final String note, name;
  Map<String, dynamic> toJson() => {'stars': stars, 'note': note, 'name': name};
  factory PlateReview.fromJson(Map<String, dynamic> json) => PlateReview(
    stars: json['stars'] as int?,
    note: json['note'] as String? ?? '',
    name: json['name'] as String? ?? '',
  );
}

/// A library entry references its source meal, so its restaurant and date stay attached.
class LibraryPlate {
  const LibraryPlate(this.memory, this.plateId, this.path);
  final Memory memory;
  final String plateId, path;
  String get key => '${memory.id}/$plateId';
  Plate? get sourcePlate =>
      memory.plates.where((plate) => plate.id == plateId).firstOrNull;
  int get rotationSteps => sourcePlate?.rotationSteps ?? 0;
  double get aspect => sourcePlate?.aspect ?? 1;
  PlateReview get review => memory.plateReviews[plateId] ?? const PlateReview();
  String get title => review.name.isNotEmpty
      ? review.name
      : memory.plates.length > 1
      ? 'Plate ${memory.plates.indexWhere((p) => p.id == plateId) + 1}'
      : memory.caption.isNotEmpty
      ? memory.caption
      : 'Untitled plate';
  static List<LibraryPlate> fromMemories(Iterable<Memory> memories) => [
    for (final memory in memories.where((m) => !m.archived && !m.draft))
      if (memory.plates.isNotEmpty)
        for (final plate in memory.plates.where((p) => p.path.isNotEmpty))
          LibraryPlate(memory, plate.id, plate.path)
      else if (memory.cutout?.isNotEmpty == true)
        LibraryPlate(memory, '__cutout__', memory.cutout!),
  ];
}

class SyncOperation {
  SyncOperation({
    required this.id,
    required this.scope,
    required this.entity,
    required this.payload,
    this.attempts = 0,
    this.error,
    this.nextAttempt,
  });
  final String id, scope, entity;
  final Map<String, dynamic> payload;
  final int attempts;
  final String? error;
  final DateTime? nextAttempt;
}
