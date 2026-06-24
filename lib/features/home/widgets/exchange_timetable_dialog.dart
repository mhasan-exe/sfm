import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/services/admin_config_service.dart';
import '../../../core/services/timetable_service.dart';

/// One slot the signed-in teacher could offer up for today's exchange —
/// either their own normal weekly slot (if not vacated by leave) or a
/// fixture-cover slot they're standing in for someone else on today.
class _ExchangeCandidate {
  final String weeklySlotId;
  final Map<String, dynamic> data;
  const _ExchangeCandidate({required this.weeklySlotId, required this.data});
}

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

  _ExchangeCandidate? _slot1;
  _ExchangeCandidate? _slot2;

  bool _busy = false;

  DateTime get _now => DateTime.now();

  String get _todayKey {
    final now = _now;
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String get _todayDayName {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[_now.weekday - 1];
  }

  /// Today's exchangeable slots for the signed-in teacher: their own
  /// weekly slots for today's weekday (skipping any vacated by approved
  /// leave — those can never be exchanged away, only an admin override can
  /// touch a leave-locked slot) plus any slot they're currently covering
  /// for someone else via a claimed/assigned fixture today. Computed once
  /// per dialog open (not a live stream) since this is a short-lived
  /// picker, not a persistent screen.
  Future<List<_ExchangeCandidate>> _loadTodayCandidates(String teacherUid) async {
    final weeklySnap = await _firestore
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: teacherUid)
        .where('day', isEqualTo: _todayDayName)
        .get();

    final excOwnSnap = await _firestore
        .collection('timetable_exceptions')
        .where('date', isEqualTo: _todayKey)
        .where('originalTeacherId', isEqualTo: teacherUid)
        .get();
    final excCoverSnap = await _firestore
        .collection('timetable_exceptions')
        .where('date', isEqualTo: _todayKey)
        .where('teacherId', isEqualTo: teacherUid)
        .get();

    final excBySlotId = <String, Map<String, dynamic>>{};
    for (final d in excOwnSnap.docs) {
      excBySlotId[d.data()['slotId']?.toString() ?? d.id] = d.data();
    }
    for (final d in excCoverSnap.docs) {
      excBySlotId[d.data()['slotId']?.toString() ?? d.id] = d.data();
    }

    final candidates = <_ExchangeCandidate>[];

    for (final doc in weeklySnap.docs) {
      final exc = excBySlotId.remove(doc.id);
      if (exc != null && exc['type'] == 'leave') {
        // This slot was vacated by approved leave today. If nobody has
        // covered it yet there's nothing of theirs to exchange; if
        // somebody else is now covering it, it's not this teacher's slot
        // to offer either way.
        continue;
      }
      candidates.add(_ExchangeCandidate(weeklySlotId: doc.id, data: doc.data()));
    }

    // Whatever's left in excBySlotId are slots NOT normally this
    // teacher's, where they're now covering via a fixture today.
    excBySlotId.forEach((slotId, exc) {
      if ((exc['teacherId'] as String?) == teacherUid) {
        candidates.add(_ExchangeCandidate(weeklySlotId: slotId, data: exc));
      }
    });

    candidates.sort((a, b) =>
        ((a.data['unit'] as num?)?.toInt() ?? 0)
            .compareTo((b.data['unit'] as num?)?.toInt() ?? 0));
    return candidates;
  }

  bool get _isExchangeSafe {
    if (_slot1 == null || _slot2 == null) return false;

    final data1 = _slot1!.data;
    final data2 = _slot2!.data;

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

  Future<void> _submitExchange() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (_slot1 == null || _slot2 == null) return;
    if (_busy) return;

    final weeklySlotId1 = _slot1!.weeklySlotId;
    final weeklySlotId2 = _slot2!.weeklySlotId;

    setState(() => _busy = true);
    try {
      // This dialog only ever deals with today's slots, so the unified
      // cutoff (same gate used by leave requests and fixture claims)
      // always applies here.
      if (await AdminConfigService().isPastUnifiedCutoffNow()) {
        throw Exception('Same-day slot exchanges are blocked after cutoff time');
      }
      await _service.exchangeForDate(
        weeklySlotId1: weeklySlotId1,
        weeklySlotId2: weeklySlotId2,
        date: _now,
      );
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
              child: FutureBuilder<List<_ExchangeCandidate>>(
                future: _loadTodayCandidates(user.uid),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Text('Could not load today\'s slots: ${snapshot.error}');
                  }

                  final candidates = snapshot.data ?? const [];
                  if (candidates.isEmpty) {
                    return const Text('No assigned slots found for today.');
                  }

                  // Horizontal (excel-like) grid: units as columns.
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ...candidates.map((cand) {
                          final data = cand.data;
                          final unit = data['unit']?.toString() ?? '';
                          final className = data['className']?.toString() ?? '';
                          final startTime = data['startTime']?.toString() ?? '';
                          final endTime = data['endTime']?.toString() ?? '';

                          final isSelected1 = _slot1?.weeklySlotId == cand.weeklySlotId;
                          final isSelected2 = _slot2?.weeklySlotId == cand.weeklySlotId;

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
                                          _slot1 = cand;
                                        } else if (_slot2 == null) {
                                          _slot2 = cand;
                                        } else {
                                          _slot2 = cand;
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
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Slot 1: ${_slot1 != null ? (_slot1!.data['unit'] ?? '') : '—'}',
                ),
                Text(
                  'Slot 2: ${_slot2 != null ? (_slot2!.data['unit'] ?? '') : '—'}',
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
