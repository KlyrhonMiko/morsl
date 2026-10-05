import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'controller.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'services/cloud.dart';
import 'services/media.dart';
import 'services/reminders.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MorslBootstrap());
}

class MorslBootstrap extends StatefulWidget {
  const MorslBootstrap({super.key});
  @override
  State<MorslBootstrap> createState() => _MorslBootstrapState();
}

class _MorslBootstrapState extends State<MorslBootstrap> {
  MorslController? app;
  String? error;
  SupabaseClient? cloudClient;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    setState(() => error = null);
    try {
      SupabaseClient? client;
      const url = String.fromEnvironment('SUPABASE_URL');
      const key = String.fromEnvironment('SUPABASE_ANON_KEY');
      if (url.isNotEmpty && key.isNotEmpty && cloudClient == null) {
        await Supabase.initialize(url: url, publishableKey: key);
        cloudClient = Supabase.instance.client;
      }
      client = cloudClient;
      final database = await MorslDatabase.open();
      final media = MediaStore();
      final engine = NativeSegmentation();
      await engine.inspectDevice();
      final controller = MorslController(
        repository: MemoryRepository(database),
        media: media,
        engine: engine,
        cloud: CloudService(client, media),
        reminders: DraftReminders(),
      );
      await controller.initialize();
      unawaited(controller.recoverLostCapture());
      if (mounted) {
        setState(() => app = controller);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) => app == null
      ? MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: morslTheme(),
          home: Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Handwriting(
                        'morsl',
                        size: 76,
                        color: Palette.terracotta,
                      ),
                      const SizedBox(height: 12),
                      const Text('Little bites. Our little history.'),
                      const SizedBox(height: 28),
                      if (error == null)
                        const CircularProgressIndicator(strokeWidth: 2)
                      else ...[
                        Text(
                          'Your scrapbook couldn’t be opened.\n$error',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: initialize,
                          child: const Text('Try again'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        )
      : ProviderScope(
          overrides: [appProvider.overrideWithValue(app!)],
          child: const MorslApp(),
        );
}

class MorslApp extends StatelessWidget {
  const MorslApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'morsl — Little bites. Our little history.',
    debugShowCheckedModeBanner: false,
    theme: morslTheme(),
    home: const MorslHome(),
  );
}
