import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Explicit SQL keeps the beta schema readable without generated source files.
class MorslDatabase extends GeneratedDatabase {
  MorslDatabase(super.executor);
  static Future<MorslDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    return MorslDatabase(
      NativeDatabase.createInBackground(File(p.join(dir.path, 'morsl.sqlite'))),
    );
  }

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement(
        'CREATE TABLE meals (id TEXT NOT NULL, scope TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(id, scope))',
      );
      await customStatement(
        'CREATE TABLE personal_memories (meal_id TEXT NOT NULL, scope TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(meal_id, scope))',
      );
      await customStatement(
        'CREATE TABLE meal_assets (id TEXT NOT NULL, scope TEXT NOT NULL, meal_id TEXT NOT NULL, original TEXT NOT NULL, cutout TEXT, thumbnail TEXT, PRIMARY KEY(id, scope))',
      );
      await customStatement(
        'CREATE TABLE processing_jobs (asset_id TEXT NOT NULL, scope TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY(asset_id, scope))',
      );
      await customStatement(
        'CREATE TABLE sync_operations (entity TEXT NOT NULL, scope TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, error TEXT, next_attempt TEXT, PRIMARY KEY(entity, scope))',
      );
      await customStatement(
        'CREATE TABLE evaluations (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, meal_id TEXT NOT NULL, data TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE beta_events (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, data TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
    },
  );
}
