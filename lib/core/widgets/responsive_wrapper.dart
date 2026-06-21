import 'package:flutter/material.dart';
import 'package:responsive_builder/responsive_builder.dart';

class ResponsiveWrapper
    extends StatelessWidget {
  final Widget mobile;
  final Widget desktop;

  const ResponsiveWrapper({
    super.key,

    required this.mobile,
    required this.desktop,
  });

  @override
  Widget build(BuildContext context) {
    return ScreenTypeLayout.builder(
      mobile: (_) => mobile,

      tablet: (_) => desktop,

      desktop: (_) => desktop,
    );
  }
}