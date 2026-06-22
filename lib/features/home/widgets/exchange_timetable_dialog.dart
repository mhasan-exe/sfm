import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/services/admin_config_service.dart';
import '../../../core/services/timetable_service.dart';

class ExchangeTimetableDialog extends StatefulWidget {
  const ExchangeTimetableDialog({super.key});

  @override
  State<ExchangeTimetableDialog> createState() =>
      _ExchangeTimetableDialogState();
}

class _ExchangeTimetableDialogState
    extends State<ExchangeTimetableDialog> {
  final TimetableService _service = TimetableService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  DocumentSnapshot<Map<String, dynamic>>? _slot1;
  DocumentSnapshot<Map<String, dynamic>>? _slot2;

  bool _busy = false;
  bool _ensuredDaily = false;

  String get _todayKey {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Same-day slot exchanges must operate on the Daily Timetable only — the
  /// permanent Weekly template is never touched by a one-off swap. This
  /// makes sure today's daily rows actually exist before the picker query
  /// runs (no-ops harmlessly if they're already there).
  Future<void> _ensureDailyExists() async {
    if (_ensuredDaily) return;
    _ensuredDaily = true;
    try {
      await _service.generateDailyForDate(DateTime.now());
    } catch (_) {
      // If this fails, the picker below will simply show "no slots found"
      // rather than crash the dialog.
    }
  }

  bool get _isExchangeSafe {
    if (_slot1 == null || _slot2 == null) return false;

    // Exchange swaps teacherId between two slots.
    // It is safe if the teacher's time window (same day) doesn't overlap
    // when swapped: i.e., the other slot time doesn't conflict with the
    // teacher's current assignment set.
    //
    // For this first implementation (destination-only), we ensure the two
    // selected slots do NOT overlap in time with each other.
    // This matches the "works without clash" expectation for a single-day
    // exchange flow.
    final data1 = _slot1!.data();
    final data2 = _slot2!.data();
    if (data1 == null || data2 == null) return false;

    final day1 = data1['day']?.toString() ?? '';
    final day2 = data2['day']?.toString() ?? '';
    if (day1.isEmpty || day2.isEmpty || day1 != day2) return true;

    final s1 = _toMinutes(data1['startTime']?.toString() ?? '');
    final e1 = _toMinutes(data1['endTime']?.toString() ?? '');
    final s2 = _toMinutes(data2['startTime']?.toString() ?? '');
    final e2 = _toMinutes(data2['endTime']?.toString() ?? '');

    if (s1 == null || e1 == null || s2 == null || e2 == null) return true;

    // overlap check [start,end)
    final overlaps = s1 < e2 && s2 < e1;
    return !overlaps;
  }

  int? _toMinutes(String t) {
    final trimmed = t.trim();
    if (trimmed.isEmpty) return null;

    final match = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$')
        .firstMatch(trimmed);
    if (match == null) return null;

    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final ampm = match.group(3);

    if (ampm != null) {
      final upper = ampm.toUpperCase();
      final isPM = upper == 'PM';
      if (hour == 12) {
        hour = isPM ? 12 : 0;
      } else {
        hour = isPM ? hour + 12 : hour;
      }
    }

    return hour * 60 + minute;
  }


  String _dayName(DateTime dt) {
    // Mon=1..Sun=7
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[dt.weekday - 1];
  }

  Future<void> _submitExchange() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (_slot1 == null || _slot2 == null) return;
    if (_busy) return;

    final slotId1 = _slot1!.id;
    final slotId2 = _slot2!.id;

    setState(() => _busy = true);
    try {
      // This dialog only ever deals with today's slots, so the unified
      // cutoff (same gate used by leave requests and fixture claims)
      // always applies here.
      if (await AdminConfigService().isPastUnifiedCutoffNow()) {
        throw Exception('Same-day slot exchanges are blocked after cutoff time');
      }
      await _service.exchangeDailySlots(dailySlotId1: slotId1, dailySlotId2: slotId2);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exchange failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;

    if (user == null) {
      return AlertDialog(
        title: const Text('Exchange'),
        content: const Text('Not authenticated'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Exchange Timetable Slots'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            const Text('Pick 2 assigned slots (for today). This only changes today\'s schedule.'),
            const SizedBox(height: 12),
            Expanded(
              child: FutureBuilder<void>(
                future: _ensureDailyExists(),
                builder: (context, ensureSnap) {
                  if (ensureSnap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    // Single equality filter (`teacherId`) — filtering by
                    // `date` too client-side avoids needing a manually
                    // created composite index in every school's Firebase
                    // project.
                    stream: _firestore
                        .collection('daily_timetables')
                        .where('teacherId', isEqualTo: user.uid)
                        .snapshots(),
                    builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final docs = [...(snapshot.data?.docs ?? [])]
                    ..retainWhere((d) => d.data()['date']?.toString() == _todayKey)
                    ..sort((a, b) =>
                        ((a.data()['unit'] as num?)?.toInt() ?? 0)
                            .compareTo((b.data()['unit'] as num?)?.toInt() ?? 0));

                  if (docs.isEmpty) {
                    return const Text('No assigned slots found for today.');
                  }

                  // Horizontal (excel-like) grid: units as columns.
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ...docs.map((doc) {
                          final data = doc.data();
                          final unit = data['unit']?.toString() ?? '';
                          final className = data['className']?.toString() ?? '';
                          final startTime = data['startTime']?.toString() ?? '';
                          final endTime = data['endTime']?.toString() ?? '';

                          final isSelected1 = _slot1?.id == doc.id;
                          final isSelected2 = _slot2?.id == doc.id;

                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: SizedBox(
                              width: 170,
                              child: Column(
                                children: [
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size.fromHeight(48),
                                      backgroundColor: (isSelected1 || isSelected2)
                                          ? Colors.blue.withValues(alpha: 0.12)
                                          : null,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        if (isSelected1) {
                                          _slot1 = null;
                                          return;
                                        }
                                        if (isSelected2) {
                                          _slot2 = null;
                                          return;
                                        }

                                        if (_slot1 == null) {
                                          _slot1 = doc;
                                        } else if (_slot2 == null) {
                                          _slot2 = doc;
                                        } else {
                                          _slot2 = doc;
                                        }
                                      });
                                    },
                                    icon: Icon(
                                      (isSelected1 || isSelected2)
                                          ? Icons.check
                                          : Icons.swap_horiz,
                                    ),
                                    label: Text(
                                      'Unit $unit',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    className,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$startTime - $endTime',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Slot 1: ${_slot1 != null ? (_slot1!.data()?['unit'] ?? '') : '—'}',
                ),
                Text(
                  'Slot 2: ${_slot2 != null ? (_slot2!.data()?['unit'] ?? '') : '—'}',
                ),
              ],
            ),
          ],
        ),
      ),
      

      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: (_slot1 != null && _slot2 != null && !_busy && _isExchangeSafe)
              ? _submitExchange
              : null,

          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm Exchange'),
        ),
      ],
    );
  }
}

