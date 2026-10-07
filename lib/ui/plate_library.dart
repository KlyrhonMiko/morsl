import 'cutout_image.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../controller.dart';
import '../data/models.dart';
import '../services/creations.dart';
import 'account_gate.dart';
import 'composition_editor.dart';
import 'theme.dart';
import 'tools.dart';

class PlateLibrary extends StatefulWidget {
  const PlateLibrary({
    super.key,
    required this.app,
    required this.onCapture,
    required this.onMealDetails,
  });
  final MorslController app;
  final VoidCallback onCapture;
  final ValueChanged<Memory> onMealDetails;
  @override
  State<PlateLibrary> createState() => _PlateLibraryState();
}

class _PlateLibraryState extends State<PlateLibrary> {
  String search = '';
  bool selecting = false;
  final selected = <String>{};
  List<PlateCreation> creations = [];
  String? loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await CreationStore(
        widget.app.repository,
        widget.app.scope,
      ).list();
      if (mounted) {
        setState(() {
          creations = items;
          loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => loadError = 'Could not load saved photos. Tap to retry.',
        );
      }
    }
  }

  Future<void> _arrange({PlateCreation? creation}) async {
    if (!await requireGoogleSignIn(context, widget.app) || !mounted) return;
    final available = LibraryPlate.fromMemories(widget.app.memories);
    final keys = available.map((p) => p.key).toSet();
    selected.removeWhere((key) => !keys.contains(key));
    if (creation == null && selected.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CompositionEditor(
          app: widget.app,
          creation: creation,
          initialPlates: available
              .where((p) => selected.contains(p.key))
              .toList(),
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      selecting = false;
      selected.clear();
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final all = LibraryPlate.fromMemories(widget.app.memories);
    final plates = all
        .where(
          (p) => '${p.title} ${p.memory.venue} ${p.review.note}'
              .toLowerCase()
              .contains(search.toLowerCase()),
        )
        .toList();
    final keys = all.map((p) => p.key).toSet();
    final count = selected.where(keys.contains).length;
    final pending = widget.app.memories
        .where((m) => !m.archived && m.draft)
        .length;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1160),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Handwriting(
                      'Your plate library',
                      size: 42,
                      color: Palette.forest,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Every plate, a little memory. Rate a bite or bring your favorites together.',
                      style: TextStyle(color: Palette.muted),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: widget.onCapture,
                          icon: const Icon(Icons.add_a_photo_outlined),
                          label: const Text('Add plates'),
                        ),
                        OutlinedButton.icon(
                          onPressed: all.isEmpty
                              ? null
                              : () => setState(() {
                                  selecting = !selecting;
                                  selected.clear();
                                }),
                          icon: Icon(
                            selecting
                                ? Icons.close
                                : Icons.dashboard_customize_outlined,
                          ),
                          label: Text(
                            selecting ? 'Cancel selection' : 'Arrange plates',
                          ),
                        ),
                      ],
                    ),
                    if (pending > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          '$pending ${pending == 1 ? 'meal is' : 'meals are'} saved in Drafts. Finish editing whenever you’re ready.',
                          style: const TextStyle(color: Palette.muted),
                        ),
                      ),
                    const SizedBox(height: 24),
                    TextField(
                      onChanged: (v) => setState(() => search = v),
                      decoration: const InputDecoration(
                        hintText: 'Find a plate or restaurant',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '${all.length} ${all.length == 1 ? 'plate' : 'plates'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 14),
                    if (plates.isEmpty)
                      EmptyState(
                        icon: Icons.restaurant_outlined,
                        title: search.isEmpty
                            ? 'A place for every plate.'
                            : 'No plates found.',
                        message: search.isEmpty
                            ? 'Add a meal photo to start your cutout collection.'
                            : 'Try another dish or restaurant.',
                        action: search.isEmpty
                            ? FilledButton(
                                onPressed: widget.onCapture,
                                child: const Text('Add plates'),
                              )
                            : null,
                      ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns =
                            MediaQuery.textScalerOf(context).scale(1) > 1.4
                            ? (constraints.maxWidth > 600 ? 2 : 1)
                            : constraints.maxWidth > 900
                            ? 4
                            : constraints.maxWidth > 550
                            ? 3
                            : 2;
                        final width =
                            (constraints.maxWidth - 16 * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: 16,
                          runSpacing: 24,
                          children: [
                            for (final plate in plates)
                              SizedBox(
                                width: width,
                                child: PlateTile(
                                  plate: plate,
                                  selecting: selecting,
                                  selected: selected.contains(plate.key),
                                  onTap: () async {
                                    if (selecting) {
                                      setState(() {
                                        if (!selected.add(plate.key)) {
                                          selected.remove(plate.key);
                                        }
                                      });
                                    } else {
                                      await Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => PlateDetails(
                                            app: widget.app,
                                            plate: plate,
                                            onMealDetails: widget.onMealDetails,
                                          ),
                                        ),
                                      );
                                      if (mounted) setState(() {});
                                    }
                                  },
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    if (creations.isNotEmpty) ...[
                      const SizedBox(height: 36),
                      Text(
                        'Your photos',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Saved on this device. Open a photo to keep arranging or export it.',
                        style: TextStyle(color: Palette.muted),
                      ),
                      const SizedBox(height: 12),
                      for (final creation in creations)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            Icons.collections_outlined,
                            color: Palette.forest,
                          ),
                          title: Text(creation.title),
                          subtitle: Text(
                            '${creation.plates.length} plates · ${DateFormat.yMMMd().format(creation.updatedAt)}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _arrange(creation: creation),
                        ),
                    ],
                    if (loadError != null)
                      TextButton(onPressed: _load, child: Text(loadError!)),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (selecting)
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Palette.sage,
              child: Row(
                children: [
                  Expanded(child: Text('$count selected')),
                  FilledButton(
                    onPressed: count == 0 ? null : () => _arrange(),
                    child: const Text('Make a photo'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class PlateTile extends StatelessWidget {
  const PlateTile({
    super.key,
    required this.plate,
    required this.onTap,
    this.selecting = false,
    this.selected = false,
  });
  final LibraryPlate plate;
  final VoidCallback onTap;
  final bool selecting, selected;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selecting ? selected : null,
    label:
        '${plate.title}, ${plate.memory.venue}${selecting ? ', select plate' : ', view and rate plate'}',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: Palette.sage.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(12),
                border: selected
                    ? Border.all(color: Palette.forest, width: 2)
                    : null,
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: PlateImage(path: plate.path),
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: Palette.forest,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (plate.memory.demo)
            const Text(
              'Example plate',
              style: TextStyle(fontSize: 11, color: Palette.muted),
            ),
          Text(
            plate.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(
            plate.memory.venue.isEmpty
                ? 'Restaurant not added'
                : plate.memory.venue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Palette.muted),
          ),
          Text(
            DateFormat('MMM d, yyyy · h:mm a').format(plate.memory.createdAt),
            style: const TextStyle(fontSize: 11, color: Palette.muted),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                plate.review.stars == null ? Icons.star_outline : Icons.star,
                size: 16,
                color: Palette.terracotta,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  plate.review.stars == null
                      ? 'Rate this plate'
                      : '${plate.review.stars}/5',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Palette.terracotta,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class PlateImage extends StatelessWidget {
  const PlateImage({super.key, required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => CutoutImage(path: path);
}

class PlateDetails extends StatefulWidget {
  const PlateDetails({
    super.key,
    required this.app,
    required this.plate,
    required this.onMealDetails,
  });
  final MorslController app;
  final LibraryPlate plate;
  final ValueChanged<Memory> onMealDetails;
  @override
  State<PlateDetails> createState() => _PlateDetailsState();
}

class _PlateDetailsState extends State<PlateDetails> {
  late final TextEditingController name, note;
  int? stars;
  bool saving = false;
  bool deleting = false;
  bool get busy => saving || deleting;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.plate.review.name);
    note = TextEditingController(text: widget.plate.review.note);
    stars = widget.plate.review.stars;
    widget.app.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.app.removeListener(_changed);
    name.dispose();
    note.dispose();
    super.dispose();
  }

  bool get canEdit =>
      widget.app.canMutate && widget.app.scope == widget.plate.memory.scope;
  Future<void> _delete() async {
    if (!canEdit || busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this plate?'),
        content: Text(
          'Remove ${widget.plate.title} and its rating and note from your library? '
          'Your meal, original photos, and other plates will stay. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete plate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !canEdit || busy) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => deleting = true);
    try {
      await widget.app.deletePlate(widget.plate);
      if (!mounted || !canEdit) return;
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Plate deleted.')));
    } catch (_) {
      if (mounted) {
        message(context, 'Could not delete this plate. Please try again.');
      }
    } finally {
      if (mounted) setState(() => deleting = false);
    }
  }

  Future<void> _save() async {
    if (!canEdit || busy) return;
    setState(() => saving = true);
    try {
      widget.app.requireGoogleAccount(widget.plate.memory);
      final current = await widget.app.repository.mutate(
        widget.plate.memory.id,
        widget.plate.memory.scope,
        (memory) {
          if (widget.plate.plateId == '__cutout__'
              ? memory.cutout?.isNotEmpty != true
              : !memory.plates.any((p) => p.id == widget.plate.plateId)) {
            throw StateError('This plate is no longer in your library.');
          }
          memory.plateReviews = {
            ...memory.plateReviews,
            widget.plate.plateId: PlateReview(
              stars: stars,
              note: note.text.trim(),
              name: name.text.trim(),
            ),
          };
        },
      );
      if (current == null) {
        throw StateError('This plate is no longer in your library.');
      }
      await widget.app.reload();
      if (mounted && canEdit) {
        message(context, 'Plate saved.');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) message(context, 'Could not save this plate: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.app.scope != widget.plate.memory.scope) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'This plate belongs to another library.',
          message: 'Return to your library to continue.',
        ),
      );
    }
    final memory =
        widget.app.memories
            .where(
              (m) =>
                  m.id == widget.plate.memory.id &&
                  m.scope == widget.plate.memory.scope,
            )
            .firstOrNull ??
        widget.plate.memory;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plate details'),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Delete plate',
              onPressed: busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 260,
                  width: double.infinity,
                  child: PlateImage(path: widget.plate.path),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.plate.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  memory.venue.isEmpty ? 'Restaurant not added' : memory.venue,
                ),
                Text(
                  DateFormat('MMMM d, yyyy · h:mm a').format(memory.createdAt),
                ),
                if (memory.companions.isNotEmpty)
                  Text('With ${memory.companions.join(', ')}'),
                TextButton.icon(
                  onPressed: busy ? null : () => widget.onMealDetails(memory),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Meal details'),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: name,
                  readOnly: !canEdit || busy,
                  maxLength: 80,
                  decoration: const InputDecoration(
                    labelText: 'Plate name',
                    hintText: 'What did you eat?',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your rating',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  children: [
                    for (var value = 1; value <= 5; value++)
                      IconButton(
                        tooltip: '$value ${value == 1 ? 'star' : 'stars'}',
                        isSelected: stars == value,
                        onPressed: !canEdit || busy
                            ? null
                            : () => setState(() => stars = value),
                        icon: Icon(
                          (stars ?? 0) >= value
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: Palette.terracotta,
                          size: 32,
                        ),
                      ),
                    if (stars != null)
                      TextButton(
                        onPressed: !canEdit || busy
                            ? null
                            : () => setState(() => stars = null),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: note,
                  readOnly: !canEdit || busy,
                  maxLines: 3,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'What made this plate memorable?',
                  ),
                ),
                const SizedBox(height: 20),
                if (canEdit)
                  FilledButton(
                    onPressed: busy ? null : _save,
                    child: Text(
                      deleting
                          ? 'Deleting plate…'
                          : saving
                          ? 'Saving…'
                          : 'Save plate',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
