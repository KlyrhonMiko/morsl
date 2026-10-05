import 'package:flutter/material.dart';

abstract final class Palette {
  static const paper = Color(0xFFF8F5EE);
  static const ink = Color(0xFF343B32);
  static const muted = Color(0xFF697063);
  static const terracotta = Color(0xFFAB5038);
  static const sage = Color(0xFFE5EBDD);
  static const forest = Color(0xFF465C43);
  static const line = Color(0xFFE1E2D7);
  static const rose = Color(0xFFF2E2DE);
  static const sand = Color(0xFFF0E5CC);
  static Color background(String name) => switch (name) {
    'sage' => sage,
    'rose' => rose,
    'sand' => sand,
    _ => const Color(0xFFEEE9DF),
  };
}

ThemeData morslTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Quicksand',
  scaffoldBackgroundColor: Palette.paper,
  colorScheme: ColorScheme.fromSeed(
    seedColor: Palette.terracotta,
    surface: Palette.paper,
    onSurface: Palette.ink,
    primary: Palette.terracotta,
    secondary: Palette.forest,
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(
      fontSize: 15,
      height: 1.5,
      fontWeight: FontWeight.w500,
      color: Palette.ink,
    ),
    bodyMedium: TextStyle(
      fontSize: 13,
      height: 1.5,
      fontWeight: FontWeight.w500,
      color: Palette.ink,
    ),
    bodySmall: TextStyle(fontSize: 12, height: 1.5, color: Palette.muted),
    titleLarge: TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      letterSpacing: -.8,
    ),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Palette.paper,
    foregroundColor: Palette.ink,
    elevation: 0,
    scrolledUnderElevation: 0,
  ),
  dividerTheme: const DividerThemeData(color: Palette.line, thickness: 1),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white.withValues(alpha: .5),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Palette.line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Palette.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Palette.forest, width: 1.5),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: Palette.terracotta,
      foregroundColor: Colors.white,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(
        fontFamily: 'Quicksand',
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: Palette.ink,
      minimumSize: const Size(48, 48),
      side: const BorderSide(color: Palette.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: Colors.transparent,
    selectedColor: Palette.forest,
    labelStyle: const TextStyle(
      fontFamily: 'Quicksand',
      fontSize: 12,
      color: Palette.ink,
    ),
    checkmarkColor: Colors.white,
    side: const BorderSide(color: Palette.line),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
  ),
);

class Handwriting extends StatelessWidget {
  const Handwriting(
    this.text, {
    super.key,
    this.size = 30,
    this.color = Palette.ink,
    this.align = TextAlign.left,
    this.maxLines,
  });
  final String text;
  final double size;
  final Color color;
  final TextAlign align;
  final int? maxLines;
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: align,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(
      fontFamily: 'Caveat',
      fontSize: size,
      height: 1.08,
      color: color,
    ),
  );
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 2,
      color: Palette.muted,
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
    child: Column(
      children: [
        Icon(icon, size: 48, color: Palette.forest),
        const SizedBox(height: 20),
        Handwriting(title, size: 36, align: TextAlign.center),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Palette.muted),
        ),
        if (action != null) ...[const SizedBox(height: 24), action!],
      ],
    ),
  );
}
