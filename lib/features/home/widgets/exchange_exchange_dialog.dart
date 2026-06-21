import 'package:flutter/material.dart';

class ExchangeChoiceDialog extends StatelessWidget {
  const ExchangeChoiceDialog({super.key, required this.onTimetable, required this.onFixture});

  final VoidCallback onTimetable;
  final VoidCallback onFixture;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exchange'),
      content: const Text('What do you want to exchange?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            onTimetable();
          },
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Timetable Slots'),
        ),
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            onFixture();
          },
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Fixtures'),
        ),
      ],
    );
  }
}

