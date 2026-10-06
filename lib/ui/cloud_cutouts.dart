import 'package:flutter/material.dart';

import '../controller.dart';

Future<bool> requestCloudCutouts(
  BuildContext context,
  MorslController app,
) async {
  if (!app.usesCloudCutouts || app.cloudCutoutsAllowed) return true;
  if (!app.cloudCutoutsSignedIn) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Sign in with Google to extract or edit plates.'),
      ),
    );
    return false;
  }
  final account = app.scope;
  final choice = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Allow cloud cutouts?'),
      content: const Text(
        'Your meal photos, including queued imports, will be sent to Modal '
        'to find and cut out plates. This requires internet access. '
        'Your choice is remembered for this account on this device. '
        'You can turn it off in Settings and edit plates by hand. '
        'Your signed-in scrapbook backup to Supabase continues either way.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Use manual cutouts'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('Allow cloud cutouts'),
        ),
      ],
    ),
  );
  if (choice == null || app.scope != account) return false;
  await app.setCloudCutoutsAllowed(choice);
  return choice;
}
