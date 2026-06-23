import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Breakpoints used consistently across the app. Anything wider than
/// [desktop] is still "desktop" — there's no separate ultra-wide tier,
/// content just gets centered with [AppTheme.maxContentWidth].
class Breakpoints {
  static const double mobile = 600;
  static const double tablet = 1024;
  static const double desktop = 1440;
}

/// True on web AND desktop (Windows/macOS/Linux) — i.e. anywhere a mouse
/// and hover states make sense, as opposed to a touch-only phone/tablet.
bool get isPointerPlatform {
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// Lets mouse-drag and trackpad scrolling work everywhere (the default
/// Flutter scroll behavior on web/desktop only allows touch/stylus drag,
/// not a plain mouse click-drag) — this is the single biggest "why doesn't
/// scrolling feel right on desktop" fix, applied globally once instead of
/// per-screen.
class AppScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    // Always show a (thin, theme-colored) scrollbar on pointer platforms —
    // reads as "real desktop app" instead of a ported mobile screen.
    if (isPointerPlatform) {
      return Scrollbar(
        controller: details.controller,
        thumbVisibility: false,
        radius: const Radius.circular(8),
        thickness: 6,
        child: child,
      );
    }
    return super.buildScrollbar(context, child, details);
  }
}

/// Consistent fade+scale transition for every pushed route, on every
/// platform — avoids the default "Android slide from right / iOS slide
/// with shadow" feel, which reads as a ported mobile app rather than a
/// desktop/web SaaS product.
class _FadeScaleTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeScaleTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}

class AppTheme {
  static const _bg1 = Color(0xFF0B1020);

  // ---- Design tokens -------------------------------------------------
  static const Color accentPrimary = Color(0xFF6D5EF7);
  static const Color accentSecondary = Color(0xFF00D4FF);
  static const Color accentSuccess = Color(0xFF34D399);
  static const Color accentWarning = Color(0xFFFBBF24);
  static const Color accentDanger = Color(0xFFF87171);

  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 22;

  /// Centers and caps content width on very wide desktop monitors so
  /// pages don't stretch into unreadable, sparse single-column layouts.
  static const double maxContentWidth = 1440;

  static final ScrollBehavior scrollBehavior = AppScrollBehavior();

  static ThemeData darkTheme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,

    scaffoldBackgroundColor: _bg1,

    colorScheme: const ColorScheme.dark(
      primary: accentPrimary,
      secondary: accentSecondary,
      surface: Color(0xFF111A2E),
      error: accentDanger,
    ),

    textTheme: GoogleFonts.interTextTheme(
      ThemeData.dark().textTheme,
    ),

    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeScaleTransitionsBuilder(),
        TargetPlatform.iOS: _FadeScaleTransitionsBuilder(),
        TargetPlatform.macOS: _FadeScaleTransitionsBuilder(),
        TargetPlatform.windows: _FadeScaleTransitionsBuilder(),
        TargetPlatform.linux: _FadeScaleTransitionsBuilder(),
        TargetPlatform.fuchsia: _FadeScaleTransitionsBuilder(),
      },
    ),

    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.2),
    ),

    cardTheme: CardThemeData(
      color: const Color(0xFF141B2E),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusLg),
      ),
    ),

    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      backgroundColor: const Color(0xFF131A2C),
      surfaceTintColor: Colors.transparent,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x221A2030),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radiusMd),
        borderSide: BorderSide.none,
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF1E2536),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),

    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) return Colors.white.withValues(alpha: 0.08);
          if (states.contains(WidgetState.pressed)) return Colors.white.withValues(alpha: 0.12);
          return null;
        }),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) return Colors.white.withValues(alpha: 0.08);
          if (states.contains(WidgetState.pressed)) return Colors.white.withValues(alpha: 0.12);
          return null;
        }),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSm)),
        ),
        side: const WidgetStatePropertyAll(BorderSide(color: Color(0x33FFFFFF))),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered)) return Colors.white.withValues(alpha: 0.06);
          return null;
        }),
      ),
    ),

    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: BorderSide.none,
      backgroundColor: Colors.white.withValues(alpha: 0.06),
      selectedColor: accentPrimary.withValues(alpha: 0.35),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0E1424),
      indicatorColor: accentPrimary.withValues(alpha: 0.25),
      elevation: 0,
      height: 64,
    ),

    splashFactory: isPointerPlatform ? NoSplash.splashFactory : InkRipple.splashFactory,
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
    return width < Breakpoints.mobile
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(24);
  }

  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < Breakpoints.mobile;
  static bool isTablet(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= Breakpoints.mobile && w < Breakpoints.tablet;
  }
  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= Breakpoints.tablet;
}
