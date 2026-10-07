import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../controller.dart';
import '../data/models.dart';
import 'theme.dart';
import 'memory_card.dart';
import 'editor.dart';
import 'map_screen.dart';
import 'tools.dart';
import 'account_gate.dart';
import 'plate_library.dart';

class MorslHome extends ConsumerStatefulWidget {
  const MorslHome({super.key});
  @override
  ConsumerState<MorslHome> createState() => _MorslHomeState();
}

class _MorslHomeState extends ConsumerState<MorslHome>
    with WidgetsBindingObserver {
  late MorslController app;
  late String accountScope;
  String? lastAuthError;
  String search = '', companion = 'All people';
  bool onlyBookmarks = false, showArchived = false;
  DateTimeRange? dates;
  @override
  void initState() {
    super.initState();
    app = ref.read(appProvider);
    accountScope = app.scope;
    app.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (mounted) {
      if (app.authError != null && app.authError != lastAuthError) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(app.authError!)));
      }
      lastAuthError = app.authError;
      setState(() {
        if (accountScope != app.scope) {
          accountScope = app.scope;
          search = '';
          companion = 'All people';
          onlyBookmarks = false;
          showArchived = false;
          dates = null;
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      app.lifecycle(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    app.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void open(Memory m) {
    if (!app.canMutate || m.scope != app.scope) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BrowseMemory(memory: m, app: app),
        ),
      );
      return;
    }
    app.repository.event(m.scope, 'memory_opened', {
      'mealId': m.id,
      'draft': m.draft,
      'demo': m.demo,
    });
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PlatingEditor(memory: m)));
  }

  Future<void> capture() => showCapture(context, app, open);
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final wide = c.maxWidth >= 1000;
      final title = ['Library', 'Map', 'Drafts'][app.destination];
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (wide) _sidebar(),
              Expanded(
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 40 : 22,
                        vertical: wide ? 18 : 10,
                      ),
                      child: Row(
                        children: [
                          if (!wide) ...[
                            const SizedBox(
                              width: 86,
                              child: FittedBox(
                                child: Handwriting(
                                  'morsl',
                                  size: 40,
                                  color: Palette.terracotta,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _beta(),
                          ],
                          if (wide) ...[
                            const Icon(
                              Icons.menu_book_outlined,
                              size: 18,
                              color: Palette.muted,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Your plates / $title',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Palette.muted,
                              ),
                            ),
                          ],
                          const Spacer(),
                          IconButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const InboxScreen(),
                              ),
                            ),
                            tooltip: 'Meal invitations',
                            icon: const Icon(
                              Icons.mail_outline_rounded,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Semantics(
                            label: 'Account and settings',
                            button: true,
                            child: InkWell(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const SettingsScreen(),
                                ),
                              ),
                              borderRadius: BorderRadius.circular(24),
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: const BoxDecoration(
                                  color: Palette.sage,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.person_outline_rounded,
                                  color: Palette.forest,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: app.destination == 1
                          ? MealMap(
                              key: ValueKey(app.scope),
                              app: app,
                              onOpen: open,
                            )
                          : app.destination == 0
                          ? PlateLibrary(
                              key: ValueKey(app.scope),
                              app: app,
                              onCapture: capture,
                              onMealDetails: open,
                            )
                          : _scrapbook(wide),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : SafeArea(
                top: false,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Palette.paper,
                    border: Border(top: BorderSide(color: Palette.line)),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      _bottomItem(0, Icons.menu_book_outlined, 'Library'),
                      _bottomItem(1, Icons.map_outlined, 'Map'),
                      _bottomItem(2, Icons.inbox_outlined, 'Drafts'),
                      Expanded(
                        child: Center(
                          heightFactor: 1,
                          child: SizedBox.square(
                            dimension: 52,
                            child: IconButton.filled(
                              onPressed: capture,
                              tooltip: 'Capture a meal',
                              style: IconButton.styleFrom(
                                backgroundColor: Palette.terracotta,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(14),
                                shape: const CircleBorder(),
                              ),
                              icon: const Icon(
                                Icons.camera_alt_outlined,
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
  Widget _beta() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      border: Border.all(color: Palette.line),
      borderRadius: BorderRadius.circular(5),
    ),
    child: const Text(
      'BETA',
      style: TextStyle(
        fontSize: 8,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
      ),
    ),
  );
  Widget _bottomItem(int i, IconData icon, String label) => Expanded(
    child: InkWell(
      onTap: () => app.navigate(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: app.destination == i ? Palette.terracotta : Palette.muted,
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: app.destination == i
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: app.destination == i
                    ? Palette.terracotta
                    : Palette.muted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _sidebar() => Container(
    width: 226,
    decoration: const BoxDecoration(
      border: Border(right: BorderSide(color: Palette.line)),
    ),
    padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Handwriting('morsl', size: 54, color: Palette.terracotta),
            const SizedBox(width: 9),
            Padding(padding: const EdgeInsets.only(bottom: 9), child: _beta()),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Little bites.\nOur little history.',
          style: TextStyle(fontSize: 12, height: 1.7, color: Palette.muted),
        ),
        const SizedBox(height: 50),
        const Eyebrow('Your little world'),
        const SizedBox(height: 16),
        ...[
          (Icons.menu_book_outlined, 'Library'),
          (Icons.map_outlined, 'Map'),
          (Icons.inbox_outlined, 'Drafts'),
        ].indexed.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Material(
              color: app.destination == item.$1
                  ? Palette.sage
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () => app.navigate(item.$1),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Icon(item.$2.$1, size: 20, color: Palette.forest),
                      const SizedBox(width: 13),
                      Text(
                        item.$2.$2,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      if (item.$1 == 2)
                        Text(
                          '${app.memories.where((m) => m.draft && !m.archived).length}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Palette.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: capture,
            icon: const Icon(Icons.add_a_photo_outlined, size: 18),
            label: const Text('Capture a meal'),
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF0ECE2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.eco_outlined, color: Palette.forest, size: 22),
              const SizedBox(height: 10),
              const Handwriting('Good food.\nBetter memories.', size: 25),
              const SizedBox(height: 10),
              const Text(
                'The little things are\nthe big things.',
                style: TextStyle(
                  fontSize: 11,
                  color: Palette.muted,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        InkWell(
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          child: Row(
            children: [
              Icon(
                app.busySync ? Icons.sync : Icons.cloud_outlined,
                size: 16,
                color: Palette.muted,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  app.cloud.account == null
                      ? 'Browse only · Sign in with Google'
                      : app.operations.isEmpty
                      ? 'All memories backed up'
                      : '${app.operations.length} pending backup',
                  style: const TextStyle(fontSize: 10, color: Palette.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _scrapbook(bool wide) {
    final draft = app.destination == 2;
    final items = app.memories
        .where((m) => m.draft == draft && m.archived == showArchived)
        .where((m) => !onlyBookmarks || m.bookmarked)
        .where(
          (m) => companion == 'All people' || m.companions.contains(companion),
        )
        .where(
          (m) =>
              dates == null ||
              (!m.createdAt.isBefore(dates!.start) &&
                  m.createdAt.isBefore(
                    dates!.end.add(const Duration(days: 1)),
                  )),
        )
        .where(
          (m) => '${m.caption} ${m.venue} ${m.companions.join(' ')}'
              .toLowerCase()
              .contains(search.toLowerCase()),
        )
        .toList();
    final people = {
      'All people',
      ...app.memories.expand((m) => m.companions),
    }.toList();
    final month = items.isEmpty
        ? DateFormat('MMMM yyyy').format(DateTime.now())
        : DateFormat('yyyy-MM').format(items.first.createdAt) !=
              DateFormat('yyyy-MM').format(items.last.createdAt)
        ? 'Recent memories'
        : DateFormat('MMMM yyyy').format(items.first.createdAt);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        wide ? 40 : 22,
        wide ? 18 : 8,
        wide ? 40 : 22,
        40,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1160),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (wide) ...[
                const Eyebrow('Little bites. Our little history.'),
                const SizedBox(height: 14),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          draft
                              ? 'A few memories in the making.'
                              : 'Your life, one bite at a time.',
                          style: TextStyle(
                            fontSize: wide ? 34 : 24,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -1.2,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          draft
                              ? 'Your photos are safe. Come back whenever you’re ready.'
                              : 'The meals, the people, the moments worth keeping.',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (wide) ...[
                    const SizedBox(width: 20),
                    OutlinedButton.icon(
                      onPressed: capture,
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('A new little memory'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              if (wide &&
                  !draft &&
                  MediaQuery.textScalerOf(context).scale(1) < 1.5 &&
                  search.isEmpty &&
                  !onlyBookmarks &&
                  companion == 'All people' &&
                  dates == null &&
                  !showArchived) ...[
                _hero(wide),
                const SizedBox(height: 32),
              ],
              if (draft && items.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Palette.sage,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_outlined,
                        size: 22,
                        color: Palette.forest,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Enjoy your meal first. Cutouts stay here until you finish editing and save to the Library.',
                          style: TextStyle(fontSize: 12, color: Palette.forest),
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const BetaToolsScreen(),
                          ),
                        ),
                        child: const Text('AI tools'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
              ],
              LayoutBuilder(
                builder: (context, c) {
                  final searchBox = TextField(
                    key: ValueKey(app.scope),
                    onChanged: (s) => setState(() => search = s),
                    decoration: InputDecoration(
                      hintText: c.maxWidth > 600
                          ? 'Find a meal, place or person'
                          : 'Find a meal or place',
                      prefixIcon: Icon(Icons.search_rounded, size: 19),
                      suffixIcon: c.maxWidth > 600
                          ? null
                          : IconButton(
                              onPressed: _pickDates,
                              tooltip: dates == null
                                  ? 'Filter by date'
                                  : 'Change date filter',
                              icon: Icon(
                                Icons.calendar_today_outlined,
                                size: 17,
                                color: dates == null
                                    ? Palette.muted
                                    : Palette.terracotta,
                              ),
                            ),
                    ),
                  );
                  return c.maxWidth > 600
                      ? Row(
                          children: [
                            Expanded(child: searchBox),
                            const SizedBox(width: 14),
                            _dateButton(),
                            const SizedBox(width: 10),
                            _archiveButton(),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: searchBox),
                            const SizedBox(width: 4),
                            _archiveButton(),
                          ],
                        );
                },
              ),
              const SizedBox(height: 15),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _filterChip(
                    wide ? 'All memories' : 'All',
                    !onlyBookmarks,
                    () => setState(() => onlyBookmarks = false),
                  ),
                  if (dates != null) ...[
                    InputChip(
                      label: Text(
                        '${DateFormat('MMM d').format(dates!.start)} – ${DateFormat('MMM d').format(dates!.end)}',
                      ),
                      onDeleted: () => setState(() => dates = null),
                    ),
                  ],
                  _filterChip(
                    'Would go again',
                    onlyBookmarks,
                    () => setState(() => onlyBookmarks = !onlyBookmarks),
                    icon: Icons.favorite_border,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    constraints: const BoxConstraints(minHeight: 48),
                    decoration: BoxDecoration(
                      border: Border.all(color: Palette.line),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: people.contains(companion)
                            ? companion
                            : 'All people',
                        icon: const Icon(Icons.keyboard_arrow_down, size: 17),
                        style: const TextStyle(
                          fontFamily: 'Quicksand',
                          color: Palette.ink,
                          fontSize: 12,
                        ),
                        items: people
                            .map(
                              (p) => DropdownMenuItem(value: p, child: Text(p)),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => companion = v!),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      draft ? 'Unfinished drafts' : month,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${items.length} ${items.length == 1 ? 'memory' : 'memories'}',
                    style: const TextStyle(fontSize: 11, color: Palette.muted),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (items.isEmpty)
                EmptyState(
                  icon: draft ? Icons.inbox_outlined : Icons.menu_book_outlined,
                  title:
                      search.isNotEmpty ||
                          onlyBookmarks ||
                          companion != 'All people'
                      ? 'No little bites here yet.'
                      : draft
                      ? 'All caught up.'
                      : 'Your story starts at the table.',
                  message:
                      search.isNotEmpty ||
                          onlyBookmarks ||
                          companion != 'All people'
                      ? 'Try a different search or loosen your filters.'
                      : draft
                      ? 'Capture a meal and we’ll keep it here for you.'
                      : 'Capture your first meal. Keep the moment.',
                  action: FilledButton.icon(
                    onPressed: capture,
                    icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                    label: const Text('Capture a meal'),
                  ),
                ),
              if (items.isNotEmpty)
                LayoutBuilder(
                  builder: (context, c) {
                    final columns = c.maxWidth > 920
                        ? 3
                        : c.maxWidth > 510
                        ? 2
                        : 1;
                    final width = (c.maxWidth - 24 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 24,
                      runSpacing: 28,
                      children: items
                          .map(
                            (m) => SizedBox(
                              width: width,
                              child: Column(
                                children: [
                                  if (draft)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            m.job == JobStatus.ready
                                                ? Icons.check_circle_outline
                                                : Icons.photo_outlined,
                                            size: 15,
                                            color: Palette.forest,
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            switch (m.job) {
                                              JobStatus.queued =>
                                                'Cutout queued',
                                              JobStatus.processing =>
                                                'Creating cutout…',
                                              JobStatus.ready =>
                                                'Ready in your library',
                                              JobStatus.failed =>
                                                'Needs a plate cutout',
                                            },
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Palette.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  MemoryCard(
                                    memory: m,
                                    pending: app.operations.any(
                                      (o) => o.entity == m.id,
                                    ),
                                    onOpen: () => open(m),
                                    onBookmark: () async {
                                      if (!await requireGoogleSignIn(
                                        context,
                                        app,
                                      )) {
                                        return;
                                      }
                                      await app.toggleBookmark(m);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    );
                  },
                ),
              const SizedBox(height: 38),
              const Center(
                child: Handwriting(
                  'Here’s to the little things.',
                  size: 24,
                  color: Palette.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip(
    String title,
    bool selected,
    VoidCallback tap, {
    IconData? icon,
  }) => ChoiceChip(
    label: Text(
      title,
      style: TextStyle(
        color: selected ? Colors.white : Palette.ink,
        fontWeight: FontWeight.w600,
      ),
    ),
    avatar: icon == null
        ? null
        : Icon(icon, size: 15, color: selected ? Colors.white : Palette.muted),
    selected: selected,
    onSelected: (_) => tap(),
    showCheckmark: false,
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
  );
  Widget _dateButton() => OutlinedButton.icon(
    onPressed: _pickDates,
    icon: const Icon(Icons.calendar_today_outlined, size: 16),
    label: Text(
      dates == null
          ? 'Any time'
          : '${DateFormat('MMM d').format(dates!.start)} – ${DateFormat('MMM d').format(dates!.end)}',
      style: const TextStyle(fontSize: 12),
    ),
  );
  Future<void> _pickDates() async {
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: dates,
    );
    if (mounted && result != null) {
      setState(() => dates = result);
    }
  }

  Widget _archiveButton() => IconButton(
    onPressed: () => setState(() => showArchived = !showArchived),
    tooltip: showArchived ? 'Show active memories' : 'Show archived memories',
    icon: Icon(
      showArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
      color: showArchived ? Palette.terracotta : Palette.muted,
      size: 20,
    ),
  );
  Widget _hero(bool wide) => Container(
    height:
        (wide ? 214 : 148) *
        MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: Palette.sage,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Expanded(
          flex: wide ? 6 : 5,
          child: Padding(
            padding: EdgeInsets.all(wide ? 28 : 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (wide) ...[
                  const Eyebrow('More than what was on the plate'),
                  const SizedBox(height: 12),
                ],
                Handwriting(
                  wide ? 'Remember how\nit felt.' : 'Remember\nhow it felt.',
                  size: wide ? 43 : 31,
                  color: Palette.forest,
                ),
                const SizedBox(height: 10),
                if (wide)
                  Text(
                    'A table full of stories. A place to keep yours.',
                    style: TextStyle(
                      fontSize: wide ? 12 : 10,
                      color: Palette.forest,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Image.asset(
                    'assets/images/salad-cutout.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
