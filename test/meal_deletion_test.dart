import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/editor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DeletionCloud extends CloudService {
  DeletionCloud(super.client, super.media);
  final cleanup = Completer<void>();
  bool cleanupStarted = false;
  @override
  bool get signedInWithGoogle => true;
  @override
  String get account => 'account';
  @override
  Future<void> cleanupImages({String? meal}) {
    cleanupStarted = true;
    return cleanup.future;
  }
}

class PendingDeletionCloud extends DeletionCloud {
  PendingDeletionCloud(super.client, super.media);
  final deletion = Completer<void>();
  @override
  Future<void> deleteMeal(String meal) => deletion.future;
}

class DeletionEngine implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async => original;
  @override
  String get runtime => 'test';
}

class DeletionController extends MorslController {
  DeletionController({
    required super.repository,
    required super.media,
    required super.cloud,
  }) : super(engine: DeletionEngine(), reminders: DraftReminders());
  @override
  Future<void> removeLocal(Memory memory) async {
    await repository.remove(memory.id, memory.scope);
    await reload();
  }
}

void main() {
  test('confirmed cloud deletion does not wait for image cleanup', () async {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient(
        (request) async => http.Response('', 204, request: request),
      ),
    );
    final cloud = DeletionCloud(client, MediaStore());
    try {
      await cloud.deleteMeal('meal').timeout(const Duration(seconds: 2));
      expect(cloud.cleanupStarted, true);
      expect(cloud.cleanup.isCompleted, false);
    } finally {
      cloud.cleanup.complete();
      await client.dispose();
    }
  });
  testWidgets('deletion gives immediate feedback and closes when confirmed', (
    tester,
  ) async {
    final db = MorslDatabase(NativeDatabase.memory());
    final media = MediaStore();
    final cloud = PendingDeletionCloud(null, media);
    final app = DeletionController(
      repository: MemoryRepository(db),
      media: media,
      cloud: cloud,
    );
    addTearDown(() async {
      app.dispose();
      cloud.cleanup.complete();
      await db.close();
    });
    final memory = Memory(
      id: 'meal',
      scope: 'account',
      creator: 'account',
      createdAt: DateTime(2026),
      original: File('assets/images/salad.jpg').absolute.path,
      job: JobStatus.ready,
    );
    await tester.runAsync(() => app.repository.save(memory, enqueue: false));
    app.memories = [memory];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appProvider.overrideWithValue(app)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlatingEditor(memory: memory),
                  ),
                ),
                child: const Text('Open meal'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Memory actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete meal'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete meal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Deleting meal…'), findsWidgets);
    expect(find.text('Finish & save'), findsNothing);
    await tester.runAsync(() async {
      cloud.deletion.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(PlatingEditor), findsNothing);
    expect(find.text('Meal deleted.'), findsOneWidget);
    expect(app.memories, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
