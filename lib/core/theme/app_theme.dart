import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const _bg1 = Color(0xFF0B1020);

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,

    scaffoldBackgroundColor: _bg1,

    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF6D5EF7),
      secondary: Color(0xFF00D4FF),
      surface: Color(0xFF111A2E),
    ),

    textTheme: GoogleFonts.interTextTheme(
      ThemeData.dark().textTheme,
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
    ),

    cardTheme: CardThemeData(
      color: const Color(0xFF141B2E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x221A2030),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
  );

  // GLOBAL GRADIENT BACKGROUND
  static BoxDecoration backgroundGradient = const BoxDecoration(
    gradient: LinearGradient(
      colors: [
        Color(0xFF0A1122),
        Color(0xFF101B3D),
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  // Page padding helper: 16 on narrow screens, 24 on wider screens
  static EdgeInsets pagePadding(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width < 800 ? const EdgeInsets.all(16) : const EdgeInsets.all(24);
  }
}