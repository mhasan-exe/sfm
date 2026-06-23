import 'package:flutter/material.dart';

/// Caps a dialog's content width on large screens (so a confirm dialog
/// doesn't stretch edge-to-edge on a 27" monitor) while still letting it
/// shrink to fit comfortably on a phone. Wrap an [AlertDialog]'s `content`
/// with this, or use [AppDialog.show] to also apply it to the dialog as a
/// whole via a custom builder.
class AppDialog {
  /// Sensible default cap for most confirm/form dialogs.
  static const double defaultMaxWidth = 480;

  static Widget constrain(BuildContext context, Widget child, {double maxWidth = defaultMaxWidth}) {
    final screenWidth = MediaQuery.of(context).size.width;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth.clamp(0, screenWidth * 0.92)),
      child: child,
    );
  }

  /// Shows [builder]'s dialog with its content pre-wrapped to a sane max
  /// width. [builder] should return the dialog's content widget only (not
  /// a whole Dialog/AlertDialog) — this wraps it in a minimal frameless
  /// dialog shell so callers that just want "a centered, width-capped
  /// panel" (e.g. a custom card-style dialog) don't need AlertDialog's
  /// title/actions layout at all.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    double maxWidth = defaultMaxWidth,
    bool barrierDismissible = true,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: constrain(context, builder(context), maxWidth: maxWidth),
      ),
    );
  }
}
