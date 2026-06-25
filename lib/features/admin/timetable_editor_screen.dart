import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/widgets/app_background.dart';
import '../../core/widgets/glass_card.dart';

import '../../core/services/timetable_service.dart';
import '../../core/services/user_service.dart';


class TimetableEditorScreen extends StatefulWidget {
  final String classId;
  final String className;

  const TimetableEditorScreen({
    super.key,
    required this.classId,
    required this.className,
  });

  @override
  State<TimetableEditorScreen> createState() => _TimetableEditorScreenState();
}

class _TimetableEditorScreenState extends State<TimetableEditorScreen> {
  static const _days = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
  ];

  Future<void> _onDropSwap({
    required String targetSlotId,
    required String? draggedTeacherSlotId,
    required String draggedTeacherId,
  }) async {
    // Placeholder for C: drag/drop clash-aware swap.
    // Next step will implement actual clash handling and rollback.
    if (draggedTeacherSlotId == null) {
      await TimetableService().assignTeacherToWeeklySlot(
        slotId: targetSlotId,
        teacherId: draggedTeacherId,
        teacherName: '',
      );
      return;
    }

    // TODO: use clash-aware swap with collision warnings + rollback.
    await TimetableService().assignTeacherToWeeklySlot(
      slotId: targetSlotId,
      teacherId: draggedTeacherId,
      teacherName: '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;



    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.className),
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('weekly_timetables')
                .where('classId', isEqualTo: widget.classId)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(
                  child: CircularProgressIndicator(),
                );
              }

              final docs = snapshot.data!.docs;
              if (docs.isEmpty) {
                return const Center(
                  child: Text('No timetable slots found for this class.'),
                );
              }

              final maxUnit = docs
                  .map((doc) =>
                      (doc.data() as Map<String, dynamic>)['unit'] as int)
                  .fold<int>(
                      0,
                      (previous, current) =>
                          current > previous ? current : previous);

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: GlassCard(
                  padding: const EdgeInsets.all(20),
                  child: DataTable(
                    columns: [
                      const DataColumn(
                        label: Text('Unit'),
                      ),
                      ...days.map((day) {
                        return DataColumn(
                          label: Text(day),
                        );
                      }),
                    ],
                    rows: List.generate(
                      maxUnit,
                      (unitIndex) {
                        final unit = unitIndex + 1;
                        return DataRow(
                          cells: [
                            DataCell(
                              Text('U$unit'),
                            ),
                            ...days.map((day) {
                              QueryDocumentSnapshot<Object?>? slot;
for (final doc in docs.cast<QueryDocumentSnapshot<Object?>>()) {
                                final data = doc.data() as Map<String, dynamic>;
                                if (data['day'] == day && data['unit'] == unit) {
                                  slot = doc;
                                  break;
                                }
                              }

                              if (slot == null) {
                                return const DataCell(Text('Empty'));
                              }

                              final data = slot.data() as Map<String, dynamic>;
                              return DataCell(
                                GestureDetector(
                                  onTap: () {
                                    assignTeacherDialog(context, slot!.id);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      data['teacherName'].toString().isEmpty
                                          ? 'Empty'
                                          : data['teacherName'],
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void assignTeacherDialog(BuildContext context, String slotId) {
    // Teacher suggestion ranking (B/B2):
    // 1) prefer teachers who do NOT teach consecutive units on this day
    // 2) then prefer least weekly load (defaultUnits+fixtureUnits) -> most
    //
    // Note: this dialog works off Firestore state at open time.
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Assign Teacher'),
          content: FutureBuilder<List<Map<String, dynamic>>>(
            future: _getRankedTeacherSuggestionsForSlot(slotId),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox(
                  height: 80,
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                );
              }

              final teachers = snapshot.data!;
              return SizedBox(
                width: 340,
                height: 420,
                child: teachers.isEmpty
                    ? const Center(child: Text('No teachers found'))
                    : ListView.builder(
                        itemCount: teachers.length,
                        itemBuilder: (context, index) {
                          final t = teachers[index];
                          final teacherId = t['uid'] as String;
                          final name = t['name'] as String? ?? 'Unknown';
                          final workload = (t['weeklyLoad'] as num?)?.toInt() ?? 0;
                          final consecutivePenalty =
                              (t['consecutivePenalty'] as num?)?.toInt() ?? 0;

                          return ListTile(
                            title: Text(name),
                            subtitle: Text(
                              '$workload units${consecutivePenalty > 0 ? ' • consecutive penalty $consecutivePenalty' : ''}',
                            ),
                            onTap: () async {
                              try {
                                await TimetableService().assignTeacherToWeeklySlot(
                                  slotId: slotId,
                                  teacherId: teacherId,
                                  teacherName: name,
                                );
                                if (!mounted) return;
                                Navigator.of(this.context).pop();
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(e.toString()),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      ),
              );
            },
          ),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _getRankedTeacherSuggestionsForSlot(
    String slotId,
  ) async {
    // Read the slot to know (day, unit).
    final slotDoc = await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .doc(slotId)
        .get();
    if (!slotDoc.exists) return const [];

    final slot = slotDoc.data()!;
    final day = (slot['day'] as String?) ?? '';
    final unit = (slot['unit'] as num?)?.toInt() ?? 0;
    if (day.isEmpty || unit <= 0) return const [];

    // Fetch teachers + their workload.
    final teachersSnap = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'teacher')
        .get();

    // Live permanent-unit count per teacher, computed from the actual
    // weekly_timetables collection — NOT the `defaultUnits` field on each
    // user doc, which is never recalculated when a teacher's schedule
    // changes (see UserService.getLivePermanentUnits for the full story).
    // One query, reused for every candidate below.
    final livePermanentUnits = await UserService().getLivePermanentUnitsForAllTeachers();

    // Fetch existing slots for each teacher on this day.
    // Then compute consecutive penalty: if teacher already has unit-1 or unit+1,
    // penalize.
    // Finally sort: penalty (0 best) then workload (least -> most).
    final timetableService = TimetableService();

    final result = <Map<String, dynamic>>[];
    for (final doc in teachersSnap.docs) {
      final data = doc.data();
      final teacherId = doc.id;
      final teacherName = data['name']?.toString() ?? 'Unknown';
      final defaultUnits = livePermanentUnits[teacherId] ?? 0;
      final fixtureUnits = (data['fixtureUnits'] as num?)?.toInt() ?? 0;
      final workload = defaultUnits + fixtureUnits;

      // Get teacher's slots on this day.
      final daySlots = await timetableService.getTeacherDaySchedule(
        teacherId,
        day,
      );

      final teachesUnitNums = daySlots
          .map((s) => (s['unit'] as num?)?.toInt() ?? -999)
          .toSet();

      final hasConsecutiveBefore = teachesUnitNums.contains(unit - 1);
      final hasConsecutiveAfter = teachesUnitNums.contains(unit + 1);

      final consecutivePenalty =
          (hasConsecutiveBefore ? 1 : 0) + (hasConsecutiveAfter ? 1 : 0);

      result.add({
        'uid': teacherId,
        'name': teacherName,
        'weeklyLoad': workload,
        'consecutivePenalty': consecutivePenalty,
      });
    }

    result.sort((a, b) {
      final pa = (a['consecutivePenalty'] as num?)?.toInt() ?? 0;
      final pb = (b['consecutivePenalty'] as num?)?.toInt() ?? 0;
      if (pa != pb) return pa.compareTo(pb);
      final wa = (a['weeklyLoad'] as num?)?.toInt() ?? 0;
      final wb = (b['weeklyLoad'] as num?)?.toInt() ?? 0;
      return wa.compareTo(wb);
    });

    return result;
  }

}
