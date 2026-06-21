import 'package:flutter/material.dart';

class LoadingSkeleton extends StatelessWidget {
  final Widget child;

  const LoadingSkeleton({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Fallback implementation when skeletonizer is unavailable.
    return Opacity(
      opacity: 0.6,
      child: child,
    );
  }
}

