import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/services/venue_location.dart';
import 'package:morsl/ui/theme.dart';
import 'package:morsl/ui/venue_field.dart';
import 'package:morsl/ui/editor.dart';

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
  late TextEditingController venueController;
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
    venueController = TextEditingController();
  });
  tearDown(() async {
    app.dispose();
    venueController.dispose();
    await database.close();
  });

  Future<void> open(
    WidgetTester tester, {
    Future<VenueLocation> Function()? locate,
    GlobalKey? previewKey,
    double fieldTop = 100,
    double keyboardHeight = 0,
  }) async {
    venueController.text = memory.venue;
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: morslTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: fieldTop),
                const Text('Where was it?'),
                VenueField(
                  app: app,
                  memory: saved ?? memory,
                  controller: venueController,
                  locate:
                      locate ??
                      () async => (latitude: 14.55, longitude: 121.02),
                  onChanged: (text) => setState(() {
                    saved = (saved ?? memory).copy()
                      ..venue = text
                      ..placeId = null
                      ..latitude = null
                      ..longitude = null
                      ..locationConfirmed = false;
                  }),
                  onSelected: (candidate) => setState(() {
                    saved = (saved ?? memory).copy()
                      ..venue = venueController.text
                      ..placeId = candidate['id'] as String?
                      ..latitude = (candidate['latitude'] as num).toDouble()
                      ..longitude = (candidate['longitude'] as num).toDouble()
                      ..locationConfirmed = true;
                  }),
                ),
                const Text('Who was at the table?'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      previewKey == null ? host : RepaintBoundary(key: previewKey, child: host),
    );
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
      expect(find.byKey(const ValueKey('venue-suggestions')), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
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
    await tester.tap(find.text('Keep just the name'));
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
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep just the name'));
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

  testWidgets(
    'leaving the field dismisses suggestions and ignores late results',
    (tester) async {
      final pending = Completer<List<Map<String, dynamic>>>();
      cloud.lookup = (_) => pending.future;
      await open(tester);
      await tester.enterText(find.byType(TextField), 'Italianis');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tapAt(const Offset(350, 700));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('venue-suggestions')), findsNothing);
      pending.complete([
        {
          'id': 'late',
          'name': 'Late branch',
          'latitude': 14.55,
          'longitude': 121.02,
        },
      ]);
      await tester.pumpAndSettle();
      expect(find.text('Late branch'), findsNothing);
      expect(saved!.venue, 'Italianis');
      expect(saved!.hasLocation, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'arrow keys and Enter choose a branch without a confirmation step',
    (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'Italianis');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(saved!.placeId, 'geoapify:branch');
      expect(saved!.hasLocation, isTrue);
      expect(find.byKey(const ValueKey('venue-suggestions')), findsNothing);
    },
  );

  testWidgets(
    'suggestions open above the field when the keyboard leaves little room',
    (tester) async {
      await open(tester, fieldTop: 360, keyboardHeight: 260);
      await tester.enterText(find.byType(TextField), 'Italianis');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final suggestions = find.byKey(const ValueKey('venue-suggestions'));
      expect(
        tester.getBottomLeft(suggestions).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(TextField)).dy),
      );
      await tester.tap(find.text('Italianis · Greenbelt'));
      await tester.pumpAndSettle();
      expect(saved!.hasLocation, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a shared meal venue remains read only', (tester) async {
    memory
      ..creator = 'another-account'
      ..venue = 'Shared restaurant';
    await open(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(cloud.searches, isEmpty);
    expect(find.byKey(const ValueKey('venue-suggestions')), findsNothing);
  });

  testWidgets(
    'meal editor autosaves a chosen branch and clears its pin after typing',
    (tester) async {
      memory
        ..latitude = 14.55
        ..longitude = 121.02
        ..original = File('assets/images/salad.jpg').absolute.path
        ..originalProcessed = true
        ..job = JobStatus.ready;
      await tester.runAsync(() async {
        await app.repository.save(memory);
        await app.reload();
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appProvider.overrideWith((ref) => app)],
          child: MaterialApp(
            theme: morslTheme(),
            home: PlatingEditor(memory: memory),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(VenueField),
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, 'Italianis');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Italianis · Greenbelt'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final chosen = await tester.runAsync(
        () => app.repository.list('account'),
      );
      expect(chosen!.single.placeId, 'geoapify:branch');
      expect(chosen.single.hasLocation, isTrue);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.enterText(field, 'Home');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      final edited = await tester.runAsync(
        () => app.repository.list('account'),
      );
      expect(edited!.single.venue, 'Home');
      expect(edited.single.placeId, isNull);
      expect(edited.single.latitude, isNull);
      expect(edited.single.hasLocation, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(tester.takeException(), isNull);
    },
  );
}
