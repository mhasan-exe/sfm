import 'package:flutter/material.dart';

import '../../../core/widgets/glass_card.dart';

/// iPhone-style vertical bento blocks.
///
/// Usage:
/// - Use [BentoColumn] instead of big padded columns.
/// - Use [BentoCard] for compact sections.
/// - Use [BentoSectionTitle] for consistent typography.
class BentoColumn extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  const BentoColumn({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class BentoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  const BentoCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 18,
  });

  @override
  Widget build(BuildContext context) {
    // Reuse existing GlassCard but with tighter padding.
    // GlassCard only supports EdgeInsets padding.
    final edgePadding = padding is EdgeInsets
        ? padding as EdgeInsets
        : const EdgeInsets.all(14);

    return GlassCard(
      padding: edgePadding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

class BentoSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const BentoSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BentoInlineRow extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const BentoInlineRow({
    super.key,
    required this.children,
    this.spacing = 10,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (int i = 0; i < children.length; i++) ...[
          if (i != 0) SizedBox(width: spacing),
          Expanded(child: children[i]),
        ]
      ],
    );
  }
}

