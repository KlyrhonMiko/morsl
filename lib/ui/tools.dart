import 'media_image.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'geoapify_attribution.dart';

import '../controller.dart';
import '../data/models.dart';
import 'theme.dart';
import 'cloud_cutouts.dart';
import 'account_gate.dart';
import 'cutout_status.dart';

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
  void Function(Memory) onOpen,
) async {
  if (!await requireGoogleSignIn(context, app) || !context.mounted) return;
  final choice = await showModalBottomSheet<(ImageSource, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => const CaptureSheet(),
  );
  if (choice == null || !context.mounted) {
    return;
  }
  await guarded(context, () async {
    final m = await app.capture(
      choice.$1,
      locate: choice.$2 && choice.$1 == ImageSource.camera,
    );
    if (m != null && context.mounted) {
      app.navigate(2);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Photo saved in Drafts. Enjoy your meal.'),
          action: SnackBarAction(
            label: 'Edit now',
            onPressed: () {
              if (!context.mounted || app.scope != m.scope) return;
              final current = app.memories
                  .where((memory) => memory.id == m.id)
                  .firstOrNull;
              if (current != null) onOpen(current);
            },
          ),
        ),
      );
    }
  });
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
            'Snap your meal, then enjoy it. We’ll save a draft and generate cutouts so you can edit later.',
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

Future<Memory?> showVenue(
  BuildContext context,
  MorslController app,
  Memory m,
) => showModalBottomSheet<Memory>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => VenueSheet(app: app, memory: m),
);

class VenueSheet extends StatefulWidget {
  const VenueSheet({super.key, required this.app, required this.memory});
  final MorslController app;
  final Memory memory;
  @override
  State<VenueSheet> createState() => _VenueSheetState();
}

class _VenueSheetState extends State<VenueSheet> {
  late TextEditingController venue, lat, lng;
  bool loading = false;
  List<Map<String, dynamic>> candidates = [];
  String? error, place;
  @override
  void initState() {
    super.initState();
    final m = widget.memory;
    venue = TextEditingController(text: m.venue);
    lat = TextEditingController(text: m.latitude?.toString() ?? '');
    lng = TextEditingController(text: m.longitude?.toString() ?? '');
    place = m.placeId;
  }

  @override
  void dispose() {
    venue.dispose();
    lat.dispose();
    lng.dispose();
    super.dispose();
  }

  Future<void> nearby() async {
    final a = double.tryParse(lat.text), b = double.tryParse(lng.text);
    if (a == null || b == null || a.abs() > 90 || b.abs() > 180) {
      setState(() => error = 'Enter valid coordinates or use a typed venue.');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (!widget.app.cloud.configured || widget.app.cloud.account == null) {
        throw StateError(
          'Nearby suggestions need a connected account. You can still type a venue and confirm your own coordinates.',
        );
      }
      final places = await widget.app.cloud.venues(a, b);
      if (mounted) {
        setState(() => candidates = places);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
    if (mounted) {
      setState(() => loading = false);
    }
  }

  void finish() {
    final a = lat.text.isEmpty ? null : double.tryParse(lat.text),
        b = lng.text.isEmpty ? null : double.tryParse(lng.text);
    if ((lat.text.isNotEmpty || lng.text.isNotEmpty) &&
        (a == null || b == null || a.abs() > 90 || b.abs() > 180)) {
      setState(
        () => error = 'Latitude must be −90 to 90 and longitude −180 to 180.',
      );
      return;
    }
    final m = widget.memory.copy()
      ..venue = venue.text.trim()
      ..placeId = place
      ..latitude = a
      ..longitude = b
      ..locationConfirmed = a != null && b != null;
    Navigator.of(context).pop(m);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Handwriting('Where did this little bite happen?', size: 31),
          const SizedBox(height: 14),
          TextField(
            controller: venue,
            onChanged: (_) => place = null,
            decoration: const InputDecoration(
              labelText: 'Your venue label',
              hintText: 'Home, Picnic, or a restaurant',
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Confirm or correct your coordinates to put this memory on the map. A venue without a location is welcome too.',
            style: TextStyle(fontSize: 12, color: Palette.muted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: lat,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Latitude'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: lng,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Longitude'),
                ),
              ),
            ],
          ),
          if (widget.memory.accuracy != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'GPS accuracy ±${widget.memory.accuracy!.round()} m · ${widget.memory.measuredAt?.toLocal() ?? ''}',
                style: const TextStyle(fontSize: 10, color: Palette.muted),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: loading ? null : nearby,
            icon: const Icon(Icons.near_me_outlined, size: 17),
            label: Text(
              loading ? 'Finding nearby places…' : 'See nearby restaurants',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: const TextStyle(fontSize: 12, color: Palette.terracotta),
              ),
            ),
          ...candidates.map(
            (c) => ListTile(
              title: Text(c['name'] ?? 'Restaurant or cafe'),
              subtitle: Text(c['address'] ?? ''),
              trailing: place == c['id']
                  ? const Icon(
                      Icons.check_circle_outline,
                      color: Palette.forest,
                    )
                  : null,
              onTap: () {
                setState(() {
                  place = c['id'];
                  error = null;
                });
                message(
                  context,
                  'Place selected. Enter your own venue label and confirm your saved coordinates.',
                );
              },
            ),
          ),
          if (candidates.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Suggestions shown live. Only the selected place ID is saved; your venue label and coordinates are your own.',
                style: TextStyle(fontSize: 10, color: Palette.muted),
              ),
            ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: finish,
              child: const Text('Confirm venue'),
            ),
          ),
          if (candidates.isNotEmpty) const GeoapifyAttribution(),
        ],
      ),
    ),
  );
}

