import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/services/venue_location.dart';
import 'package:morsl/ui/theme.dart';
import 'package:morsl/ui/tools.dart';

class VenueTestCloud extends CloudService {
  VenueTestCloud() : super(null, MediaStore());
  final searches = <({String query, double latitude, double longitude})>[];
  Future<List<Map<String, dynamic>>> Function(String)? lookup;
  @override
  bool get configured => true;
  @override
  bool get signedInWithGoogle => true;
  @override
  String get account => 'account';
  @override
  Future<List<Map<String, dynamic>>> venues(
    double lat,
    double lng, {
    String query = '',
  }) {
    searches.add((query: query, latitude: lat, longitude: lng));
    return lookup?.call(query) ??
        Future.value([
          {
            'id': 'geoapify:branch',
            'name': 'Italianis · Greenbelt',
            'address': 'Greenbelt, Makati',
            'latitude': 14.552,
            'longitude': 121.021,
          },
        ]);
  }
}

class NoVenueSegmentation implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async => original;
  @override
  String get runtime => 'test';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MorslDatabase database;
  late MorslController app;
  late VenueTestCloud cloud;
  late Memory memory;
  Memory? saved;
  setUpAll(() async {
    for (final font in ['Quicksand', 'Caveat']) {
      await (FontLoader(
        font,
      )..addFont(rootBundle.load('assets/fonts/$font.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    database = MorslDatabase(NativeDatabase.memory());
    cloud = VenueTestCloud();
    app = MorslController(
      repository: MemoryRepository(database),
      media: MediaStore(),
      engine: NoVenueSegmentation(),
      cloud: cloud,
      reminders: DraftReminders(),
    );
    memory = Memory(
      id: 'meal',
      scope: 'account',
      createdAt: DateTime(2026, 10, 7),
      original: '',
    );
    saved = null;
  });
  tearDown(() async {
    app.dispose();
    await database.close();
  });

  Future<void> open(
    WidgetTester tester, {
    Future<VenueLocation> Function()? locate,
    GlobalKey? previewKey,
  }) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: morslTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                saved = await showModalBottomSheet<Memory>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (_) => VenueSheet(
                    app: app,
                    memory: memory,
                    locate:
                        locate ??
                        () async => (latitude: 14.55, longitude: 121.02),
                  ),
                );
              },
              child: const Text('Choose restaurant'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      previewKey == null ? host : RepaintBoundary(key: previewKey, child: host),
    );
    await tester.tap(find.text('Choose restaurant'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'typing a restaurant finds branches and selecting saves its map pin',
    (tester) async {
      var locationCalls = 0;
      final previewKey = GlobalKey();
      await open(
        tester,
        previewKey: previewKey,
        locate: () async {
          locationCalls++;
          return (latitude: 14.55, longitude: 121.02);
        },
      );
      expect(find.text('Latitude'), findsNothing);
      expect(find.text('Longitude'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Italianis');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(locationCalls, 1);
      expect(cloud.searches.single.query, 'Italianis');
      expect(find.text('Italianis · Greenbelt'), findsOneWidget);
      expect(find.text('Greenbelt, Makati'), findsOneWidget);
      expect(find.text('Powered by Geoapify'), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('output/previews').create(recursive: true);
        await File(
          'output/previews/venue-search.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('Italianis · Greenbelt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm venue'));
      await tester.pumpAndSettle();
      expect(saved!.venue, 'Italianis · Greenbelt');
      expect(saved!.placeId, 'geoapify:branch');
      expect(saved!.latitude, 14.552);
      expect(saved!.longitude, 121.021);
      expect(saved!.hasLocation, isTrue);
      expect(memory.placeId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('photo coordinates avoid asking for device location', (
    tester,
  ) async {
    memory
      ..latitude = 14.6
      ..longitude = 121.1;
    await open(
      tester,
      locate: () async => throw StateError('Should not request location'),
    );
    await tester.enterText(find.byType(TextField), 'Italianis');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(cloud.searches.single.latitude, 14.6);
    expect(cloud.searches.single.longitude, 121.1);
  });

  testWidgets('denied location still allows saving a venue name', (
    tester,
  ) async {
    await open(
      tester,
      locate: () async => throw VenueLocationException(
        LocationAccessStatus.permissionNeeded,
        'Allow location access to find nearby restaurants.',
      ),
    );
    await tester.enterText(find.byType(TextField), 'Home');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.textContaining('Allow location access'), findsOneWidget);
    expect(find.text('Enable location'), findsOneWidget);
    await tester.tap(find.text('Save venue name'));
    await tester.pumpAndSettle();
    expect(saved!.venue, 'Home');
    expect(saved!.hasLocation, isFalse);
    expect(cloud.searches, isEmpty);
  });

  testWidgets('editing a selected venue clears its old map pin', (
    tester,
  ) async {
    memory
      ..venue = 'Old restaurant'
      ..placeId = 'old'
      ..latitude = 14.6
      ..longitude = 121.1
      ..locationConfirmed = true;
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Picnic');
    await tester.pump();
    await tester.tap(find.text('Save venue name'));
    await tester.pumpAndSettle();
    expect(saved!.venue, 'Picnic');
    expect(saved!.placeId, isNull);
    expect(saved!.latitude, isNull);
    expect(saved!.hasLocation, isFalse);
  });

  testWidgets('a slow earlier search cannot replace newer restaurant results', (
    tester,
  ) async {
    final first = Completer<List<Map<String, dynamic>>>();
    final second = Completer<List<Map<String, dynamic>>>();
    cloud.lookup = (query) => query == 'First' ? first.future : second.future;
    await open(tester);
    await tester.enterText(find.byType(TextField), 'First');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Second');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    second.complete([
      {
        'id': 'new',
        'name': 'New restaurant',
        'address': 'Nearby',
        'latitude': 14.55,
        'longitude': 121.02,
      },
    ]);
    await tester.pumpAndSettle();
    first.complete([
      {'id': 'old', 'name': 'Old result'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('New restaurant'), findsOneWidget);
    expect(find.text('Old result'), findsNothing);
  });
}
