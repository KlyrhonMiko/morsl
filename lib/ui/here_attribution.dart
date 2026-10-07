import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

class HereAttribution extends StatelessWidget {
  const HereAttribution({super.key});

  Future<void> _open(BuildContext context, String address) async {
    try {
      if (await launchUrl(
        Uri.parse(address),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // Suggestions remain usable when the device cannot open a browser.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the attribution link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Palette.paper,
    child: Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (final entry in const {
          'Powered by HERE': 'https://www.here.com/',
        }.entries)
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: const TextStyle(fontFamily: 'Quicksand', fontSize: 10),
            ),
            onPressed: () => _open(context, entry.value),
            child: Text(entry.key),
          ),
      ],
    ),
  );
}
