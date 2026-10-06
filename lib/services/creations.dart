import 'dart:convert';

import '../data/repository.dart';

class PlacedPlate {
  PlacedPlate({
    required this.key,
    this.x = .1,
    this.y = .1,
    this.scale = .4,
    this.rotation = 0,
  });
  final String key;
  double x, y, scale, rotation;
  Map<String, dynamic> toJson() => {
    'key': key,
    'x': x,
    'y': y,
    'scale': scale,
    'rotation': rotation,
  };
  factory PlacedPlate.fromJson(Map<String, dynamic> json) => PlacedPlate(
    key: json['key'],
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    scale: (json['scale'] as num).toDouble(),
    rotation: (json['rotation'] as num).toDouble(),
  );
}

class PlateCreation {
  PlateCreation({
    required this.id,
    required this.updatedAt,
    this.title = 'My plate photo',
    this.background = 'cream',
    required this.plates,
  });
  final String id;
  DateTime updatedAt;
  String title, background;
  List<PlacedPlate> plates;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'background': background,
    'updatedAt': updatedAt.toIso8601String(),
    'plates': plates.map((p) => p.toJson()).toList(),
  };
  factory PlateCreation.fromJson(Map<String, dynamic> json) => PlateCreation(
    id: json['id'],
    title: json['title'],
    background: json['background'],
    updatedAt: DateTime.parse(json['updatedAt']),
    plates: (json['plates'] as List)
        .map((p) => PlacedPlate.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
  );
  PlateCreation copy() => PlateCreation.fromJson(toJson());
}

/// Arrangements stay separate from meals and never alter source plate geometry.
class CreationStore {
  const CreationStore(this.repository, this.scope);
  final MemoryRepository repository;
  final String scope;
  Future<List<PlateCreation>> list() async {
    final data = await repository.preference('plateCreations:v1:$scope');
    if (data == null) return [];
    return (jsonDecode(data) as List)
        .map((j) => PlateCreation.fromJson(Map<String, dynamic>.from(j)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(PlateCreation creation) async {
    final items = await list();
    items.removeWhere((c) => c.id == creation.id);
    items.insert(0, creation);
    await repository.setPreference(
      'plateCreations:v1:$scope',
      jsonEncode(items.map((c) => c.toJson()).toList()),
    );
  }
}
