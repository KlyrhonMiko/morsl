import 'dart:convert';

enum JobStatus { queued, processing, ready, failed }

/// An alpha mask over a region of the unchanged original, and its placement.
/// Only the mask and normalized coordinates travel in backup, never local paths.
class Plate {
  Plate({
    required this.id,
    required this.mask,
    this.path = '',
    this.left = 0,
    this.top = 0,
    this.width = 1,
    this.height = 1,
    this.aspect = 1,
    this.x = .2,
    this.y = .15,
    this.scale = .6,
    this.rotation = 0,
  });
  final String id;
  String mask, path;
  double left, top, width, height, aspect, x, y, scale, rotation;
  Map<String, dynamic> toJson({bool local = true}) => {
    'id': id,
    'mask': mask,
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
  };
  Plate copy() => Plate.fromJson(toJson());
  factory Plate.fromJson(Map<String, dynamic> j) => Plate(
    id: j['id'],
    mask: j['mask'],
    path: j['path'] ?? '',
    left: (j['left'] as num?)?.toDouble() ?? 0,
    top: (j['top'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toDouble() ?? 1,
    height: (j['height'] as num?)?.toDouble() ?? 1,
    aspect: (j['aspect'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? .2,
    y: (j['y'] as num?)?.toDouble() ?? .15,
    scale: (j['scale'] as num?)?.toDouble() ?? .6,
    rotation: (j['rotation'] as num?)?.toDouble() ?? 0,
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
    'thumbnail': thumbnail,
    'cutout': cutout,
    'plates': plates.map((plate) => plate.toJson()).toList(),
    'platesEdited': platesEdited,
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
    thumbnail: j['thumbnail'],
    cutout: j['cutout'],
    plates: (j['plates'] as List? ?? [])
        .map((p) => Plate.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
    platesEdited: j['platesEdited'] ?? false,
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
  );
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
