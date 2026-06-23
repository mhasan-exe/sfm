import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// Wrap a horizontally-scrolling widget (e.g. the timetable's excel-like
/// grid) with this so a plain mouse wheel — which only ever generates
/// vertical scroll deltas — also scrolls it sideways. Without this,
/// desktop users have to shift+scroll or click-drag the scrollbar, which
/// feels broken on a grid that's wider than the screen.
class MouseWheelHorizontalScroll extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  const MouseWheelHorizontalScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && controller.hasClients) {
          final delta = event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
              ? event.scrollDelta.dy
              : event.scrollDelta.dx;
          final target = (controller.offset + delta).clamp(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          );
          controller.jumpTo(target);
        }
      },
      child: child,
    );
  }
}
