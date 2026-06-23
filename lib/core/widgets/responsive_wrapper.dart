import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Picks [mobile] or [desktop] based on the SAME breakpoint everything
/// else in the app uses ([Breakpoints.mobile]/[AppTheme.isMobile]) — this
/// used to defer to the `responsive_builder` package's own (different)
/// default breakpoints, which meant a screen could be "desktop" by one
/// definition and "mobile" by another depending on which widget asked.
class ResponsiveWrapper extends StatelessWidget {
  final Widget mobile;
  final Widget desktop;

  const ResponsiveWrapper({
    super.key,
    required this.mobile,
    required this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth < Breakpoints.mobile ? mobile : desktop;
      },
    );
  }
}
