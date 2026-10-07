import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class GoogleCloud extends CloudService {
  GoogleCloud(super.client, super.media, {super.imageClient});
  @override
  bool get signedInWithGoogle => true;
  @override
  String get account => '22222222-2222-4222-8222-222222222222';
}

class FixtureClient extends http.BaseClient {
  FixtureClient(this.handler);
  final Future<http.Response> Function(http.Request) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final normalized = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = body;
    final response = await handler(normalized);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

FixtureClient requestClient(
  Future<http.Response> Function(http.Request) handler,
) => FixtureClient(handler);

void main() {
  const id = '11111111-1111-4111-8111-111111111111';
  const original =
      '$id/$id/r2/original-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg';
  const plateKey =
      '$id/22222222-2222-4222-8222-222222222222/r2/plate-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png';
  http.Response json(Object? data) => http.Response(
    jsonEncode(data),
    200,
    headers: {'content-type': 'application/json'},
  );

  test(
    'restore returns stable references without downloading images or rendering plates',
    () async {
      final requests = <String>[];
      final client = SupabaseClient(
        'https://supabase.example',
        'test-key',
        httpClient: requestClient((request) async {
          requests.add(request.url.path);
          return json([
            Memory(
              id: id,
              scope: 'remote',
              createdAt: DateTime(2026),
              original: original,
              plates: [Plate(id: 'plate', mask: 'mask', cloudPath: plateKey)],
            ).toJson(),
          ]);
        }),
      );
      final media = MediaStore();
      final cloud = GoogleCloud(client, media);
      media.download = (_) async =>
          throw StateError('restore must not download');
      final restored = (await cloud.pull(cloud.account)).single;
      expect(restored.original, MediaStore.remote(original));
      expect(restored.plates.single.path, MediaStore.remote(plateKey));
      expect(restored.job, JobStatus.ready);
      expect(requests, ['/rest/v1/rpc/restore_memories']);
      await client.dispose();
    },
  );

  test(
    'backup commits only after original and finished cutout uploads succeed',
    () async {
      final root = await Directory.systemTemp.createTemp('morsl-upload-');
      final originalFile = await File(
        '${root.path}/original.jpg',
      ).writeAsBytes([1, 2, 3]);
      final plateFile = await File(
        '${root.path}/plate.png',
      ).writeAsBytes([4, 5, 6]);
      final calls = <String>[];
      Map<String, dynamic>? saved;
      final client = SupabaseClient(
        'https://supabase.example',
        'test-key',
        httpClient: requestClient((request) async {
          if (request.url.path.endsWith('reserve_meal')) {
            calls.add('reserve');
            return json(null);
          }
          if (request.url.path.endsWith('image-storage')) {
            final body = jsonDecode(request.body);
            expect(body['size'], 3);
            return json({'url': 'https://r2.example/${body['key']}'});
          }
          calls.add('commit');
          saved = jsonDecode(request.body)['payload'];
          return json({'mealRevision': 1, 'memoryRevision': 1});
        }),
      );
      final images = MockClient((request) async {
        calls.add(request.url.path.contains('plate-') ? 'plate' : 'original');
        expect(request.method, 'PUT');
        return http.Response('', 200);
      });
      final cloud = GoogleCloud(client, MediaStore(), imageClient: images);
      try {
        await cloud.push(
          Memory(
            id: id,
            scope: cloud.account,
            creator: cloud.account,
            createdAt: DateTime(2026),
            original: originalFile.path,
            plates: [Plate(id: 'plate', mask: 'mask', path: plateFile.path)],
          ),
        );
        expect(calls, ['reserve', 'original', 'plate', 'commit']);
        expect(saved!['original'], startsWith('$id/$id/r2/original-'));
        expect(saved!['plates'][0]['cloudPath'], contains('/r2/plate-'));
        expect(saved!['plates'][0].containsKey('path'), false);
        expect(await originalFile.exists(), true);
        expect(await plateFile.exists(), true);
      } finally {
        images.close();
        await client.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'failed upload keeps local originals and never commits remote references',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'morsl-upload-failed-',
      );
      final source = await File(
        '${root.path}/original.jpg',
      ).writeAsBytes([1, 2, 3]);
      var commits = 0;
      final client = SupabaseClient(
        'https://supabase.example',
        'test-key',
        httpClient: requestClient((request) async {
          if (request.url.path.endsWith('reserve_meal')) return json(null);
          if (request.url.path.endsWith('image-storage')) {
            return json({'url': 'https://r2.example/upload'});
          }
          commits++;
          return json({});
        }),
      );
      final images = MockClient((request) async => http.Response('', 503));
      final cloud = GoogleCloud(client, MediaStore(), imageClient: images);
      try {
        await expectLater(
          cloud.push(
            Memory(
              id: id,
              scope: cloud.account,
              creator: cloud.account,
              createdAt: DateTime(2026),
              original: source.path,
            ),
          ),
          throwsStateError,
        );
        expect(commits, 0);
        expect(await source.readAsBytes(), [1, 2, 3]);
      } finally {
        images.close();
        await client.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'metadata-only backup reuses R2 references without touching image bytes',
    () async {
      var uploads = 0;
      Map<String, dynamic>? saved;
      final client = SupabaseClient(
        'https://supabase.example',
        'test-key',
        httpClient: requestClient((request) async {
          if (request.url.path.endsWith('reserve_meal')) return json(null);
          if (request.url.path.endsWith('image-storage')) {
            uploads++;
            return json({});
          }
          saved = jsonDecode(request.body)['payload'];
          return json({'mealRevision': 2, 'memoryRevision': 2});
        }),
      );
      final cloud = GoogleCloud(client, MediaStore());
      await cloud.push(
        Memory(
          id: id,
          scope: cloud.account,
          createdAt: DateTime(2026),
          original: MediaStore.remote(original),
          plates: [
            Plate(
              id: 'plate',
              mask: 'mask',
              path: MediaStore.remote(plateKey),
              cloudPath: plateKey,
            ),
          ],
        ),
      );
      expect(uploads, 0);
      expect(saved!['original'], original);
      expect(saved!['plates'][0]['cloudPath'], plateKey);
      await client.dispose();
    },
  );
}
