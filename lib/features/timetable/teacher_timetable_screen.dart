import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/services/break_duty_service.dart';
import '../../core/theme/app_theme.dart';
import '../../models/break_duty_model.dart';

/// Teacher timetable (read-only).
///
/// Data source strategy:
/// - `weekly_timetables`: permanent weekly plan (single source of truth for
///   "what normally happens")
/// - `timetable_exceptions`: sparse per-date deviations (leave, exchanges,
///   admin overrides, fixture cover) for "what's different today"
///
/// UI:
/// - Horizontal grid: days (columns) x units (rows)
/// - No editing, no drag/drop
class TeacherTimetableScreen extends StatefulWidget {
  /// When null, shows the signed-in user's own timetable. When provided,
  /// shows the given teacher's timetable instead (read-only viewing of a
  /// colleague's schedule, e.g. from the Profiles screen).
  final String? teacherId;
  final String? teacherName;

  const TeacherTimetableScreen({super.key, this.teacherId, this.teacherName});

  @override
  State<TeacherTimetableScreen> createState() => _TeacherTimetableScreenState();
}

class _TeacherTimetableScreenState extends State<TeacherTimetableScreen> {
  static const List<String> days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  String get _todayKey {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    final teacherId = widget.teacherId ?? FirebaseAuth.instance.currentUser?.uid;

    if (teacherId == null || teacherId.isEmpty) {
      return const Center(child: Text('Not authenticated'));
    }

    return ListView(
      padding: AppTheme.pagePadding(context),
      children: [
        Text(
          widget.teacherName != null ? '${widget.teacherName}\'s Timetable' : 'My Timetable',
          style: Theme.of(context).textTheme.headlineSmall,
        )
            .animate()
            .fadeIn(duration: 300.ms)
            .slideY(begin: -8, end: 0),
        const SizedBox(height: 18),
        if (widget.teacherId == null) _TodayBreakDutyBanner(teacherId: teacherId),
        _TeacherTimetableGrid(
          teacherId: teacherId,
          todayKey: _todayKey,
        ),
      ],
    );
  }
}

/// Small banner showing today's break/recess/lunch duties for the signed-in
/// teacher, if any — pulled from the Break Duty roster, separate from the
/// class timetable grid below.
class _TodayBreakDutyBanner extends StatelessWidget {
  final String teacherId;
  const _TodayBreakDutyBanner({required this.teacherId});

  String get _today {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[DateTime.now().weekday - 1];
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<BreakDutyModel>>(
      stream: BreakDutyService().watchForTeacher(teacherId),
      builder: (context, snapshot) {
        final todays = (snapshot.data ?? const [])
            .where((d) => d.days.contains(_today))
            .toList();
        if (todays.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: todays.map((duty) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.free_breakfast_outlined, color: Colors.orangeAccent, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${duty.name} · ${duty.startTime}-${duty.endTime}${duty.location.isNotEmpty ? ' · ${duty.location}' : ''}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ).animate().fadeIn(duration: 250.ms);
      },
    );
  }
}

class _TeacherTimetableGrid extends StatelessWidget {
  // Stabilize streams: create them once per widget instance instead of re-creating in build().

  final String teacherId;
  final String todayKey;

  const _TeacherTimetableGrid({
    required this.teacherId,
    required this.todayKey,
  });

