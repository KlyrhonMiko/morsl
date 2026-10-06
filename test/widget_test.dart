import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_map/flutter_map.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/main.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/plates.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/editor.dart';
import 'package:morsl/ui/plate_library.dart';
import 'package:morsl/ui/composition_editor.dart';
import 'package:morsl/services/creations.dart';
import 'package:morsl/ui/theme.dart';
import 'package:morsl/ui/home.dart';
import 'package:morsl/ui/map_screen.dart';

class LocalTestTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      FileImage(File('assets/images/salad.jpg'));
}

class SwitchingCloud extends CloudService {
  SwitchingCloud(super.client, super.media);
  String? current = 'guest';
  @override
  bool get signedInWithGoogle => current != null;
  @override
  String? get account => current;
}

class UnavailableSegmentation implements SegmentationEngine {
  @override
  Future<bool> available() async => false;
  @override
  Future<String> process(String original, String output) async =>
      throw StateError('Segmentation unavailable');
  @override
  String get runtime => 'test segmentation';
}

class AutomaticDishEngine extends UnavailableSegmentation
    implements MultiSubjectSegmentationEngine {
  AutomaticDishEngine(this.path);
  final String path;
  @override
  Future<List<Plate>> subjects(
    String original,
    String directory, {
    Plate? region,
  }) async => List.generate(
    4,
    (i) => Plate(id: 'dish-$i', path: path, mask: solidPlateMask()),
  );
}

class TestDishMedia extends MediaStore {
  @override
  Future<Directory> directory(String scope, String id) async =>
      Directory.current;
}

