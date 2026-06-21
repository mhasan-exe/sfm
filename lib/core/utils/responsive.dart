import 'package:flutter/material.dart';

class Responsive {
  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < 700;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 700 &&
      MediaQuery.of(context).size.width < 1100;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1100;

  static double padding(BuildContext context) {
    if (isDesktop(context)) return 24;
    if (isTablet(context)) return 18;
    return 14;
  }

  static double title(BuildContext context) {
    if (isDesktop(context)) return 30;
    return 22;
  }

  static double cardRadius = 22;
}