  @override
  Widget build(BuildContext context) {
    final weeklyStream = _weeklyForTeacher(teacherId);
    final exceptionsStream = _exceptionsForTeacherToday(teacherId, todayKey);

    return StreamBuilder<_MergedTeacherTimetable>(
      stream: _mergeStreams(weeklyStream, exceptionsStream, todayKey),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            height: 420,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final data = snapshot.data!;
        if (data.maxUnit <= 0) {
          return const Center(child: Text('No timetable assigned'));
        }

        // New orientation (requested):
        // - Days vertically (rows)
        // - Units horizontally (columns)
        return LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final isNarrow = maxW < 600;

            final headerH = isNarrow ? 48.0 : 54.0;
            final slotH = isNarrow ? 88.0 : 96.0;
            final slotPad = isNarrow ? 8.0 : 10.0;

            final dayColW = isNarrow ? 110.0 : 140.0;
            final unitColW = isNarrow ? 95.0 : 110.0;

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                children: [
                  SizedBox(
                    height: headerH,
                    child: Row(
                      children: [
                        SizedBox(
                          width: dayColW,
                          child: Container(
                            alignment: Alignment.centerLeft,
                            padding: EdgeInsets.symmetric(horizontal: slotPad),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: const Text(
                              'Day',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                        for (var unitIndex = 0; unitIndex < data.maxUnit; unitIndex++)
                          SizedBox(
                            width: unitColW,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                                color: Colors.white.withValues(alpha: 0.06),
                              ),
                              child: Text(
                                'U${unitIndex + 1}',
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  for (var dayIndex = 0;
                      dayIndex < _TeacherTimetableScreenDays.days.length;
                      dayIndex++)
                    SizedBox(
                      height: slotH,
                      child: Row(
                        children: [
                          SizedBox(
                            width: dayColW,
                            child: Container(
                              alignment: Alignment.centerLeft,
                              padding: EdgeInsets.symmetric(horizontal: slotPad),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Text(
                                _TeacherTimetableScreenDays.days[dayIndex],
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                          for (var unitIndex = 0; unitIndex < data.maxUnit; unitIndex++)
                            Builder(builder: (ctx) {
                              final unit = unitIndex + 1;
                              final day = _TeacherTimetableScreenDays.days[dayIndex];
                              final cell = data.byDay[day]?[unit];
                              final teacherName = cell?.teacherName ?? '';
                              final className = cell?.className ?? '';
                              final startTime = cell?.startTime ?? '';
                              final endTime = cell?.endTime ?? '';
                              final isToday = cell?.dateKey == todayKey;

                              final empty = teacherName.trim().isEmpty;
                              final bg = empty
                                  ? Colors.transparent
                                  : (isToday
                                      ? Colors.green.withValues(alpha: 0.12)
                                      : Colors.blue.withValues(alpha: 0.12));
                              final border = empty
                                  ? Colors.transparent
                                  : (isToday
                                      ? Colors.green.withValues(alpha: 0.25)
                                      : Colors.blue.withValues(alpha: 0.25));

                              return SizedBox(
                                width: unitColW,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Container(
                                    height: slotH - 8,
                                    decoration: BoxDecoration(
                                      color: bg,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: border),
                                    ),
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: empty
                                        ? const Text(
                                            '—',
                                            style: TextStyle(color: Colors.white54),
                                          )
                                        : Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                className.isEmpty ? 'Class' : className,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontWeight: FontWeight.w600),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${startTime.isEmpty ? '' : startTime}${startTime.isEmpty ? '' : ' - '}${endTime.isEmpty ? '' : endTime}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                ],
              ),
            ).animate().fadeIn(duration: 200.ms);
          },
        );
      },
    );
  }
}


class _TeacherSlotCell {
  final String teacherName;
  final String className;
  final String startTime;
  final String endTime;
  final String? dateKey;

  _TeacherSlotCell({
    required this.teacherName,
    required this.className,
    required this.startTime,
    required this.endTime,
    required this.dateKey,
  });
}

class _MergedTeacherTimetable {
  final int maxUnit;
  final Map<String, Map<int, _TeacherSlotCell>> byDay;

  _MergedTeacherTimetable({required this.maxUnit, required this.byDay});
}

class _TeacherTimetableScreenDays {
  static const List<String> days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];
}

Stream<QuerySnapshot<Map<String, dynamic>>> _weeklyForTeacher(String teacherId) {
  return FirebaseFirestore.instance
      .collection('weekly_timetables')
      .where('teacherId', isEqualTo: teacherId)
      .snapshots();
}

/// Today's exceptions affecting this teacher — queried by BOTH
/// `originalTeacherId` (their own slot, possibly vacated by leave) AND
/// `teacherId` (a slot they're now covering for someone else). Querying
/// only by the live `teacherId` field (the old `daily_timetables` query
/// this replaces) was the actual bug: that field goes blank the instant a
/// slot is vacated by approved leave, so a teacher's own "today" view
/// would silently keep showing their normal weekly class instead of the
/// vacancy — the data and the screen disagreeing with each other.
Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _exceptionsForTeacherToday(
  String teacherId,
  String todayKey,
) {
  final ownStream = FirebaseFirestore.instance
      .collection('timetable_exceptions')
      .where('date', isEqualTo: todayKey)
      .where('originalTeacherId', isEqualTo: teacherId)
      .snapshots();
  final coveringStream = FirebaseFirestore.instance
      .collection('timetable_exceptions')
      .where('date', isEqualTo: todayKey)
      .where('teacherId', isEqualTo: teacherId)
      .snapshots();

  return Stream.multi((sink) {
    List<QueryDocumentSnapshot<Map<String, dynamic>>> own = [];
    List<QueryDocumentSnapshot<Map<String, dynamic>>> covering = [];

    void emit() {
      final byId = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final d in own) byId[d.id] = d;
      for (final d in covering) byId[d.id] = d;
      sink.add(byId.values.toList());
    }

    final s1 = ownStream.listen((snap) {
      own = snap.docs;
      emit();
    }, onError: sink.addError);
    final s2 = coveringStream.listen((snap) {
      covering = snap.docs;
      emit();
    }, onError: sink.addError);

    sink.onCancel = () async {
      await s1.cancel();
      await s2.cancel();
    };
  });
}

/// Merges weekly + today's exceptions for this teacher.
/// An exception overrides the weekly entry for the same (day, unit) when
/// it exists. A vacated slot (exception teacherId blank) renders as empty
/// instead of silently showing the normal weekly assignment.
Stream<_MergedTeacherTimetable> _mergeStreams(
  Stream<QuerySnapshot<Map<String, dynamic>>> weekly,
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> exceptions,
  String todayKey,
) {
  return Stream.multi((sink) {
    Map<String, Map<int, _TeacherSlotCell>> mergedByDay = {};
    int maxUnit = 0;

    Map<String, Map<int, _TeacherSlotCell>> weeklyMap = {};
    Map<String, Map<int, _TeacherSlotCell>> exceptionMap = {};

    void computeAndEmit() {
      mergedByDay = {};
      maxUnit = 0;

      void apply(Map<String, Map<int, _TeacherSlotCell>> source) {
        source.forEach((day, unitMap) {
          mergedByDay.putIfAbsent(day, () => {});
          unitMap.forEach((unit, cell) {
            mergedByDay[day]![unit] = cell;
            if (unit > maxUnit) maxUnit = unit;
          });
        });
      }

      // Weekly first...
      apply(weeklyMap);
      // ...then today's exceptions overwrite (including showing as empty
      // when an exception vacates a slot).
      apply(exceptionMap);

      sink.add(
        _MergedTeacherTimetable(
          maxUnit: maxUnit,
          byDay: mergedByDay,
        ),
      );
    }

    final weeklySub = weekly.listen(
      (snap) {
        weeklyMap = _extractMap(snap, dateKey: null);
        computeAndEmit();
      },
      onError: sink.addError,
    );

    final exceptionSub = exceptions.listen(
      (docs) {
        exceptionMap = _extractExceptionMap(docs, dateKey: todayKey);
        computeAndEmit();
      },
      onError: sink.addError,
    );

    sink.onCancel = () async {
      await weeklySub.cancel();
      await exceptionSub.cancel();
    };
  });
}

Map<String, Map<int, _TeacherSlotCell>> _extractExceptionMap(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs, {
  required String dateKey,
}) {
  final byDay = <String, Map<int, _TeacherSlotCell>>{};

  for (final doc in docs) {
    final data = doc.data();
    final day = (data['day'] as String?) ?? '';
    final unit = (data['unit'] as num?)?.toInt() ?? 0;
    if (day.isEmpty || unit <= 0) continue;

    // Blank teacherId here means genuinely vacant (leave with nobody
    // covering yet) — exactly what should render, not a fallback to the
    // weekly value.
    final teacherName = (data['teacherName'] as String?) ?? '';
    final className = (data['className'] as String?) ?? '';
    final startTime = (data['startTime'] as String?) ?? '';
    final endTime = (data['endTime'] as String?) ?? '';

    byDay.putIfAbsent(day, () => {});
    byDay[day]![unit] = _TeacherSlotCell(
      teacherName: teacherName,
      className: className,
      startTime: startTime,
      endTime: endTime,
      dateKey: dateKey,
    );
  }

  return byDay;
}

Map<String, Map<int, _TeacherSlotCell>> _extractMap(
  QuerySnapshot<Map<String, dynamic>> snap,
  {
  required String? dateKey,
  }
) {

  final byDay = <String, Map<int, _TeacherSlotCell>>{};

  for (final doc in snap.docs) {
    final data = doc.data();
    final day = (data['day'] as String?) ?? '';
    final unit = (data['unit'] as num?)?.toInt() ?? 0;
    if (day.isEmpty || unit <= 0) continue;

    final teacherName = (data['teacherName'] as String?) ?? '';
    final className = (data['className'] as String?) ?? '';
    final startTime = (data['startTime'] as String?) ?? '';
    final endTime = (data['endTime'] as String?) ?? '';

    byDay.putIfAbsent(day, () => {});
    byDay[day]![unit] = _TeacherSlotCell(
      teacherName: teacherName,
      className: className,
      startTime: startTime,
      endTime: endTime,
      dateKey: dateKey,
    );
  }

  return byDay;
}

