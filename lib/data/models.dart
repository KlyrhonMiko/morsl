import 'dart:convert';

enum JobStatus { queued, processing, ready, failed }

class Memory {
  Memory({
    required this.id,
    required this.scope,
    required this.createdAt,
    required this.original,
    this.thumbnail,
    this.cutout,
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
  String get displayPath => !useOriginal && cutout != null ? cutout! : original;
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
