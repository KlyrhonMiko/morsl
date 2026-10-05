import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morsl/controller.dart';
import 'package:morsl/data/database.dart';
import 'package:morsl/data/models.dart';
import 'package:morsl/data/repository.dart';
import 'package:morsl/main.dart';
import 'package:morsl/services/cloud.dart';
import 'package:morsl/services/media.dart';
import 'package:morsl/services/reminders.dart';
import 'package:morsl/ui/editor.dart';
import 'package:morsl/ui/theme.dart';
import 'package:morsl/ui/home.dart';

class SwitchingCloud extends CloudService {
  SwitchingCloud(super.client, super.media);
  String? current;
  @override
  String? get account => current;
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
      engine: NativeSegmentation(),
      cloud: SwitchingCloud(null, media),
      reminders: DraftReminders(),
    );
    app.memories = [
      Memory(
        id: 'a',
        scope: 'guest',
        createdAt: DateTime(2026, 10, 4),
        original: File('assets/images/salad.jpg').absolute.path,
        caption: 'The kind of lunch that turns into dinner.',
        venue: 'Wildflour Café',
        companions: ['Jamie', 'Alex'],
        background: 'sage',
        draft: false,
        demo: true,
        bookmarked: true,
        job: JobStatus.failed,
      ),
      Memory(
        id: 'b',
        scope: 'guest',
        createdAt: DateTime(2026, 10, 2),
        original: File('assets/images/pasta.jpg').absolute.path,
        caption: 'A little pasta, a lot of catching up.',
        venue: 'A Mano',
        companions: ['Jamie'],
        background: 'cream',
        layout: 'postcard',
        draft: false,
        demo: true,
        bookmarked: true,
        job: JobStatus.failed,
      ),
      Memory(
        id: 'c',
        scope: 'guest',
        createdAt: DateTime(2026, 9, 30),
        original: File('assets/images/pizza.jpg').absolute.path,
        caption: 'One more slice. Always.',
        venue: 'Gino’s Brick Oven Pizza',
        companions: ['Alex', 'Sam'],
        background: 'rose',
        draft: false,
        demo: true,
        job: JobStatus.failed,
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

  testWidgets('history search and primary destinations work on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(const MorslApp()));
    await tester.pumpAndSettle();
    expect(find.text('Your life, one bite at a time.'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Jamie');
    await tester.pumpAndSettle();
    expect(find.text('2 memories'), findsOneWidget);
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
    final memory = app.memories.first.copy()..draft = true;
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
    expect(find.text('Save memory'), findsOneWidget);
    await tester.tap(find.text('Save memory'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    final saved = await tester.runAsync(() => app.repository.list('guest'));
    expect(saved!.single.draft, false);
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
      expect(find.text('History'), findsOneWidget);
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
      expect(find.text('Save memory'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
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
    expect(find.text('Save memory'), findsOneWidget);
    await tester.runAsync(() async {
      await app.repository.remove(memory.id, 'guest');
      await app.reload();
    });
    await tester.pumpAndSettle();
    expect(
      find.text('This memory is no longer in this scrapbook.'),
      findsOneWidget,
    );
    expect(find.text('Save memory'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
  testWidgets('render the Plating editor', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final memory = app.memories.first.copy()..draft = true;
    await tester.runAsync(() async {
      await app.repository.save(memory);
      final provider = FileImage(File(memory.original));
      final cacheKey = await provider.obtainKey(const ImageConfiguration());
      final codec = await ui.instantiateImageCodec(
        await File(memory.original).readAsBytes(),
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
      await Directory('docs/previews').create(recursive: true);
      await File('docs/previews/plating-1200.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
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
            final provider = ResizeImage.resizeIfNeeded(
              700,
              null,
              FileImage(File(m.original)),
            );
            final cacheKey = await provider.obtainKey(
              const ImageConfiguration(),
            );
            final codec = await ui.instantiateImageCodec(
              await File(m.original).readAsBytes(),
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
          final dir = await Directory('docs/previews').create(recursive: true);
          await File('${dir.path}/history-${size.width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      },
    );
  }
}