class TestExportMedia extends MediaStore {
  @override
  Future<Directory> directory(String scope, String id) =>
      Directory('output/previews').create(recursive: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in ['Quicksand', 'Caveat']) {
      final loader = FontLoader(font)
        ..addFont(rootBundle.load('assets/fonts/$font.ttf'));
      await loader.load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late MorslDatabase db;
  late MorslController app;
  setUp(() {
    db = MorslDatabase(NativeDatabase.memory());
    final media = MediaStore();
    app = MorslController(
      repository: MemoryRepository(db),
      media: media,
      engine: UnavailableSegmentation(),
      cloud: SwitchingCloud(null, media),
      reminders: DraftReminders(),
    );
    app.memories = [
      Memory(
        id: 'a',
        scope: 'guest',
        createdAt: DateTime(2026, 10, 4),
        original: File('assets/images/salad.jpg').absolute.path,
        cutout: File('assets/images/salad-cutout.png').absolute.path,
        useOriginal: false,
        caption: 'The kind of lunch that turns into dinner.',
        venue: 'Wildflour Café',
        companions: ['Jamie', 'Alex'],
        background: 'sage',
        draft: false,
        demo: true,
        bookmarked: true,
        job: JobStatus.ready,
      ),
      Memory(
        id: 'b',
        scope: 'guest',
        createdAt: DateTime(2026, 10, 2),
        original: File('assets/images/pasta.jpg').absolute.path,
        cutout: File('assets/images/pasta-cutout.png').absolute.path,
        useOriginal: false,
        caption: 'A little pasta, a lot of catching up.',
        venue: 'A Mano',
        companions: ['Jamie'],
        background: 'cream',
        layout: 'postcard',
        draft: false,
        demo: true,
        bookmarked: true,
        job: JobStatus.ready,
      ),
      Memory(
        id: 'c',
        scope: 'guest',
        createdAt: DateTime(2026, 9, 30),
        original: File('assets/images/pizza.jpg').absolute.path,
        cutout: File('assets/images/pizza-cutout.png').absolute.path,
        useOriginal: false,
        caption: 'One more slice. Always.',
        venue: 'Gino’s Brick Oven Pizza',
        companions: ['Alex', 'Sam'],
        background: 'rose',
        draft: false,
        demo: true,
        job: JobStatus.ready,
      ),
    ];
  });
  tearDown(() async {
    app.dispose();
    await db.close();
  });
  Widget host(Widget child) => ProviderScope(
    overrides: [appProvider.overrideWithValue(app)],
    child: child,
  );

  testWidgets('editor shows processing feedback and removes it on completion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final memory = app.memories.first..job = JobStatus.processing;
    await tester.runAsync(() async {
      final provider = FileImage(File(memory.original));
      final cacheKey = await provider.obtainKey(const ImageConfiguration());
      final codec = await ui.instantiateImageCodec(
        await File(memory.original).readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      PaintingBinding.instance.imageCache.evict(cacheKey);
      PaintingBinding.instance.imageCache.putIfAbsent(
        cacheKey,
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: frame.image)),
        ),
      );
    });
    final previewKey = GlobalKey();
    await tester.pumpWidget(
      host(
        RepaintBoundary(
          key: previewKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: morslTheme(),
            home: PlatingEditor(memory: memory),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Creating your cutout…'), findsOneWidget);
    expect(find.byKey(const ValueKey('cutout-photo-shimmer')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.runAsync(() async {
      final boundary =
          previewKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('output/previews').create(recursive: true);
      await File(
        'output/previews/cutout-photo-loading.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    memory.job = JobStatus.ready;
    await app.repository.save(memory, enqueue: false);
    await app.reload();
    await tester.pumpAndSettle();
    expect(find.text('Creating your cutout…'), findsNothing);
    expect(find.byKey(const ValueKey('cutout-photo-shimmer')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Geoapify map opens a meal and keeps attribution and offline access',
    (tester) async {
      final memory = app.memories.first
        ..latitude = 14.55
        ..longitude = 121.02
        ..locationConfirmed = true;
      Memory? opened;
      await tester.pumpWidget(
        host(
          MaterialApp(
            home: Scaffold(
              body: MealMap(
                app: app,
                apiKey: 'test-key',
                tileProvider: LocalTestTiles(),
                onOpen: (meal) => opened = meal,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('Powered by Geoapify'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      await tester.tap(find.byTooltip(memory.venue));
      expect(opened?.id, memory.id);
      await tester.tap(find.text('Use offline list'));
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.textContaining('Illustrated preview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'guest capture asks for Google and an editor route remains browse-only',
    (tester) async {
      (app.cloud as SwitchingCloud).current = null;
      final memory = app.memories.first;
      await tester.pumpWidget(host(const MorslApp()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Capture a meal').first);
      await tester.pumpAndSettle();
      expect(find.text('Make it your little world'), findsOneWidget);
      expect(find.text('Keep browsing'), findsOneWidget);
      await tester.tap(find.text('Keep browsing'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        host(MaterialApp(home: PlatingEditor(memory: memory))),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Sign in with Google to start your own scrapbook.'),
        findsOneWidget,
      );
      expect(find.text('Save to library'), findsNothing);
      expect(find.text('Separate dishes'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('history search and primary destinations work on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(const MorslApp()));
    await tester.pumpAndSettle();
    expect(find.text('Your plate library'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Wildflour');
    await tester.pumpAndSettle();
    expect(find.text('Wildflour Café'), findsOneWidget);
    expect(find.text('A Mano'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drafts').last);
    await tester.pumpAndSettle();
    expect(find.text('All caught up.'), findsOneWidget);
    await tester.tap(find.text('Map').last);
    await tester.pumpAndSettle();
    expect(find.text('A little map of your life.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed cutout can be edited and saved without processing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final memory = app.memories.first.copy()
      ..draft = true
      ..cutout = null
      ..job = JobStatus.failed
      ..useOriginal = true;
    await tester.runAsync(() => app.repository.save(memory));
    await tester.pumpWidget(
      host(
        MaterialApp(
          theme: morslTheme(),
          home: PlatingEditor(memory: memory),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save to library'), findsOneWidget);
    await tester.tap(find.text('Save to library'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final saved = await tester.runAsync(() => app.repository.list('guest'));
    expect(saved!.single.draft, true);
    expect(saved.single.original, memory.original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
  testWidgets(
    'large text and reduced motion preserve navigation and editor controls',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget accessible(Widget child) => MediaQuery(
        data: const MediaQueryData(
          size: Size(375, 812),
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: child,
      );
      await tester.pumpWidget(
        host(
          MaterialApp(theme: morslTheme(), home: accessible(const MorslHome())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('Drafts'), findsOneWidget);
      final memory = app.memories.first.copy()..draft = true;
      await tester.runAsync(() => app.repository.save(memory));
      await tester.pumpWidget(
        host(
          MaterialApp(
            theme: morslTheme(),
            home: accessible(PlatingEditor(memory: memory)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Save to library'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    },
  );
  testWidgets('removing one plate preserves the other plate and autosaves', (
    tester,
  ) async {
    final memory = app.memories.first.copy()
      ..plates = [
        Plate(
          id: 'one',
          mask: solidPlateMask(),
          path: app.memories.first.cutout!,
          x: .1,
        ),
        Plate(
          id: 'two',
          mask: solidPlateMask(),
          path: app.memories.first.cutout!,
          x: .6,
          rotation: .4,
        ),
      ]
      ..useOriginal = false;
    await tester.runAsync(() => app.repository.save(memory));
    await tester.pumpWidget(
      host(
        MaterialApp(
          theme: morslTheme(),
          home: PlatingEditor(memory: memory),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Plate 1'));
    await tester.tap(find.text('Plate 1'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Remove plate'));
    await tester.tap(find.text('Remove plate'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(
      () => app.repository.list('guest'),
    ))!.single;
    expect(saved.plates.single.id, 'two');
    expect(saved.plates.single.x, .6);
    expect(saved.plates.single.rotation, .4);
    expect(saved.platesEdited, true);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'automatic separation replaces a merged cutout and supports undo',
    (tester) async {
      final memory = app.memories.first.copy()
        ..plates = [
          Plate(
            id: 'merged',
            path: app.memories.first.cutout!,
            mask: solidPlateMask(),
            x: .37,
          ),
        ]
        ..useOriginal = false;
      app.dispose();
      final media = TestDishMedia();
      app = MorslController(
        repository: MemoryRepository(db),
        media: media,
        engine: AutomaticDishEngine(memory.cutout!),
        cloud: SwitchingCloud(null, media),
        reminders: DraftReminders(),
      )..memories = [memory];
      await tester.runAsync(() => app.repository.save(memory));
      await tester.pumpWidget(
        host(
          MaterialApp(
            theme: morslTheme(),
            home: PlatingEditor(memory: memory),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Separate dishes'));
      await tester.tap(find.text('Separate dishes'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpAndSettle();
      var saved = (await tester.runAsync(
        () => app.repository.list('guest'),
      ))!.single;
      expect(saved.plates.map((p) => p.id), [
        'dish-0',
        'dish-1',
        'dish-2',
        'dish-3',
      ]);
      expect(find.text('Review plates'), findsNothing);
      expect(find.text('4 dishes separated'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      saved = (await tester.runAsync(
        () => app.repository.list('guest'),
      ))!.single;
      expect(saved.plates.single.id, 'merged');
      expect(saved.plates.single.x, .37);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('switching accounts hides an already open private memory', (
    tester,
  ) async {
    final memory = app.memories.first.copy();
    await tester.runAsync(() => app.repository.save(memory));
    await tester.pumpWidget(
      host(
        MaterialApp(
          theme: morslTheme(),
          home: PlatingEditor(memory: memory),
        ),
      ),
    );
    await tester.pumpAndSettle();
    (app.cloud as SwitchingCloud).current = 'another-account';
    await tester.runAsync(app.reload);
    await tester.pumpAndSettle();
    expect(
      find.text('This memory is no longer in this scrapbook.'),
      findsOneWidget,
    );
    expect(find.text(memory.caption), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
  testWidgets('revocation closes the visible content of an open editor', (
    tester,
  ) async {
    final memory = app.memories.first.copy();
    await tester.runAsync(() => app.repository.save(memory));
    await tester.pumpWidget(
      host(
        MaterialApp(
          theme: morslTheme(),
          home: PlatingEditor(memory: memory),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save to library'), findsOneWidget);
    await tester.runAsync(() async {
      await app.repository.remove(memory.id, 'guest');
      await app.reload();
    });
    await tester.pumpAndSettle();
    expect(
      find.text('This memory is no longer in this scrapbook.'),
      findsOneWidget,
    );
    expect(find.text('Save to library'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
  testWidgets(
    'rate one plate without changing the other plates from its meal',
    (tester) async {
      final memory = app.memories.first
        ..plates = [
          Plate(id: 'first', mask: '', path: app.memories.first.cutout!),
          Plate(id: 'second', mask: '', path: app.memories.first.cutout!),
        ];
      await tester.runAsync(() => app.repository.save(memory, enqueue: false));
      app.memories = [memory];
      await tester.pumpWidget(
        host(MaterialApp(theme: morslTheme(), home: const MorslHome())),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlateTile), findsNWidgets(2));
      await tester.ensureVisible(find.text('Plate 1'));
      await tester.tap(find.text('Plate 1'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('4 stars'));
      await tester.tap(find.byTooltip('4 stars'));
      await tester.enterText(find.byType(TextField).first, 'Favorite salad');
      await tester.enterText(find.byType(TextField).last, 'Fresh and crisp');
      await tester.ensureVisible(find.text('Save plate'));
      await tester.tap(find.text('Save plate'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      final saved = await tester.runAsync(() => app.repository.list('guest'));
      expect(saved!.single.plateReviews['first']!.stars, 4);
      expect(saved.single.plateReviews['first']!.note, 'Fresh and crisp');
      expect(saved.single.plateReviews.containsKey('second'), false);
      expect(find.text('Favorite salad'), findsOneWidget);
      expect(find.text('4/5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('save and reopen a photo assembled from different meals', (
    tester,
  ) async {
    final entries = LibraryPlate.fromMemories(app.memories).take(2).toList();
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: CompositionEditor(app: app, initialPlates: entries),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Original photo'), findsNothing);
    expect(find.text('Layout'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Weekend favorites');
    await tester.tap(find.text('Save photo'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    final saved = await tester.runAsync(
      () => CreationStore(app.repository, app.scope).list(),
    );
    expect(saved!.single.plates.map((p) => p.key), entries.map((p) => p.key));
    expect(saved.single.title, 'Weekend favorites');
    final creation = saved.single.copy()..plates.first.x = .3;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        theme: morslTheme(),
        home: CompositionEditor(app: app, creation: creation),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Weekend favorites'), findsOneWidget);
    expect(find.byType(PlateImage), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'export a photo with real plates and no editor selection outline',
    (tester) async {
      final exportApp = MorslController(
        repository: app.repository,
        media: TestExportMedia(),
        engine: app.engine,
        cloud: app.cloud,
        reminders: app.reminders,
      )..memories = app.memories;
      addTearDown(exportApp.dispose);
      final entries = LibraryPlate.fromMemories(app.memories).take(2).toList();
      await tester.runAsync(() async {
        for (final entry in entries) {
          final provider = FileImage(File(entry.path));
          final key = await provider.obtainKey(const ImageConfiguration());
          final codec = await ui.instantiateImageCodec(
            await File(entry.path).readAsBytes(),
          );
          final frame = await codec.getNextFrame();
          PaintingBinding.instance.imageCache.evict(key);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image)),
            ),
          );
        }
      });
      String? exported;
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            exported =
                ((call.arguments as Map)['paths'] as List).single as String;
            return 'test-share-target';
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: morslTheme(),
          home: CompositionEditor(app: exportApp, initialPlates: entries),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export photo'));
      for (var frame = 0; frame < 10 && exported == null; frame++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(exported, isNotNull);
      final photo = await tester.runAsync(
        () async => img.decodePng(await File(exported!).readAsBytes())!,
      );
      expect(photo!.width, 1600);
      expect(photo.height, 1600);
      final corner = photo.getPixel(96, 96);
      expect([corner.r, corner.g, corner.b], [238, 233, 223]);
      final plateCenter = photo.getPixel(416, 416);
      expect([
        plateCenter.r,
        plateCenter.g,
        plateCenter.b,
      ], isNot([238, 233, 223]));
      expect(
        (await tester.runAsync(
          () => CreationStore(app.repository, app.scope).list(),
        ))!.single.plates.length,
        2,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(1200, 1000), const Size(375, 812)]) {
    testWidgets('render plate photo editor at ${size.width.toInt()}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entries = LibraryPlate.fromMemories(app.memories).take(2).toList();
      await tester.runAsync(() async {
        for (final entry in entries) {
          final provider = FileImage(File(entry.path));
          final cacheKey = await provider.obtainKey(const ImageConfiguration());
          final codec = await ui.instantiateImageCodec(
            await File(entry.path).readAsBytes(),
          );
          final frame = await codec.getNextFrame();
          PaintingBinding.instance.imageCache.evict(cacheKey);
          PaintingBinding.instance.imageCache.putIfAbsent(
            cacheKey,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image)),
            ),
          );
        }
      });
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: morslTheme(),
            home: CompositionEditor(app: app, initialPlates: entries),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((image) => image.image != null)
            .length,
        2,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('output/previews').create(recursive: true);
        await File(
          'output/previews/plate-photo-${size.width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }

  testWidgets('render the Plating editor', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final memory = app.memories.first.copy()..draft = true;
    await tester.runAsync(() async {
      await app.repository.save(memory);
      final provider = FileImage(File(memory.displayPath));
      final cacheKey = await provider.obtainKey(const ImageConfiguration());
      final codec = await ui.instantiateImageCodec(
        await File(memory.displayPath).readAsBytes(),
        targetWidth: 900,
      );
      final frame = await codec.getNextFrame();
      PaintingBinding.instance.imageCache.evict(cacheKey);
      PaintingBinding.instance.imageCache.putIfAbsent(
        cacheKey,
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: frame.image)),
        ),
      );
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      host(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: morslTheme(),
            home: PlatingEditor(memory: memory),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('output/previews').create(recursive: true);
      await File(
        'output/previews/plating-1200.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
  for (final size in [
    const Size(1440, 1000),
    const Size(375, 812),
    const Size(812, 375),
  ]) {
    testWidgets(
      'render scrapbook at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          for (final font in ['Quicksand', 'Caveat']) {
            final loader = FontLoader(font)
              ..addFont(rootBundle.load('assets/fonts/$font.ttf'));
            await loader.load();
          }
        });
        final key = GlobalKey();
        await tester.runAsync(() async {
          for (final m in app.memories) {
            final provider = FileImage(File(m.displayPath));
            final cacheKey = await provider.obtainKey(
              const ImageConfiguration(),
            );
            final codec = await ui.instantiateImageCodec(
              await File(m.displayPath).readAsBytes(),
              targetWidth: 700,
            );
            final frame = await codec.getNextFrame();
            PaintingBinding.instance.imageCache.evict(cacheKey);
            PaintingBinding.instance.imageCache.putIfAbsent(
              cacheKey,
              () => OneFrameImageStreamCompleter(
                Future.value(ImageInfo(image: frame.image)),
              ),
            );
          }
        });
        await tester.pumpWidget(
          host(RepaintBoundary(key: key, child: const MorslApp())),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = await Directory(
            'output/previews',
          ).create(recursive: true);
          await File(
            '${dir.path}/history-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
      },
    );
  }
}
