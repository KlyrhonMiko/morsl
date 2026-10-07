import 'package:flutter/material.dart';

import 'theme.dart';

class MealMap extends StatelessWidget {
  const MealMap({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: SingleChildScrollView(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.map_outlined, size: 48, color: Palette.forest),
          SizedBox(height: 20),
          Handwriting(
            'Your meal map, on pause.',
            size: 32,
            color: Palette.forest,
          ),
          SizedBox(height: 12),
          Text(
            'Your saved locations are safe.\nFind your meals in History for now.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Palette.muted, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