Future<void> showEvaluation(
  BuildContext context,
  MorslController app,
  Memory m,
) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => EvaluationSheet(app: app, memory: m),
);

class EvaluationSheet extends StatefulWidget {
  const EvaluationSheet({super.key, required this.app, required this.memory});
  final MorslController app;
  final Memory memory;
  @override
  State<EvaluationSheet> createState() => _EvaluationSheetState();
}

class _EvaluationSheetState extends State<EvaluationSheet> {
  late Memory m;
  String? category, rating;
  bool retrying = false;
  @override
  void initState() {
    super.initState();
    m = widget.memory.copy();
    category = m.failureCategory;
    rating = m.rating;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Beta / Cutout notebook'),
          const SizedBox(height: 12),
          const Handwriting('A little imperfect is okay.', size: 35),
          const SizedBox(height: 12),
          if (retrying) ...[
            const CutoutStatus(job: JobStatus.processing, compact: true),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(child: _preview(m.original, 'Original')),
              const SizedBox(width: 12),
              Expanded(child: _preview(m.cutout, 'Cutout')),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '${m.job.name} · ${m.durationMs == null ? 'Not timed yet' : '${(m.durationMs! / 1000).toStringAsFixed(2)} s'} · attempt ${m.attempts}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            m.runtime ?? widget.app.engine.runtime,
            style: const TextStyle(fontSize: 10, color: Palette.muted),
          ),
          if (m.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                m.error!,
                style: const TextStyle(fontSize: 11, color: Palette.terracotta),
              ),
            ),
          const SizedBox(height: 20),
          const Text(
            'How usable is the cutout?',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: ['Usable', 'Needs correction', 'Unusable']
                .map(
                  (r) => ChoiceChip(
                    label: Text(
                      r,
                      style: TextStyle(
                        color: rating == r ? Colors.white : Palette.ink,
                      ),
                    ),
                    selected: rating == r,
                    onSelected: (v) async {
                      setState(() {
                        rating = r;
                        if (r == 'Usable') {
                          category = null;
                        }
                      });
                      await widget.app.rate(m, r, category);
                    },
                  ),
                )
                .toList(),
          ),
          if (rating != null && rating != 'Usable') ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: category,
              decoration: const InputDecoration(labelText: 'What went wrong?'),
              items: [
                'Missing food',
                'Included clutter',
                'Damaged edges',
                'Merged subjects',
                'No subject',
              ].map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
              onChanged: (v) async {
                setState(() => category = v);
                await widget.app.rate(m, rating!, v);
              },
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: retrying
                    ? null
                    : () async {
                        setState(() => retrying = true);
                        await guarded(context, () async {
                          await widget.app.retry(m);
                          final updated = widget.app.memories
                              .where((e) => e.id == m.id)
                              .firstOrNull;
                          if (updated != null && mounted) {
                            setState(() => m = updated.copy());
                          }
                        });
                        if (mounted) {
                          setState(() => retrying = false);
                        }
                      },
                icon: const Icon(Icons.refresh, size: 17),
                label: Text(retrying ? 'Processing…' : 'Retry cutout'),
              ),
              TextButton.icon(
                onPressed: () => guarded(context, () async {
                  final file = await widget.app.exportEvaluations();
                  widget.app.requireGoogleAccount();
                  if (context.mounted) {
                    await shareFile(context, file, 'morsl cutout evaluations');
                  }
                }),
                icon: const Icon(Icons.ios_share, size: 17),
                label: const Text('Export results'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _preview(String? path, String label) => Column(
    children: [
      AspectRatio(
        aspectRatio: 1,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Palette.sage,
            borderRadius: BorderRadius.circular(10),
          ),
          child: path == null
              ? const Center(
                  child: Text(
                    'Original still ready\nto make a memory',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                )
              : Image(
                  image: mediaImage(path),
                  fit: BoxFit.contain,
                  errorBuilder: (c, e, s) =>
                      const Icon(Icons.broken_image_outlined),
                ),
        ),
      ),
      const SizedBox(height: 7),
      Text(label, style: const TextStyle(fontSize: 11, color: Palette.muted)),
    ],
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

Future<void> showInvite(
  BuildContext context,
  MorslController app,
  Memory memory,
) async {
  if (memory.demo) {
    message(
      context,
      'Example memories stay on this device. Capture a real meal to invite someone.',
    );
    return;
  }
  if (app.cloud.account == null) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    return;
  }
  final email = TextEditingController();
  await showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Save a seat for someone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Invite an existing morsl account. They’ll have their own caption, feeling, and layout after accepting.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Their account email'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Maybe later'),
        ),
        FilledButton(
          onPressed: () => guarded(c, () async {
            await app.sync(manual: true);
            if (app.operations.any((o) => o.entity == memory.id)) {
              throw StateError(
                'Back up this memory successfully before inviting someone.',
              );
            }
            await app.cloud.invite(memory.id, email.text);
            if (c.mounted) {
              Navigator.pop(c);
              message(
                context,
                'Invitation sent. Photos stay private until they accept.',
              );
            }
          }),
          child: const Text('Send invitation'),
        ),
      ],
    ),
  );
  email.dispose();
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
              const Eyebrow('Beta notebook'),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.auto_awesome_outlined,
                  color: Palette.forest,
                ),
                title: const Text(
                  'Cutouts & beta tools',
                  style: TextStyle(fontSize: 14),
                ),
                trailing: const Icon(Icons.arrow_forward, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const BetaToolsScreen()),
                ),
              ),
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

