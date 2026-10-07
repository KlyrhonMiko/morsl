import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../controller.dart';
import '../data/friends.dart';
import '../data/models.dart';
import 'theme.dart';

String sharingError(Object error) => error is PostgrestException
    ? error.code == 'PGRST202'
          ? 'Friends are unavailable right now. Please try again later.'
          : error.message
    : error is StateError
    ? error.message.toString()
    : 'Could not complete this right now. Please try again.';

class MealShareSheet extends StatefulWidget {
  const MealShareSheet({super.key, required this.app, required this.memory});
  final MorslController app;
  final Memory memory;
  @override
  State<MealShareSheet> createState() => _MealShareSheetState();
}

class _MealShareSheetState extends State<MealShareSheet> {
  final email = TextEditingController();
  late final String scope;
  List<FriendConnection> friends = [];
  FriendConnection? selected;
  bool loading = true, sending = false;
  String? error, friendsError;
  @override
  void initState() {
    super.initState();
    scope = widget.app.scope;
    widget.app.addListener(accountChanged);
    load();
  }

  void accountChanged() {
    if (mounted && widget.app.scope != scope) {
      setState(() {
        friends = [];
        selected = null;
        email.clear();
      });
    }
  }

  Future<void> load() async {
    try {
      final result = await widget.app.cloud.friends();
      if (!mounted || widget.app.scope != scope) return;
      setState(() {
        friends = result.where((friend) => friend.accepted).toList();
        friendsError = null;
      });
    } catch (_) {
      if (mounted && widget.app.scope == scope) {
        setState(
          () => friendsError =
              'Friends could not be loaded. You can still invite by email.',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(accountChanged);
    email.dispose();
    super.dispose();
  }

  Future<void> send() async {
    if (sending || widget.app.scope != scope || !widget.app.canMutate) return;
    final recipient = email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(recipient)) {
      setState(() => error = 'Choose a friend or enter their account email.');
      return;
    }
    final label = selected?.name ?? recipient;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.app.sync(manual: true);
      if (!mounted || widget.app.scope != scope) return;
      if (widget.app.operations.any(
        (operation) => operation.entity == widget.memory.id,
      )) {
        throw StateError(
          'This meal needs to finish backing up before it can be shared. Please try again.',
        );
      }
      await widget.app.cloud.invite(widget.memory.id, recipient);
      if (mounted && widget.app.scope == scope) Navigator.pop(context, label);
    } catch (failure) {
      if (mounted && widget.app.scope == scope) {
        setState(() => error = sharingError(failure));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.app.scope != scope || !widget.app.canMutate) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Sign in to your account to share this meal.'),
        ),
      );
    }
    final query = email.text.trim().toLowerCase();
    final matches = friends
        .where(
          (friend) =>
              '${friend.name} ${friend.email}'.toLowerCase().contains(query),
        )
        .toList();
    return SafeArea(
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
            const Handwriting('Share a seat at the table.', size: 31),
            const SizedBox(height: 12),
            const Text(
              'Share this meal and all its plates. They’ll get an invitation and can keep their own memory after accepting.',
              style: TextStyle(fontSize: 12, color: Palette.muted),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: email,
              enabled: !sending,
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {
                selected = null;
                error = null;
              }),
              decoration: const InputDecoration(
                labelText: 'Find a friend or enter an email',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your friends',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: sending
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => FriendsScreen(app: widget.app),
                            ),
                          );
                          if (mounted && widget.app.scope == scope) {
                            await load();
                          }
                        },
                  icon: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                  label: const Text('Manage friends'),
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            if (friendsError != null)
              Text(
                friendsError!,
                style: const TextStyle(fontSize: 12, color: Palette.muted),
              ),
            if (!loading && friendsError == null && friends.isEmpty)
              const Text(
                'Add friends to choose them here, or enter someone’s Google email.',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
            if (!loading && friends.isNotEmpty && matches.isEmpty)
              const Text(
                'No matching friend. Enter a full account email to invite someone else.',
                style: TextStyle(fontSize: 12, color: Palette.muted),
              ),
            ...matches.map(
              (friend) => ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                title: Text(friend.name),
                subtitle: Text(friend.email),
                selected: selected?.id == friend.id,
                selectedTileColor: Palette.sage,
                selectedColor: Palette.forest,
                trailing: selected?.id == friend.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: sending
                    ? null
                    : () => setState(() {
                        selected = friend;
                        email.text = friend.email;
                        error = null;
                      }),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: const TextStyle(
                    color: Palette.terracotta,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: sending ? null : send,
                child: Text(
                  sending ? 'Sending invitation…' : 'Send invitation',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.app});
  final MorslController app;
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final email = TextEditingController();
  List<FriendConnection> connections = [];
  late String scope;
  bool loading = true, busy = false;
  String? error;
  int version = 0;
  @override
  void initState() {
    super.initState();
    scope = widget.app.scope;
    widget.app.addListener(accountChanged);
    load();
  }

  void accountChanged() {
    if (mounted && scope != widget.app.scope) {
      scope = widget.app.scope;
      version++;
      setState(() {
        connections = [];
        email.clear();
        error = null;
        busy = false;
      });
      load();
    }
  }

  Future<void> load() async {
    final request = ++version;
    if (!widget.app.canMutate) {
      setState(() {
        connections = [];
        loading = false;
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.app.cloud.friends();
      if (mounted && request == version) setState(() => connections = result);
    } catch (failure) {
      if (mounted && request == version) {
        setState(() => error = sharingError(failure));
      }
    } finally {
      if (mounted && request == version) setState(() => loading = false);
    }
  }

  Future<void> run(Future<void> Function() action, String notice) async {
    if (busy || !widget.app.canMutate) return;
    final account = scope;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      if (!mounted || account != scope) return;
      email.clear();
      await load();
      if (mounted && account == scope) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(notice)));
      }
    } catch (failure) {
      if (mounted && account == scope) {
        setState(() => error = sharingError(failure));
      }
    } finally {
      if (mounted && account == scope) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(accountChanged);
    email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final incoming = connections
        .where((friend) => !friend.accepted && friend.incoming)
        .toList();
    final outgoing = connections
        .where((friend) => !friend.accepted && !friend.incoming)
        .toList();
    final accepted = connections.where((friend) => friend.accepted).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Friends')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (!widget.app.canMutate)
            const Text('Sign in with Google to add friends.')
          else ...[
            const Text(
              'Share meals with people you know.',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Text(
              'Add their Google account email. They’ll appear in your friends list after accepting.',
              style: TextStyle(color: Palette.muted, fontSize: 12),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: email,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Their account email',
                prefixIcon: Icon(Icons.person_add_alt_1_outlined, size: 19),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy
                  ? null
                  : () {
                      final address = email.text.trim();
                      if (!RegExp(
                        r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                      ).hasMatch(address)) {
                        setState(
                          () => error = 'Enter their full account email.',
                        );
                        return;
                      }
                      run(
                        () => widget.app.cloud.requestFriend(address),
                        'Friend request sent.',
                      );
                    },
              child: const Text('Send friend request'),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: LinearProgressIndicator(),
              ),
            if (error != null) ...[
              const SizedBox(height: 14),
              Text(error!, style: const TextStyle(color: Palette.terracotta)),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Try again'),
              ),
            ],
            if (incoming.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                'Friend requests',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...incoming.map(
                (friend) => Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        friend.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        friend.email,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Palette.muted,
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: busy
                                ? null
                                : () => run(
                                    () => widget.app.cloud.respondToFriend(
                                      friend.id,
                                      true,
                                    ),
                                    'Friend added.',
                                  ),
                            child: const Text('Accept'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(
                                    () => widget.app.cloud.respondToFriend(
                                      friend.id,
                                      false,
                                    ),
                                    'Friend request declined.',
                                  ),
                            child: const Text('Decline'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Your friends',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            if (!loading && accepted.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Accepted friends will appear here.',
                  style: TextStyle(fontSize: 12, color: Palette.muted),
                ),
              ),
            ...accepted.map(
              (friend) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(friend.name),
                subtitle: Text(friend.email),
                trailing: PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: 'Friend options',
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove friend'),
                    ),
                  ],
                  onSelected: (_) => run(
                    () => widget.app.cloud.removeFriend(friend.id),
                    'Friend removed.',
                  ),
                ),
              ),
            ),
            if (outgoing.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                'Requests sent',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...outgoing.map(
                (friend) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(friend.name),
                  subtitle: const Text('Waiting for acceptance'),
                  trailing: IconButton(
                    tooltip: 'Cancel friend request',
                    onPressed: busy
                        ? null
                        : () => run(
                            () => widget.app.cloud.removeFriend(friend.id),
                            'Friend request cancelled.',
                          ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
