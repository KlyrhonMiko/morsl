import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/venue_location.dart';
import 'theme.dart';
import 'cloud_cutouts.dart';
import 'account_gate.dart';
import 'location_access.dart';
import 'sharing.dart';

void message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Palette.forest,
    ),
  );
}

Future<void> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      message(context, e.toString().replaceFirst('Bad state: ', ''));
    }
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<void> showCapture(
  BuildContext context,
  MorslController app,
  void Function(Memory) onOpen, {
  LocationAccessService locationAccess = const LocationAccessService(),
}) async {
  if (app.isCapturing) return;
  if (!await requireGoogleSignIn(context, app) || !context.mounted) return;
  await ensureLocationAccess(context, service: locationAccess);
  if (!context.mounted || !app.canMutate) return;
  final choice = await showModalBottomSheet<(ImageSource, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => const CaptureSheet(),
  );
  if (choice == null || !context.mounted || app.isCapturing) {
    return;
  }
  await guarded(context, () async {
    final progress = ValueNotifier<(int, int)?>(null);
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    final feedback = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(days: 1),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Palette.forest,
        dismissDirection: DismissDirection.none,
        content: PhotoImportFeedback(progress: progress),
      ),
    );
    final Memory? m;
    try {
      m = await app.capture(
        choice.$1,
        locate: choice.$2 && choice.$1 == ImageSource.camera,
        onImportProgress: (saved, total) => progress.value = (saved, total),
      );
    } finally {
      feedback.close();
      unawaited(feedback.closed.then((_) => progress.dispose()));
    }
    if (m != null && context.mounted) {
      final savedMemory = m;
      app.navigate(2);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${m.originals.length == 1 ? 'Photo' : '${m.originals.length} photos'} saved in Drafts. Enjoy your meal.',
          ),
          action: SnackBarAction(
            label: 'Edit now',
            onPressed: () {
              if (!context.mounted || app.scope != savedMemory.scope) return;
              final current = app.memories
                  .where((memory) => memory.id == savedMemory.id)
                  .firstOrNull;
              if (current != null) onOpen(current);
            },
          ),
        ),
      );
    }
  });
}

class PhotoImportFeedback extends StatelessWidget {
  const PhotoImportFeedback({super.key, required this.progress});

  final ValueNotifier<(int, int)?> progress;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<(int, int)?>(
    valueListenable: progress,
    builder: (context, value, _) {
      final saved = value?.$1 ?? 0;
      final total = value?.$2;
      final savingDraft = total != null && saved == total;
      return Semantics(
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              total == null
                  ? 'Preparing photos…'
                  : savingDraft
                  ? 'Saving your draft…'
                  : 'Importing ${total == 1 ? 'photo' : '$total photos'}…',
            ),
            if (total != null) ...[
              const SizedBox(height: 4),
              Text('$saved of $total ${total == 1 ? 'photo' : 'photos'} saved'),
            ],
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: total == null || savingDraft ? null : saved / total,
              color: Palette.paper,
              backgroundColor: Palette.paper.withValues(alpha: .2),
              semanticsLabel: 'Photo import progress',
            ),
          ],
        ),
      );
    },
  );
}

class CaptureSheet extends StatefulWidget {
  const CaptureSheet({super.key});
  @override
  State<CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends State<CaptureSheet> {
  bool location = false, guidance = true;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Bring a little bite with you'),
          const SizedBox(height: 12),
          const Handwriting('What’s on your table?', size: 36),
          const SizedBox(height: 12),
          const Text(
            'Snap your meal or choose several photos from the same visit. We’ll save them together and generate cutouts so you can edit later.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 20),
          if (guidance)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Palette.sage,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.filter_center_focus,
                    size: 30,
                    color: Palette.forest,
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Try a view from above, with the whole meal in frame. Any angle is welcome.',
                      style: TextStyle(fontSize: 12, color: Palette.forest),
                    ),
                  ),
                ],
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'A little top-down guidance',
              style: TextStyle(fontSize: 13),
            ),
            value: guidance,
            onChanged: (v) => setState(() => guidance = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Save approximate location',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: const Text(
              'Optional. Confirm it later before adding a map pin.',
              style: TextStyle(fontSize: 11, color: Palette.muted),
            ),
            value: location,
            onChanged: (v) => setState(() => location = v),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.pop(context, (ImageSource.camera, location)),
              icon: const Icon(Icons.camera_alt_outlined, size: 20),
              label: const Text('Take a photo'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () =>
                  Navigator.pop(context, (ImageSource.gallery, false)),
              icon: const Icon(Icons.photo_library_outlined, size: 20),
              label: const Text('Choose from photos'),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> shareFile(BuildContext context, String file, String title) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file)],
      title: title,
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