class BetaToolsScreen extends ConsumerStatefulWidget {
  const BetaToolsScreen({super.key});
  @override
  ConsumerState<BetaToolsScreen> createState() => _BetaToolsScreenState();
}

class _BetaToolsScreenState extends ConsumerState<BetaToolsScreen> {
  late MorslController app;
  @override
  void initState() {
    super.initState();
    app = ref.read(appProvider);
    app.addListener(changed);
  }

  void changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    app.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Beta notebook', style: TextStyle(fontSize: 17)),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Handwriting(
          'Good memories. Better cutouts.',
          size: 35,
          color: Palette.forest,
        ),
        const SizedBox(height: 14),
        Text(
          app.engine.runtime,
          style: const TextStyle(fontSize: 11, color: Palette.muted),
        ),
        const SizedBox(height: 12),
        Text(
          !app.cloudCutoutsSignedIn
              ? 'Sign in for cloud extraction'
              : !app.cloudCutoutsAllowed
              ? 'Cloud extraction is off'
              : app.modelReady
              ? 'Cloud extraction is available'
              : 'Cloud availability has not been confirmed',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              onPressed: () => guarded(context, () async {
                final file = await app.exportEvaluations();
                app.requireGoogleAccount();
                if (context.mounted) {
                  await shareFile(context, file, 'morsl AI evaluations');
                }
              }),
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('Export evaluations'),
            ),
          ],
        ),
        if (app.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              app.notice!,
              style: const TextStyle(fontSize: 12, color: Palette.muted),
            ),
          ),
        const SizedBox(height: 22),
        const Divider(),
        const SizedBox(height: 16),
        const Eyebrow('Processing queue'),
        const SizedBox(height: 10),
        ...app.memories.map(
          (m) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              m.venue.isEmpty ? 'A little meal' : m.venue,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${m.job.name} · ${m.durationMs ?? 0} ms · ${m.rating ?? 'Not rated'}',
              style: const TextStyle(fontSize: 11, color: Palette.muted),
            ),
            trailing: const Icon(Icons.compare_outlined, size: 20),
            onTap: () => showEvaluation(context, app, m),
          ),
        ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        const Eyebrow('Backup queue'),
        const SizedBox(height: 10),
        if (app.operations.isEmpty)
          const Text(
            'No pending operations.',
            style: TextStyle(fontSize: 12, color: Palette.muted),
          ),
        ...app.operations.map(
          (o) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(o.entity, style: const TextStyle(fontSize: 10)),
            subtitle: Text(
              'Attempt ${o.attempts} · ${o.error ?? 'Queued'}',
              style: const TextStyle(fontSize: 11, color: Palette.muted),
            ),
            trailing: (o.error?.toLowerCase().contains('conflict') ?? false)
                ? TextButton(
                    onPressed: () => guarded(context, () async {
                      final remote = await app.cloudVersion(o.entity);
                      final local = app.memories
                          .where((m) => m.id == o.entity)
                          .firstOrNull;
                      if (local == null || !context.mounted) {
                        return;
                      }
                      final decision = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: const Text('Two versions of a little memory'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'This device: ${local.caption.isEmpty ? '(no caption)' : local.caption}\n${local.background} paper · ${local.layout}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Cloud: ${remote.caption.isEmpty ? '(no caption)' : remote.caption}\n${remote.background} paper · ${remote.layout}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Choose the version to keep. Shared meal details follow the creator’s choice.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Palette.muted,
                                ),
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('Later'),
                            ),
                            OutlinedButton(
                              onPressed: () => Navigator.pop(c, false),
                              child: const Text('Use cloud version'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(c, true),
                              child: const Text('Keep this device'),
                            ),
                          ],
                        ),
                      );
                      if (decision != null) {
                        await app.resolveConflict(remote, keepLocal: decision);
                      }
                    }),
                    child: const Text('Review'),
                  )
                : null,
          ),
        ),
        if (app.cloud.account != null)
          OutlinedButton(
            onPressed: app.busySync ? null : () => app.sync(manual: true),
            child: const Text('Retry backup now'),
          ),
      ],
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
