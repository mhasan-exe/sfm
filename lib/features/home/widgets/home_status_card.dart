import 'package:flutter/material.dart';

import '../../../core/services/timetable_service.dart';

class HomeStatusCard extends StatefulWidget {
  const HomeStatusCard({super.key, required this.teacherId});

  final String teacherId;

  @override
  State<HomeStatusCard> createState() => _HomeStatusCardState();
}

class _HomeStatusCardState extends State<HomeStatusCard> {
  final TimetableService _timetableService = TimetableService();

  String? _className;
  String? _rangeText;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // NOTE: Current data model in this repo stores weekly slots.
      // We approximate "current" and "next" by using today's day name and
      // ordering by unit/startTime.
      final now = DateTime.now();
      final day = _dayName(now);

final daySlots = await _timetableService.getTeacherDaySchedule(
        widget.teacherId,
        day,
      );

      // "next" = first slot whose endTime is after now (approx)
      // Since times are stored as strings like "08:30", we compare by minutes.
      final nowMinutes = _toMinutes(now);

      Map<String, dynamic>? currentOrNext;
      int? currentUnit;
      int? nextUnit;

      for (final slot in daySlots) {
        _parseTimeToMinutes(slot['startTime'] as String);
        final slotEnd = _parseTimeToMinutes(slot['endTime'] as String);

        if (slotEnd >= nowMinutes) {
          // candidate for current/next
          if (nextUnit == null || (slot['unit'] as int) < nextUnit) {
            nextUnit = slot['unit'] as int;
            currentOrNext = slot;
          }
        }
        currentUnit ??= slot['unit'] as int;
        // keep track of something for fallback
        if (slot['unit'] is int) {
          currentUnit = slot['unit'] as int;
        }
      }

      // fallback: earliest slot today
      currentOrNext ??= (daySlots.isNotEmpty
          ? (daySlots.toList()
            ..sort((a, b) => (a['unit'] as int).compareTo(b['unit'] as int)))
              .first
          : null);

      if (!mounted) return;

      setState(() {
        _loading = false;
        if (currentOrNext == null) {
          _className = null;
          _rangeText = null;
          _error = 'No schedule found for today';
        } else {
          _error = null;
          _className = currentOrNext['className'] as String? ?? 'Class';
          _rangeText =
              '${currentOrNext['startTime']} - ${currentOrNext['endTime']}';
          // also allow overriding label later if desired
// unused for now
          // currentUnit = null;
          nextUnit = null;
          
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  String _dayName(DateTime dt) {
    // Firestore days are stored as Monday..Saturday in existing code.
    final weekday = dt.weekday; // Mon=1..Sun=7
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      // Sunday isn't used by existing generator; map it to Monday.
      'Sunday',
    ];
    return days[weekday - 1];
  }

  int _toMinutes(DateTime dt) => dt.hour * 60 + dt.minute;

  int _parseTimeToMinutes(String time) {
    // Accept "08:30" or "08:30 AM" just in case.
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    final hour = int.tryParse(parts[0].trim()) ?? 0;
    final minutePart = parts[1];
    final minuteStr = minutePart.replaceAll(RegExp(r'[^0-9]'), '');
    final minute = int.tryParse(minuteStr) ?? 0;
    return hour * 60 + minute;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 140,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Current Status',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.schedule, size: 32),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Next Unit'),
                  const SizedBox(height: 4),
                  Text(
                    _className ?? '—',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _rangeText ?? (_error ?? '—'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

