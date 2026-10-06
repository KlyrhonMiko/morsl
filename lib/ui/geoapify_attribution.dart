import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

class GeoapifyAttribution extends StatelessWidget {
  const GeoapifyAttribution({super.key});

  Future<void> _open(BuildContext context, String address) async {
    try {
      if (await launchUrl(
        Uri.parse(address),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      // The map remains usable when the device cannot open an external browser.
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
          'Powered by Geoapify': 'https://www.geoapify.com/',
          '© OpenStreetMap contributors':
              'https://www.openstreetmap.org/copyright',
        }.entries)
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              textStyle: const TextStyle(fontSize: 10),
            ),
            onPressed: () => _open(context, entry.value),
            child: Text(entry.key),
          ),
      ],
    ),
  );
}
