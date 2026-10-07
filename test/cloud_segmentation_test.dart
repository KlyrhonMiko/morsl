import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:morsl/data/models.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/plates.dart';

class StreamingClient extends http.BaseClient {
  StreamingClient(this.response);
  final Future<http.StreamedResponse> Function() response;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response();
  @override
  void close() => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String original;
  late Map<String, dynamic> fixture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cloud-plates-');
    original = '${directory.path}/original.png';
    final photo = img.Image(width: 10, height: 20, numChannels: 3);
    for (final pixel in photo) {
      pixel.setRgb(pixel.x * 10, pixel.y * 10, 60);
    }
    await File(original).writeAsBytes(img.encodePng(photo));
    fixture =
        jsonDecode(await File('test/fixtures/cloud_plates.json').readAsString())
            as Map<String, dynamic>;
  });
  tearDown(() async => directory.delete(recursive: true));
  CloudSegmentation engine(http.Client client) => CloudSegmentation(
    clientFactory: () => client,
    accessToken: () => 'user-session',
  )..uploadsAllowed = true;

  test(
    'real server fixture yields cropped transparency and unchanged RGB',
    () async {
      final source = await File(original).readAsBytes();
      final cloud = engine(
        MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer user-session');
          expect(
            request.headers['content-type'],
            startsWith('multipart/form-data;'),
          );
          expect(
            latin1.decode(request.bodyBytes),
            contains('name="image"; filename="image.png"'),
          );
          return http.Response(jsonEncode(fixture), 200);
        }),
      );
      final plates = await cloud.subjects(original, directory.path);
      final plate = plates.single;
      expect(
        [plate.left, plate.top, plate.width, plate.height],
        [.2, .25, .5, .5],
      );
      expect(plate.aspect, .5);
      final result = img.decodePng(await File(plate.path).readAsBytes())!;
      expect([result.width, result.height], [5, 10]);
      expect(result.getPixel(1, 3).a, 0);
      expect(result.getPixel(0, 0).a, 255);
      expect(result.getPixel(0, 0).r, 20);
      expect(result.getPixel(0, 0).g, 50);
      expect(await File(original).readAsBytes(), source);
    },
  );

  test('selection-relative bounds map back into the original photo', () async {
    final cloud = engine(
      MockClient((_) async => http.Response(jsonEncode(fixture), 200)),
    );
    final plates = await cloud.subjects(
      original,
      directory.path,
      region: Plate(
        id: 'selection',
        mask: solidPlateMask(),
        left: .2,
        top: .1,
        width: .5,
        height: .8,
      ),
    );
    expect(plates.single.left, closeTo(.3, .00001));
    expect(plates.single.top, closeTo(.3, .00001));
    expect(plates.single.width, .25);
    expect(plates.single.height, .4);
  });

  test('busy response retries once after server cooldown', () async {
    var sends = 0;
    final waits = <Duration>[];
    final cloud = CloudSegmentation(
      accessToken: () => 'session',
      waitBeforeRetry: (delay) async {
        waits.add(delay);
      },
      clientFactory: () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer session');
        sends++;
        if (sends == 1) {
          return http.Response('busy', 429, headers: {'retry-after': '60'});
        }
        return http.Response(jsonEncode(fixture), 200);
      }),
    )..uploadsAllowed = true;
    expect(await cloud.subjects(original, directory.path), hasLength(1));
    expect(sends, 2);
    expect(waits, [const Duration(seconds: 60)]);
  });

  test(
    'busy retry is bounded and respects upload opt-out while waiting',
    () async {
      for (final optOut in [false, true]) {
        var sends = 0;
        late CloudSegmentation cloud;
        cloud = CloudSegmentation(
          accessToken: () => 'session',
          waitBeforeRetry: (_) async {
            if (optOut) cloud.uploadsAllowed = false;
          },
          clientFactory: () => MockClient((_) async {
            sends++;
            return http.Response('busy', 429, headers: {'retry-after': '5'});
          }),
        )..uploadsAllowed = true;
        await expectLater(
          cloud.subjects(original, directory.path),
          throwsStateError,
        );
        expect(sends, optOut ? 1 : 2);
      }
    },
  );

  test(
    'inference failures do not automatically submit duplicate GPU work',
    () async {
      for (final status in [401, 403, 413, 503, 504]) {
        var sends = 0;
        final cloud = CloudSegmentation(
          accessToken: () => 'session',
          waitBeforeRetry: (_) async {
            fail('Unexpected retry');
          },
          clientFactory: () => MockClient((_) async {
            sends++;
            return http.Response('failed', status);
          }),
        )..uploadsAllowed = true;
        await expectLater(
          cloud.subjects(original, directory.path),
          throwsStateError,
        );
        expect(sends, 1);
      }
    },
  );

  test('no upload occurs before consent or without a session', () async {
    var sends = 0;
    final cloud = CloudSegmentation(
      clientFactory: () => MockClient((_) async {
        sends++;
        return http.Response('{}', 200);
      }),
      accessToken: () => 'session',
    );
    await expectLater(
      cloud.subjects(original, directory.path),
      throwsStateError,
    );
    expect(await cloud.available(), false);
    final guest = CloudSegmentation()..uploadsAllowed = true;
    await expectLater(
      guest.subjects(original, directory.path),
      throwsStateError,
    );
    expect(sends, 0);
  });

  test(
    'timeouts cover stalled upload and stalled response and close the client',
    () async {
      for (final stalledBody in [false, true]) {
        final stream = StreamController<List<int>>();
        final client = StreamingClient(
          () => stalledBody
              ? Future.value(http.StreamedResponse(stream.stream, 200))
              : Completer<http.StreamedResponse>().future,
        );
        final cloud = CloudSegmentation(
          clientFactory: () => client,
          accessToken: () => 'session',
          requestTimeout: const Duration(milliseconds: 20),
        )..uploadsAllowed = true;
        await expectLater(
          cloud.subjects(original, directory.path),
          throwsA(isA<TimeoutException>()),
        );
        expect(client.closed, true);
        unawaited(stream.close());
      }
    },
  );

  test(
    'malformed protocol, bounds, and grayscale masks are rejected',
    () async {
      final cases = [
        {...fixture, 'version': 2},
        {
          ...fixture,
          'plates': [
            {
              'bounds': [.9, .1, .5, .5],
              'mask': fixture['plates'][0]['mask'],
            },
          ],
        },
        {
          ...fixture,
          'plates': [
            {
              'bounds': [.2, .25, .5, .5],
              'mask': base64Encode(
                img.encodePng(img.Image(width: 5, height: 10, numChannels: 1)),
              ),
            },
          ],
        },
      ];
      for (final response in cases) {
        final cloud = engine(
          MockClient((_) async => http.Response(jsonEncode(response), 200)),
        );
        await expectLater(
          cloud.subjects(original, directory.path),
          throwsFormatException,
        );
      }
    },
  );

  test('availability checks the authenticated endpoint and protocol', () async {
    final cloud = engine(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/health');
        return http.Response('{"version":1,"model":"sam3","ready":true}', 200);
      }),
    );
    expect(await cloud.available(), true);
    final unavailable = engine(
      MockClient((_) async => http.Response('unavailable', 503)),
    );
    expect(await unavailable.available(), false);
  });
}
