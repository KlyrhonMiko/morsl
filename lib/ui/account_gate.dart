import 'package:flutter/material.dart';

import '../controller.dart';
import '../data/models.dart';
import 'memory_card.dart';

Future<bool> requireGoogleSignIn(
  BuildContext context,
  MorslController app,
) async {
  if (app.canMutate) return true;
  final signIn = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Make it your little world'),
      content: const Text(
        'Sign in with Google to capture, edit, and share meals. '
        'You can keep browsing without an account.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('Keep browsing'),
        ),
        FilledButton(
          onPressed: !app.cloud.configured
              ? null
              : () => Navigator.pop(dialog, true),
          child: const Text('Continue with Google'),
        ),
      ],
    ),
  );
  if (signIn == true) {
    try {
      await app.signInWithGoogle();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    }
  }
  // Let the user restart the action after their account's data has loaded.
  return false;
}

class BrowseMemory extends StatelessWidget {
  const BrowseMemory({super.key, required this.memory, required this.app});
  final Memory memory;
  final MorslController app;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('A little memory')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AspectRatio(
              aspectRatio: .91,
              child: MemoryCanvas(memory: memory),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Sign in with Google to start your own scrapbook.'),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => requireGoogleSignIn(context, app),
          child: const Text('Continue with Google'),
        ),
      ],
    ),
  );
}
