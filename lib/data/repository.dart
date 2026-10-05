import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import 'database.dart';
import 'models.dart';

class MemoryRepository {
  MemoryRepository(this.db);
  final MorslDatabase db;

  Future<List<Memory>> list(String scope) async {
    final rows = await db
        .customSelect(
          'SELECT p.data FROM personal_memories p WHERE scope = ?',
          variables: [Variable(scope)],
        )
        .get();
    return rows
        .map((r) => Memory.fromJson(jsonDecode(r.read<String>('data'))))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<Memory?> mutate(
    String id,
    String scope,
    void Function(Memory) change, {
    bool enqueue = true,
  }) => db.transaction(() async {
    final row = await db
        .customSelect(
          'SELECT data FROM personal_memories WHERE meal_id=? AND scope=?',
          variables: [Variable(id), Variable(scope)],
        )
        .getSingleOrNull();
    if (row == null) {
      return null;
    }
    final current = Memory.fromJson(jsonDecode(row.read<String>('data')));
    change(current);
    await save(current, enqueue: enqueue);
    return current;
  });
  Future<void> save(Memory memory, {bool enqueue = true}) =>
      db.transaction(() async {
        final j = memory.toJson();
        final meal = {
          for (final k in [
            'id',
            'creator',
            'createdAt',
            'venue',
            'placeId',
            'companions',
            'latitude',
            'longitude',
            'accuracy',
            'measuredAt',
            'locationConfirmed',
            'mealRevision',
          ])
            k: j[k],
        };
        await db.customStatement(
          'INSERT OR REPLACE INTO meals VALUES (?, ?, ?)',
          [memory.id, memory.scope, jsonEncode(meal)],
        );
        await db.customStatement(
          'INSERT OR REPLACE INTO personal_memories VALUES (?, ?, ?)',
          [memory.id, memory.scope, memory.encode()],
        );
        await db.customStatement(
          'INSERT OR REPLACE INTO meal_assets VALUES (?, ?, ?, ?, ?, ?)',
          [
            memory.assetId ?? memory.id,
            memory.scope,
            memory.id,
            memory.original,
            memory.cutout,
            memory.thumbnail,
          ],
        );
        await db.customStatement(
          'INSERT OR REPLACE INTO processing_jobs VALUES (?, ?, ?, ?, ?)',
          [
            memory.assetId ?? memory.id,
            memory.scope,
            memory.job.name,
            memory.attempts,
            jsonEncode({
              'error': memory.error,
              'durationMs': memory.durationMs,
              'runtime': memory.runtime,
            }),
          ],
        );
        if (enqueue && memory.scope != 'guest' && !memory.demo) {
          await db.customStatement(
            'INSERT OR REPLACE INTO sync_operations (entity, scope, id, payload) VALUES (?, ?, ?, ?)',
            [memory.id, memory.scope, const Uuid().v4(), memory.encode()],
          );
        }
      });
  Future<void> remove(String id, String scope) => db.transaction(() async {
    for (final table in [
      'meals',
      'personal_memories',
      'meal_assets',
      'processing_jobs',
      'sync_operations',
    ]) {
      final column = switch (table) {
        'personal_memories' => 'meal_id',
        'meal_assets' => 'meal_id',
        'processing_jobs' => 'asset_id',
        'sync_operations' => 'entity',
        _ => 'id',
      };
      await db.customStatement(
        'DELETE FROM $table WHERE $column = ? AND scope = ?',
        [id, scope],
      );
    }
  });
  Future<List<SyncOperation>> pending(String scope) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM sync_operations WHERE scope = ?',
          variables: [Variable(scope)],
        )
        .get();
    return rows
        .map(
          (r) => SyncOperation(
            id: r.read('id'),
            scope: scope,
            entity: r.read('entity'),
            payload: jsonDecode(r.read('payload')),
            attempts: r.read('attempts'),
            error: r.readNullable('error'),
            nextAttempt: r.readNullable<String>('next_attempt') == null
                ? null
                : DateTime.parse(r.read('next_attempt')),
          ),
        )
        .toList();
  }

  Future<void> complete(SyncOperation op) => db.customStatement(
    'DELETE FROM sync_operations WHERE id = ? AND scope = ?',
    [op.id, op.scope],
  );
  Future<void> fail(SyncOperation op, String error) => db.customStatement(
    'UPDATE sync_operations SET attempts = attempts + 1, error = ?, next_attempt = ? WHERE id = ? AND scope = ?',
    [
      error,
      DateTime.now()
          .add(Duration(seconds: 5 * (1 << op.attempts.clamp(0, 9))))
          .toIso8601String(),
      op.id,
      op.scope,
    ],
  );
  Future<void> evaluate(Memory m) => db.customStatement(
    'INSERT INTO evaluations (scope, meal_id, data) VALUES (?, ?, ?)',
    [
      m.scope,
      m.id,
      jsonEncode({
        'mealId': m.id,
        'at': DateTime.now().toIso8601String(),
        'durationMs': m.durationMs,
        'attempt': m.attempts,
        'status': m.job.name,
        'error': m.error,
        'runtime': m.runtime,
        'rating': m.rating,
        'failureCategory': m.failureCategory,
      }),
    ],
  );
  Future<List<Map<String, dynamic>>> evaluations(String scope) async =>
      (await db
              .customSelect(
                'SELECT data FROM evaluations WHERE scope = ?',
                variables: [Variable(scope)],
              )
              .get())
          .map(
            (r) => jsonDecode(r.read<String>('data')) as Map<String, dynamic>,
          )
          .toList();
  Future<void> event(String scope, String name, Map<String, dynamic> data) =>
      db.customStatement('INSERT INTO beta_events (scope,data) VALUES (?, ?)', [
        scope,
        jsonEncode({
          'event': name,
          'at': DateTime.now().toIso8601String(),
          ...data,
        }),
      ]);
  Future<List<Map<String, dynamic>>> events(String scope) async =>
      (await db
              .customSelect(
                'SELECT data FROM beta_events WHERE scope = ?',
                variables: [Variable(scope)],
              )
              .get())
          .map(
            (r) => jsonDecode(r.read<String>('data')) as Map<String, dynamic>,
          )
          .toList();
  Future<String?> preference(String key) async =>
      (await db
              .customSelect(
                'SELECT value FROM preferences WHERE key = ?',
                variables: [Variable(key)],
              )
              .getSingleOrNull())
          ?.read<String>('value');
  Future<void> setPreference(String key, String value) => db.customStatement(
    'INSERT OR REPLACE INTO preferences VALUES (?, ?)',
    [key, value],
  );
  Future<void> associateGuest(String account) => db.transaction(() async {
    final memories = await list('guest');
    for (final m in memories.where((m) => !m.demo)) {
      await remove(m.id, 'guest');
      m.scope = account;
      m.creator = account;
      await save(m);
    }
  });
}
