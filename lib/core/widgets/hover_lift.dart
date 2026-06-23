import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Wraps [child] with a subtle "lift" on hover (scale + brighter border +
/// soft shadow) — purely cosmetic, does nothing on touch-only platforms
/// where there's no concept of hover. Use around cards, list tiles, and
/// anything else that should feel alive under a mouse cursor.
///
/// Does NOT add its own tap handling — wrap with [InkWell]/[GestureDetector]
/// yourself (or pass [onTap] for the common case).
class HoverLift extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final BorderRadius? borderRadius;
  final bool enabled;

  const HoverLift({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 1.015,
    this.borderRadius,
    this.enabled = true,
  });

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !isPointerPlatform) {
      return widget.onTap == null
          ? widget.child
          : InkWell(
              onTap: widget.onTap,
              borderRadius: widget.borderRadius,
              child: widget.child,
            );
    }

    return MouseRegion(
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hovering ? widget.scale : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius ?? BorderRadius.circular(AppTheme.radiusLg),
              boxShadow: _hovering
                  ? [
                      BoxShadow(
                        color: AppTheme.accentPrimary.withValues(alpha: 0.18),
                        blurRadius: 24,
                        spreadRadius: -4,
                        offset: const Offset(0, 10),
                      ),
                    ]
                  : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
