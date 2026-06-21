import 'package:flutter/material.dart';

/// Lightweight “SaaS-like” spacing helpers for the Admin UI.
///
/// Purpose:
/// - keep content compact on phones
/// - avoid fixed large paddings that cause squeeze/overflow
/// - provide reusable header layout
class AdminSaasLayout {
  static bool isNarrow(BuildContext context) {
    return MediaQuery.sizeOf(context).width < 600;
  }

  static EdgeInsets contentPadding(BuildContext context) {
    if (isNarrow(context)) {
      return const EdgeInsets.symmetric(horizontal: 14, vertical: 10);
    }
    return const EdgeInsets.symmetric(horizontal: 20, vertical: 16);
  }

  static Widget header({
    required BuildContext context,
    required String title,
    required String subtitle,
    Widget? right,
  }) {
    final narrow = isNarrow(context);

    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (right != null) ...[
            const SizedBox(height: 12),
            right,
          ],
        ],
      );
    }

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        if (right != null) ...[
          const SizedBox(width: 16),
          Align(alignment: Alignment.centerRight, child: right),
        ],
      ],
    );
  }

  static Widget twoColumnOrStack({
    required BuildContext context,
    required Widget left,
    required Widget right,
  }) {
    if (MediaQuery.sizeOf(context).width < 820) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          left,
          const SizedBox(height: 16),
          right,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: left),
        const SizedBox(width: 24),
        Expanded(child: right),
      ],
    );
  }
}