Future<String?> showInvite(
  BuildContext context,
  MorslController app,
  Memory memory,
) async {
  if (memory.demo) {
    message(
      context,
      'Example memories stay on this device. Capture a real meal to invite someone.',
    );
    return null;
  }
  if (!app.canMutate) return null;
  final recipient = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => MealShareSheet(app: app, memory: memory),
  );
  if (recipient != null && context.mounted) {
    message(context, 'Invitation sent. Photos stay private until they accept.');
  }
  return recipient;
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late MorslController app;
  late String accountScope;
  bool working = false;
  @override
  void initState() {
    super.initState();
    app = ref.read(appProvider);
    accountScope = app.scope;
    app.addListener(changed);
  }

  void changed() {
    if (mounted) {
      setState(() {
        if (accountScope != app.scope) {
          accountScope = app.scope;
        }
      });
    }
  }

  @override
  void dispose() {
    app.removeListener(changed);
    super.dispose();
  }

  Future<void> auth() async {
    setState(() => working = true);
    await guarded(context, app.signInWithGoogle);
    if (mounted) setState(() => working = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Your little world', style: TextStyle(fontSize: 17)),
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Handwriting(
                'Keep your memories close.',
                size: 38,
                color: Palette.forest,
              ),
              const SizedBox(height: 12),
              const Text(
                'Browse freely. Sign in with Google to capture, edit, and share.',
                style: TextStyle(color: Palette.muted),
              ),
              const SizedBox(height: 30),
              const Eyebrow('Your account'),
              const SizedBox(height: 16),
              if (app.authError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    app.authError!,
                    style: const TextStyle(color: Palette.terracotta),
                  ),
                ),
              if (!app.cloud.configured)
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Palette.sage,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'You can browse the example scrapbook. Google sign-in must be configured before capturing, editing, or sharing meals.',
                    style: TextStyle(fontSize: 13, color: Palette.forest),
                  ),
                ),
              if (app.cloud.configured && !app.canMutate) ...[
                FilledButton(
                  onPressed: working ? null : auth,
                  child: Text(
                    working ? 'Opening Google…' : 'Continue with Google',
                  ),
                ),
              ],
              if (app.canMutate) ...[
                Text(
                  app.cloud.email ?? 'Signed in',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  '${app.operations.length} pending backup · ${app.busySync ? 'Syncing…' : 'Local saves available immediately'}',
                  style: const TextStyle(fontSize: 12, color: Palette.muted),
                ),
                if (app.syncError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      app.syncError!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Palette.terracotta,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => FriendsScreen(app: app),
                        ),
                      ),
                      icon: const Icon(Icons.people_outline_rounded, size: 18),
                      label: const Text('Friends'),
                    ),
                    FilledButton.icon(
                      onPressed: app.busySync
                          ? null
                          : () => guarded(context, () async {
                              await app.sync(manual: true);
                              if (app.syncError != null) {
                                throw StateError(app.syncError!);
                              }
                            }),
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('Back up & restore'),
                    ),
                    OutlinedButton(
                      onPressed: () => guarded(context, () async {
                        final guest = (await app.repository.list(
                          'guest',
                        )).where((m) => !m.demo).length;
                        if (!context.mounted) {
                          return;
                        }
                        if (guest == 0) {
                          message(context, 'No local guest memories to add.');
                          return;
                        }
                        final approved = await confirm(
                          context,
                          'Add $guest local memories to this account?',
                          'These memories will belong to ${app.cloud.email} and will be backed up to this account.',
                          'Add my memories',
                        );
                        if (approved) {
                          await app.associateGuest();
                        }
                      }),
                      child: const Text('Add local memories'),
                    ),
                    TextButton(
                      onPressed: () => guarded(context, app.cloud.signOut),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 30),
              const Divider(),
              const SizedBox(height: 24),
              if (app.usesCloudCutouts) ...[
                const Eyebrow('Photo processing'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cloud cutouts'),
                  subtitle: Text(
                    app.cloudCutoutsSignedIn
                        ? 'On by default. Meal photos are sent to Modal for automatic cutouts. Clean up edges afterward if needed.'
                        : 'Sign in for automatic cloud cutouts, then clean up edges if needed.',
                  ),
                  value: app.cloudCutoutsAllowed,
                  onChanged: !app.cloudCutoutsSignedIn
                      ? null
                      : (allowed) => guarded(context, () async {
                          if (allowed) {
                            await requestCloudCutouts(context, app);
                          } else {
                            await app.setCloudCutoutsAllowed(false);
                          }
                        }),
                ),
                const SizedBox(height: 24),
              ],
              const Eyebrow('A gentle nudge'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Evening draft reminder',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Only while you have unfinished memories.',
                  style: TextStyle(fontSize: 11, color: Palette.muted),
                ),
                value: app.reminderEnabled,
                onChanged: !app.canMutate
                    ? null
                    : (v) => guarded(
                        context,
                        () => app.setReminder(
                          v,
                          app.reminderHour,
                          app.reminderMinute,
                        ),
                      ),
              ),
              OutlinedButton.icon(
                onPressed: !app.canMutate
                    ? null
                    : () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: TimeOfDay(
                            hour: app.reminderHour,
                            minute: app.reminderMinute,
                          ),
                        );
                        if (time != null && context.mounted) {
                          await guarded(
                            context,
                            () => app.setReminder(
                              app.reminderEnabled,
                              time.hour,
                              time.minute,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.schedule, size: 17),
                label: Text(
                  TimeOfDay(
                    hour: app.reminderHour,
                    minute: app.reminderMinute,
                  ).format(context),
                ),
              ),
              const SizedBox(height: 30),
              const Divider(),
              const SizedBox(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline, color: Palette.forest),
                title: const Text(
                  'Meal invitations',
                  style: TextStyle(fontSize: 14),
                ),
                trailing: const Icon(Icons.arrow_forward, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const InboxScreen()),
                ),
              ),
              if (app.canMutate && app.memories.any((m) => m.demo))
                TextButton(
                  onPressed: () => guarded(context, app.clearExamples),
                  child: const Text('Clear example scrapbook'),
                ),
              const SizedBox(height: 28),
              const Handwriting(
                'Little bites. Our little history.',
                size: 25,
                color: Palette.muted,
              ),
              const SizedBox(height: 8),
              const Text(
                'morsl · beta 0.1',
                style: TextStyle(fontSize: 10, color: Palette.muted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});
  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  late MorslController app;
  late String accountScope;
  List<Map<String, dynamic>> invitations = [];
  String? error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    app = ref.read(appProvider);
    accountScope = app.scope;
    app.addListener(accountChanged);
    load();
  }

  void accountChanged() {
    if (mounted && accountScope != app.scope) {
      setState(() {
        accountScope = app.scope;
        invitations = [];
        error = null;
        loading = true;
      });
      unawaited(load());
    }
  }

  @override
  void dispose() {
    app.removeListener(accountChanged);
    super.dispose();
  }

  Future<void> load() async {
    final app = ref.read(appProvider);
    final requestScope = app.scope;
    try {
      if (app.cloud.account != null) {
        final fetched = await app.cloud.invitations();
        if (requestScope != app.scope) {
          return;
        }
        invitations = fetched;
      }
    } catch (e) {
      if (requestScope != app.scope) {
        return;
      }
      error = e.toString();
    }
    if (mounted) {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.read(appProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'A seat at the table',
          style: TextStyle(fontSize: 17),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => FriendsScreen(app: app)),
            ),
            icon: const Icon(Icons.people_outline_rounded, size: 18),
            label: const Text('Friends'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Handwriting(
            'Some memories are better shared.',
            size: 35,
            color: Palette.forest,
          ),
          const SizedBox(height: 12),
          const Text(
            'Accept a meal, then make the memory your own.',
            style: TextStyle(color: Palette.muted),
          ),
          const SizedBox(height: 24),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: const TextStyle(color: Palette.terracotta)),
          if (app.cloud.account == null)
            EmptyState(
              icon: Icons.people_outline,
              title: 'There’s a place for you.',
              message: 'Sign in to invite people and receive shared meals.',
              action: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
                child: const Text('Your account'),
              ),
            ),
          if (!loading && app.cloud.account != null && invitations.isEmpty)
            const EmptyState(
              icon: Icons.mail_outline,
              title: 'No invitations just yet.',
              message: 'Open a saved meal and invite someone to your table.',
            ),
          ...invitations.map(
            (i) => Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Palette.sage,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    i['venue'] ?? 'A shared meal',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'From ${i['sender_email']} · ${i['status']}',
                    style: const TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                  if (i['status'] == 'pending') ...[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      children: [
                        FilledButton(
                          onPressed: () => guarded(context, () async {
                            await app.cloud.respond(i['id'], true);
                            await app.sync(manual: true);
                            await load();
                            if (context.mounted) {
                              message(
                                context,
                                'A shared meal, your own memory. Find it in History.',
                              );
                            }
                          }),
                          child: const Text('Accept meal'),
                        ),
                        TextButton(
                          onPressed: () => guarded(context, () async {
                            await app.cloud.respond(i['id'], false);
                            await load();
                          }),
                          child: const Text('Decline'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
