import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class AppBackground extends StatelessWidget {
  final Widget child;

  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(decoration: AppTheme.backgroundGradient),

          Positioned(
            top: -140,
            left: -120,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
              child: Container(
                width: 260,
                height: 260,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color.fromRGBO(255, 166, 79, 0.65),
                      Color.fromRGBO(255, 177, 90, 0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            top: 60,
            right: -90,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(
                width: 220,
                height: 220,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color.fromRGBO(79, 146, 255, 0.55),
                      Color.fromRGBO(79, 146, 255, 0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            bottom: -120,
            right: -90,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
              child: Container(
                width: 260,
                height: 260,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color.fromRGBO(251, 91, 112, 0.45),
                      Color.fromRGBO(251, 91, 112, 0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            bottom: 120,
            left: -80,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(
                width: 180,
                height: 180,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color.fromRGBO(113, 212, 231, 0.35),
                      Color.fromRGBO(113, 212, 231, 0),
                    ],
                  ),
                ),
              ),
            ),
          ),

          child,
        ],
      ),
    );
  }
}