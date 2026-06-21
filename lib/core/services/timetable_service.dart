import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/timetable_constants.dart';
import '../utils/timetable_generator.dart';
import 'admin_config_service.dart';
import 'clash_handling_mode.dart';
import 'timetable_clash_outcome.dart';
import 'audit_log_service.dart';
import 'notification_service.dart';

import '../../models/class_model.dart';
import '../../models/timetable_slot_model.dart';

import '../../models/time_profile_model.dart';

class GenerationOutcome {
  final int assigned;
  final int total;
  final List<String> warnings;

  const GenerationOutcome({
    required this.assigned,
    required this.total,
    required this.warnings,
  });
}

class TimetableService {
  final FirebaseFirestore _firestore;
  final AuditLogService _auditLogService;

  TimetableService({FirebaseFirestore? firestore, AuditLogService? auditLogService})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auditLogService = auditLogService ?? AuditLogService();

  CollectionReference<Map<String, dynamic>> get _weekly =>
      _firestore.collection('weekly_timetables');
  CollectionReference<Map<String, dynamic>> get _daily =>
      _firestore.collection('daily_timetables');
  CollectionReference<Map<String, dynamic>> get _classes =>
      _firestore.collection('classes');

  String slotId(String classId, String day, int unit) =>
      '${classId}_${day}_$unit';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Stream<List<TimetableSlotModel>> streamClassTimetable(String classId) {
    return _weekly.where('classId', isEqualTo: classId).snapshots().map((snap) {
      final slots = snap.docs
          .map((d) => TimetableSlotModel.fromMap(d.id, d.data()))
          .toList();
      slots.sort((a, b) {
        final d = workingDayIndex(a.day).compareTo(workingDayIndex(b.day));
        return d != 0 ? d : a.unit.compareTo(b.unit);
      });
      return slots;
    });
  }

  Stream<List<TimetableSlotModel>> streamTeacherTimetable(String teacherId) {
    return _weekly
        .where('teacherId', isEqualTo: teacherId)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => TimetableSlotModel.fromMap(d.id, d.data()))
            .toList());
  }

  Future<ClassModel?> getClass(String classId) async {
    final doc = await _classes.doc(classId).get();
    if (!doc.exists) return null;
    return ClassModel.fromMap({...doc.data()!, 'id': doc.id});
  }

  Future<TimeProfileModel?> getTimeProfile(String timeProfileId) async {
    if (timeProfileId.isEmpty) return null;
    final doc =
        await _firestore.collection('time_profiles').doc(timeProfileId).get();
    if (!doc.exists) return null;
    return TimeProfileModel.fromMap({...doc.data()!, 'id': doc.id});
  }

  Future<List<Map<String, dynamic>>> getTeacherDaySchedule(
    String teacherId,
    String day,
  ) async {
    final snap = await _weekly
        .where('teacherId', isEqualTo: teacherId)
        .where('day', isEqualTo: day)
        .get();
    final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
    list.sort((a, b) =>
        ((a['unit'] as num?) ?? 0).compareTo((b['unit'] as num?) ?? 0));
    return list;
  }

  // ---------------------------------------------------------------------------
  // Grid scaffolding
  // ---------------------------------------------------------------------------

  Future<void> ensureWeeklyScaffold(String classId) async {
    final cls = await getClass(classId);
    if (cls == null) throw Exception('Class not found');

    final profile = await getTimeProfile(cls.timeProfileId);
    // Only teaching periods become timetable slots — breaks (recess,
    // lunch, etc) are first-class entries in the Time Profile but are
    // never assigned a teacher/class.
    final periods = profile?.teachingPeriods ?? const <TimePeriod>[];
    if (periods.isEmpty) {
      throw Exception(
          'Time profile "${cls.timeProfileId}" has no teaching periods. Add periods before building the grid.');
    }

    final periodsSorted = [...periods]
      ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    final unitCount = cls.unitsPerDay <= 0
        ? periodsSorted.length
        : (cls.unitsPerDay < periodsSorted.length
            ? cls.unitsPerDay
            : periodsSorted.length);

    final existing = await _weekly.where('classId', isEqualTo: classId).get();
    final existingIds = existing.docs.map((d) => d.id).toSet();

    final batch = _firestore.batch();
    var created = 0;
    for (final day in cls.workingDays) {
      for (var i = 0; i < unitCount; i++) {
        final unit = i + 1;
        final id = slotId(classId, day, unit);
        if (existingIds.contains(id)) continue;
        final period = periodsSorted[i];
        batch.set(_weekly.doc(id), {
          'classId': classId,
          'className': cls.className,
          'day': day,
          'unit': unit,
          'startTime': period.startTime,
          'endTime': period.endTime,
          'teacherId': '',
          'teacherName': '',
          'type': 'permanent',
          'originalTeacherId': '',
          'createdAt': FieldValue.serverTimestamp(),
        });
        created++;
      }
    }
    if (created > 0) await batch.commit();
  }

  // ---------------------------------------------------------------------------
  // Manual editing
  // ---------------------------------------------------------------------------

  Future<void> assignTeacher({
    required String slotId,
    required String teacherId,
    required String teacherName,
  }) async {
    await _weekly.doc(slotId).set({
      'teacherId': teacherId,
      'teacherName': teacherName,
      'originalTeacherId': teacherId,
      'type': 'permanent',
      'assignedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> assignTeacherToWeeklySlot({
    required String slotId,
    required String teacherId,
    required String teacherName,
  }) =>
      assignTeacher(
          slotId: slotId, teacherId: teacherId, teacherName: teacherName);

  Future<void> clearSlot(String slotId) async {
    await _weekly.doc(slotId).set({
      'teacherId': '',
      'teacherName': '',
      'originalTeacherId': '',
      'type': 'permanent',
      'clearedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------------
  // Teacher name lookup helper
  // ---------------------------------------------------------------------------

  /// Looks up teacher display name from users collection.
  /// Falls back to empty string so callers never crash on missing data.
  Future<String> _fetchTeacherName(String teacherId) async {
    if (teacherId.isEmpty) return '';
    try {
      final doc = await _firestore.collection('users').doc(teacherId).get();
      return (doc.data()?['name'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  // ---------------------------------------------------------------------------
  // Drag/drop clash-aware assignment
  // ---------------------------------------------------------------------------

  Future<ClashAssignmentOutcome> assignTeacherWithClashHandling({
    required String classId,
    required String destinationSlotId,
    required String draggedTeacherId,
    required ClashHandlingMode mode,
    bool overrideQuota = false,
  }) async {
    if (draggedTeacherId.isEmpty) {
      return const ClashAssignmentOutcome(assigned: false, warnings: []);
    }

    // Look up teacher name ONCE before any write operation.
    final draggedTeacherName = await _fetchTeacherName(draggedTeacherId);

    final destSnap = await _weekly.doc(destinationSlotId).get();
    if (!destSnap.exists) {
      throw Exception('Destination slot not found: $destinationSlotId');
    }
    final dest = destSnap.data() as Map<String, dynamic>;
    final destDay = (dest['day'] as String?) ?? '';
    final destUnitNum = (dest['unit'] as num?)?.toInt() ?? 0;
    if (destDay.isEmpty || destUnitNum <= 0) {
      throw Exception('Destination slot missing day/unit: $destinationSlotId');
    }

    final busySlotsSnap = await _weekly
        .where('teacherId', isEqualTo: draggedTeacherId)
        .where('day', isEqualTo: destDay)
        .get();

    final destStart = (dest['startTime'] as String?) ?? '';
    final destEnd = (dest['endTime'] as String?) ?? '';

    // Hard-rule clash: an actual time overlap (this class or any other).
    final overlapping = <Map<String, dynamic>>[];
    // Strong-rule clash: same teacher already teaching THIS class on the
    // SAME day at a different (non-overlapping) unit. Not physically
    // impossible, but violates "max one unit/day per teacher in a class".
    final sameClassSameDayOther = <Map<String, dynamic>>[];

    for (final d in busySlotsSnap.docs) {
      if (d.id == destinationSlotId) continue; // reassigning the same slot is never a clash with itself
      final data = d.data();
      final otherStart = (data['startTime'] as String?) ?? '';
      final otherEnd = (data['endTime'] as String?) ?? '';

      if (otherStart.isNotEmpty &&
          otherEnd.isNotEmpty &&
          _timeRangesOverlap(otherStart, otherEnd, destStart, destEnd)) {
        overlapping.add({...data, 'id': d.id});
        continue;
      }

      if ((data['classId'] as String?) == classId) {
        sameClassSameDayOther.add({...data, 'id': d.id});
      }
    }

    // Quota check — tightened to actively AVOID exceeding quota rather than
    // merely warning about it. Two layers:
    //  1) Per-class quota (`unitsWeek` configured on the class's teacher list)
    //  2) Whole-school weekly cap (admin Settings -> max units per teacher),
    //     counted across every class this teacher is in.
    // Either layer can be bypassed with an explicit `overrideQuota: true`
    // (used by the UI's "assign anyway?" confirmation) — but only if the
    // admin has Settings -> "Allow quota override" turned on.
    String? quotaWarning;
    final cls = await getClass(classId);
    if (cls != null) {
      final matchingTeachers =
          cls.teachers.where((t) => t.teacherId == draggedTeacherId).toList();
      final quota = matchingTeachers.isEmpty ? null : matchingTeachers.first.unitsWeek;
      if (quota != null) {
        final currentCountSnap = await _weekly
            .where('classId', isEqualTo: classId)
            .where('teacherId', isEqualTo: draggedTeacherId)
            .get();
        final currentCount = currentCountSnap.docs
            .where((d) => d.id != destinationSlotId)
            .length;
        if (currentCount + 1 > quota) {
          quotaWarning =
              '${draggedTeacherName.isEmpty ? draggedTeacherId : draggedTeacherName} would exceed their weekly quota for this class (${currentCount + 1}/$quota).';
        }
      }
    }

    if (quotaWarning == null) {
      final maxUnits = await AdminConfigService().getMaxUnitsPerTeacher();
      final totalSnap = await _weekly
          .where('teacherId', isEqualTo: draggedTeacherId)
          .get();
      final totalCount = totalSnap.docs
          .where((d) => d.id != destinationSlotId)
          .length;
      if (totalCount + 1 > maxUnits) {
        quotaWarning =
            '${draggedTeacherName.isEmpty ? draggedTeacherId : draggedTeacherName} would exceed the school\'s $maxUnits-unit weekly cap (${totalCount + 1}/$maxUnits).';
      }
    }

    if (quotaWarning != null && !overrideQuota) {
      final allowOverride = await AdminConfigService().getAllowQuotaOverride();
      return ClashAssignmentOutcome(
        assigned: false,
        warnings: [quotaWarning],
        quotaExceeded: allowOverride,
      );
    }

    if (overlapping.isNotEmpty) {
      final warnings = [
        'Clash: ${draggedTeacherName.isEmpty ? draggedTeacherId : draggedTeacherName} is already busy on $destDay (unit $destUnitNum).',
      ];

      switch (mode) {
        case ClashHandlingMode.rollback:
          return ClashAssignmentOutcome(assigned: false, warnings: warnings);
        case ClashHandlingMode.warnOnly:
          await assignTeacher(
            slotId: destinationSlotId,
            teacherId: draggedTeacherId,
            teacherName: draggedTeacherName,
          );
          return ClashAssignmentOutcome(assigned: true, warnings: warnings);
        case ClashHandlingMode.autoFindNonClashing:
          final clearedAny = await _tryAutoResolveClash(
            teacherId: draggedTeacherId,
            conflictingSlotIds: overlapping.map((e) => e['id'] as String).toList(),
            mode: mode,
          );
          if (clearedAny) {
            await assignTeacher(
              slotId: destinationSlotId,
              teacherId: draggedTeacherId,
              teacherName: draggedTeacherName,
            );
            return const ClashAssignmentOutcome(assigned: true, warnings: []);
          }
          return ClashAssignmentOutcome(assigned: false, warnings: warnings);
      }
    }

    // No hard (time-overlap) clash. Still surface soft warnings (same-day
    // double-booking within this class, quota overflow) but allow the
    // assignment to proceed — admins need the ability to override.
    final softWarnings = <String>[];
    if (sameClassSameDayOther.isNotEmpty) {
      softWarnings.add(
          '${draggedTeacherName.isEmpty ? draggedTeacherId : draggedTeacherName} already teaches this class on $destDay at another unit.');
    }
    if (quotaWarning != null) {
      softWarnings.add(quotaWarning);
    }

    await assignTeacher(
      slotId: destinationSlotId,
      teacherId: draggedTeacherId,
      teacherName: draggedTeacherName,
    );

    await _log('assign_teacher', {
      'classId': classId,
      'slotId': destinationSlotId,
      'teacherId': draggedTeacherId,
      'teacherName': draggedTeacherName,
      'handlingMode': mode.toString(),
    });

    final className = cls?.className ?? 'a class';
    await NotificationService().notifyTeacher(
      teacherId: draggedTeacherId,
      title: 'Timetable updated',
      body: 'You\'ve been assigned to $className on $destDay (unit $destUnitNum).',
      type: NotificationType.classOccurring,
      data: {'classId': classId, 'slotId': destinationSlotId},
    );

    return ClashAssignmentOutcome(assigned: true, warnings: softWarnings);
  }

  Future<void> _log(String action, Map<String, dynamic> details) async {
    try {
      await _auditLogService.log(action: action, details: details);
    } catch (_) {}
  }

  Future<bool> _tryAutoResolveClash({
    required String teacherId,
    required List<String> conflictingSlotIds,
    required ClashHandlingMode mode,
  }) async {
    if (conflictingSlotIds.isEmpty) return false;

    var cleared = 0;
    for (final slotId in conflictingSlotIds) {
      final snap = await _weekly.doc(slotId).get();
      if (!snap.exists) continue;
      final data = snap.data() as Map<String, dynamic>;
      final currentTeacher = (data['teacherId'] as String?) ?? '';
      if (currentTeacher != teacherId) continue;

      final type = (data['type'] as String?) ?? 'permanent';
      if (type == 'override') {
        await clearSlot(slotId);
        cleared++;
      }
    }

    return cleared > 0;
  }

  Future<void> exchangeSlots({
    required String slotId1,
    required String slotId2,
  }) async {
    if (slotId1 == slotId2) return;
    final ref1 = _weekly.doc(slotId1);
    final ref2 = _weekly.doc(slotId2);

    await _firestore.runTransaction((tx) async {
      final s1 = await tx.get(ref1);
      final s2 = await tx.get(ref2);
      if (!s1.exists || !s2.exists) {
        throw Exception('One of the slots no longer exists.');
      }
      final d1 = s1.data()!;
      final d2 = s2.data()!;

      tx.update(ref1, {
        'teacherId': d2['teacherId'] ?? '',
        'teacherName': d2['teacherName'] ?? '',
        'type': 'override',
        'exchangedAt': FieldValue.serverTimestamp(),
      });
      tx.update(ref2, {
        'teacherId': d1['teacherId'] ?? '',
        'teacherName': d1['teacherName'] ?? '',
        'type': 'override',
        'exchangedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Same-day teacher exchange that touches ONLY the daily timetable for
  /// that one date — the recurring weekly template is never modified.
  /// Tomorrow, the weekly pattern (and therefore tomorrow's daily
  /// schedule) is back to normal automatically. This is the correct
  /// "today-only swap" behaviour; [exchangeSlots] permanently rewrites the
  /// weekly template and should only be used by admin-driven permanent
  /// timetable edits, never by a teacher's own same-day exchange request.
  Future<void> exchangeDailySlots({
    required String dailySlotId1,
    required String dailySlotId2,
  }) async {
    if (dailySlotId1 == dailySlotId2) return;
    final ref1 = _daily.doc(dailySlotId1);
    final ref2 = _daily.doc(dailySlotId2);

    Map<String, dynamic>? d1;
    Map<String, dynamic>? d2;
    await _firestore.runTransaction((tx) async {
      final s1 = await tx.get(ref1);
      final s2 = await tx.get(ref2);
      if (!s1.exists || !s2.exists) {
        throw Exception('One of the slots no longer exists.');
      }
      d1 = s1.data()!;
      d2 = s2.data()!;

      tx.update(ref1, {
        'teacherId': d2!['teacherId'] ?? '',
        'teacherName': d2!['teacherName'] ?? '',
        'type': 'override',
        'exchangedAt': FieldValue.serverTimestamp(),
      });
      tx.update(ref2, {
        'teacherId': d1!['teacherId'] ?? '',
        'teacherName': d1!['teacherName'] ?? '',
        'type': 'override',
        'exchangedAt': FieldValue.serverTimestamp(),
      });
    });

    // Notify both teachers their daily schedule changed (today only).
    final swapped = [
      {'teacherId': d2?['teacherId'], 'data': d1},
      {'teacherId': d1?['teacherId'], 'data': d2},
    ];
    for (final entry in swapped) {
      final teacherId = entry['teacherId']?.toString() ?? '';
      final data = entry['data'] as Map<String, dynamic>?;
      if (teacherId.isEmpty || data == null) continue;
      await NotificationService().notifyTimetableChange(
        teacherId: teacherId,
        className: data['className']?.toString() ?? '',
        day: data['day']?.toString() ?? '',
        unit: (data['unit'] as num?)?.toInt() ?? 0,
        isPermanent: false,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Class teacher / quota configuration
  // ---------------------------------------------------------------------------

  Future<void> setClassTeacherConfig({
    required String classId,
    required List<ClassTeacherAssignment> teachers,
  }) async {
    final classTeacher = teachers
        .cast<ClassTeacherAssignment?>()
        .firstWhere((t) => t!.isClassTeacher, orElse: () => null);

    await _classes.doc(classId).set({
      'teachers': teachers.map((t) => t.toMap()).toList(),
      'classTeacherId': classTeacher?.teacherId ?? '',
      'classTeacherName': classTeacher?.teacherName ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------------
  // Auto generation
  // ---------------------------------------------------------------------------

  Future<GenerationOutcome> generateAndApplyClassTimetable({
    required String classId,
    bool force = false,
  }) async {
    final cls = await getClass(classId);
    if (cls == null) throw Exception('Class not found');
    if (cls.teachers.isEmpty) {
      throw Exception(
          'No teachers configured for this class. Set teacher quotas first.');
    }

    await ensureWeeklyScaffold(classId);

    final slotSnap = await _weekly.where('classId', isEqualTo: classId).get();
    final slots = slotSnap.docs
        .map((d) => TimetableSlotModel.fromMap(d.id, d.data()))
        .toList();

    final assignmentSlots = slots
        .map((s) => AssignmentSlot(
              day: s.day,
              unit: s.unit,
              slotId: s.id,
              startTime: s.startTime,
              endTime: s.endTime,
            ))
        .toList();

    final quotas = cls.teachers
        .map((t) => TeacherQuota(
              uid: t.teacherId,
              name: t.teacherName,
              unitsWeek: t.unitsWeek,
              isClassTeacher: t.isClassTeacher,
            ))
        .toList();

    final externalBusy = await _buildExternalBusy(excludeClassId: classId);

    final result = TimetableGenerator.generate(
      slots: assignmentSlots,
      teacherQuotas: quotas,
      externalBusy: externalBusy,
      force: force,
    );

    final nameByUid = {for (final t in cls.teachers) t.teacherId: t.teacherName};

    const batchLimit = 400;
    final ids = slots.map((s) => s.id).toList();
    for (var i = 0; i < ids.length; i += batchLimit) {
      final batch = _firestore.batch();
      for (final id in ids.skip(i).take(batchLimit)) {
        final teacherId = result.slotIdToTeacherId[id] ?? '';
        batch.set(
          _weekly.doc(id),
          {
            'teacherId': teacherId,
            'teacherName': teacherId.isEmpty ? '' : (nameByUid[teacherId] ?? ''),
            'originalTeacherId': teacherId,
            'type': 'permanent',
            'generatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
      await batch.commit();
    }

    // Real notification: tell each affected teacher their timetable for
    // this class changed, instead of changing it silently behind the scenes.
    final affectedTeacherIds = result.slotIdToTeacherId.values.toSet();
    for (final teacherId in affectedTeacherIds) {
      if (teacherId.isEmpty) continue;
      await NotificationService().notifyTeacher(
        teacherId: teacherId,
        title: 'Timetable updated',
        body: 'Your weekly timetable for ${cls.className} has been regenerated.',
        type: NotificationType.classOccurring,
        data: {'classId': classId},
      );
    }

    return GenerationOutcome(
      assigned: result.slotIdToTeacherId.length,
      total: slots.length,
      warnings: result.warnings,
    );
  }

  Future<Map<String, List<BusyBlock>>> _buildExternalBusy({
    required String excludeClassId,
  }) async {
    final snap = await _weekly.get();
    final busy = <String, List<BusyBlock>>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      if (data['classId'] == excludeClassId) continue;
      final teacherId = (data['teacherId'] as String?) ?? '';
      if (teacherId.isEmpty) continue;
      busy.putIfAbsent(teacherId, () => []).add(BusyBlock(
            day: data['day'] as String? ?? '',
            startTime: data['startTime'] as String? ?? '',
            endTime: data['endTime'] as String? ?? '',
          ));
    }
    return busy;
  }

  // ---------------------------------------------------------------------------
  // Leave-driven daily clearing (daily-only; weekly is never touched)
  // ---------------------------------------------------------------------------

  /// Called when a leave request is approved. For every day in the leave
  /// range, materializes (if needed) and clears that teacher's DAILY slots
  /// only — the permanent weekly pattern is never modified, since the
  /// teacher is still expected back on a normal week once leave ends.
  ///
  /// Returns the list of vacated slot details (for fixture creation and
  /// for telling the teacher exactly what was affected).
  Future<List<Map<String, dynamic>>> clearScheduleForApprovedLeave({
    required String teacherId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final vacated = <Map<String, dynamic>>[];

    var cursor = DateTime(startDate.year, startDate.month, startDate.day);
    final last = DateTime(endDate.year, endDate.month, endDate.day);

    while (!cursor.isAfter(last)) {
      final dateKey =
          '${cursor.year.toString().padLeft(4, '0')}-${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}';

      // Make sure today's daily slots exist before we try to clear them.
      // Safe to call repeatedly: it never overwrites existing daily-only
      // overrides (see generateDailyForDate).
      await generateDailyForDate(cursor);

      final slotsSnap = await _daily
          .where('date', isEqualTo: dateKey)
          .where('teacherId', isEqualTo: teacherId)
          .get();

      if (slotsSnap.docs.isNotEmpty) {
        final batch = _firestore.batch();
        for (final doc in slotsSnap.docs) {
          final data = doc.data();
          batch.update(doc.reference, {
            'teacherId': '',
            'teacherName': '',
            'type': 'on_leave',
            'vacatedAt': FieldValue.serverTimestamp(),
            'vacatedReason': 'approved_leave',
          });

          vacated.add({
            'classId': data['classId'],
            'className': data['className'],
            'day': data['day'],
            'unit': data['unit'],
            'startTime': data['startTime'],
            'endTime': data['endTime'],
            'date': dateKey,
            'absentTeacherId': teacherId,
            'sourceDailySlotId': doc.id,
          });
        }
        await batch.commit();
      }

      cursor = cursor.add(const Duration(days: 1));
    }

    return vacated;
  }

  // ---------------------------------------------------------------------------
  // Daily materialisation
  // ---------------------------------------------------------------------------

  // Daily-only override types: once a daily slot has one of these, a
  // weekly-driven refresh must never touch it again. This is what makes
  // "daily is independent of weekly" actually true instead of aspirational.
  static const Set<String> _dailyOverrideTypes = {
    'on_leave',
    'fixture_assigned',
    'override',
  };

  Future<int> generateDailyForDate(DateTime date, {String? classId}) async {
    final dateKey =
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final day = dayNameForDate(date);

    Query<Map<String, dynamic>> q = _weekly.where('day', isEqualTo: day);
    if (classId != null) q = q.where('classId', isEqualTo: classId);
    final snap = await q.get();

    if (snap.docs.isEmpty) return 0;

    // Find which daily slots already have a daily-only override so we can
    // skip them entirely below — a weekly refresh must never clobber these.
    Query<Map<String, dynamic>> existingQuery =
        _daily.where('date', isEqualTo: dateKey);
    if (classId != null) existingQuery = existingQuery.where('classId', isEqualTo: classId);
    final existingSnap = await existingQuery.get();
    final overriddenSlotIds = <String>{
      for (final d in existingSnap.docs)
        if (_dailyOverrideTypes.contains(d.data()['type']))
          (d.data()['sourceSlotId'] as String? ?? '')
    };

    const batchLimit = 400;
    final docs = snap.docs;
    var written = 0;
    for (var i = 0; i < docs.length; i += batchLimit) {
      final batch = _firestore.batch();
      for (final doc in docs.skip(i).take(batchLimit)) {
        if (overriddenSlotIds.contains(doc.id)) continue; // protect the override

        final data = doc.data();
        final id = '${dateKey}_${doc.id}';
        batch.set(_daily.doc(id), {
          ...data,
          'date': dateKey,
          'sourceSlotId': doc.id,
          'materializedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        written++;
      }
      await batch.commit();
    }
    return written;
  }

  // ---------------------------------------------------------------------------
  // Class / profile creation
  // ---------------------------------------------------------------------------

  Future<void> createTimeProfile({
    required String name,
    required List periods,
  }) async {
    await _firestore.collection('time_profiles').add({
      'name': name,
      'periods': periods is List<TimePeriod>
          ? periods.map((p) => p.toMap()).toList()
          : periods,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Overwrites an existing time profile's name/periods in place. Existing
  /// timetable slots already scaffolded against the old periods are left
  /// untouched — call [ensureWeeklyScaffold] per class afterwards (or use
  /// the "Resync" action) if classes using this profile should pick up the
  /// new timings/period count.
  Future<void> updateTimeProfile({
    required String timeProfileId,
    required String name,
    required List<TimePeriod> periods,
  }) async {
    await _firestore.collection('time_profiles').doc(timeProfileId).set({
      'name': name,
      'periods': periods.map((p) => p.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<List<TimeProfileModel>> watchTimeProfiles() {
    return _firestore.collection('time_profiles').snapshots().map((snap) {
      final list = snap.docs
          .map((d) => TimeProfileModel.fromMap({...d.data(), 'id': d.id}))
          .toList();
      list.sort((a, b) => a.name.compareTo(b.name));
      return list;
    });
  }

  /// Every class currently using [timeProfileId], by name — used to warn
  /// before deleting/editing a profile that's actively in use.
  Future<List<String>> classesUsingTimeProfile(String timeProfileId) async {
    final snap = await _classes
        .where('timeProfileId', isEqualTo: timeProfileId)
        .get();
    return snap.docs
        .map((d) => (d.data()['className'] as String?) ?? d.id)
        .toList();
  }

  /// Deletes a time profile. Throws if any class still references it —
  /// callers should check [classesUsingTimeProfile] first and let the
  /// admin confirm/reassign before forcing this.
  Future<void> deleteTimeProfile(String timeProfileId, {bool force = false}) async {
    if (!force) {
      final inUse = await classesUsingTimeProfile(timeProfileId);
      if (inUse.isNotEmpty) {
        throw Exception(
            'This time profile is used by: ${inUse.join(', ')}. Reassign those classes first.');
      }
    }
    await _firestore.collection('time_profiles').doc(timeProfileId).delete();
  }

  /// Every teacher's busy (day, startTime, endTime) blocks across ALL
  /// classes — the cross-class version of [_buildExternalBusy] (which
  /// excludes one class for the generator). Used by the timetable editor
  /// UI to grey out busy teachers in the roster / teacher picker and to
  /// tint drag targets red/green while dragging.
  Future<Map<String, List<BusyBlock>>> buildAllTeacherBusyBlocks() async {
    final snap = await _weekly.get();
    final busy = <String, List<BusyBlock>>{};
    for (final doc in snap.docs) {
      final data = doc.data();
      final teacherId = (data['teacherId'] as String?) ?? '';
      if (teacherId.isEmpty) continue;
      busy.putIfAbsent(teacherId, () => []).add(BusyBlock(
            day: data['day'] as String? ?? '',
            startTime: data['startTime'] as String? ?? '',
            endTime: data['endTime'] as String? ?? '',
          ));
    }
    return busy;
  }

  /// True if [teacherId] has a real time-overlap clash on [day] against
  /// [startTime]-[endTime], per the busy map from [buildAllTeacherBusyBlocks].
  /// [ignoreSlotDay]/[ignoreStart]/[ignoreEnd] let callers exclude the
  /// destination slot itself (so re-dropping a teacher onto their own
  /// current slot never shows as "busy").
  bool isTeacherBusyAt(
    Map<String, List<BusyBlock>> busyMap,
    String teacherId,
    String day,
    String startTime,
    String endTime,
  ) {
    final blocks = busyMap[teacherId];
    if (blocks == null || blocks.isEmpty) return false;
    for (final b in blocks) {
      if (b.day != day) continue;
      if (_timeRangesOverlap(b.startTime, b.endTime, startTime, endTime)) {
        return true;
      }
    }
    return false;
  }

  Future<String> createClass({
    required String className,
    required String timeProfileId,
    required int unitsPerDay,
    List<String> workingDays = kWorkingDays,
  }) async {
    final ref = await _classes.add({
      'className': className,
      'timeProfileId': timeProfileId,
      'unitsPerDay': unitsPerDay,
      'workingDays': workingDays,
      'classTeacherId': '',
      'classTeacherName': '',
      'teachers': <Map<String, dynamic>>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Updates editable class metadata (name, time profile, units/day, working
  /// days). Used by the admin "Manage Classes" screen's Edit action.
  ///
  /// Note: changing [timeProfileId] or [unitsPerDay] does not retroactively
  /// remove existing weekly slots; call [ensureWeeklyScaffold] afterwards if
  /// you want the grid to pick up newly-added periods/days.
  Future<void> updateClassDetails({
    required String classId,
    required String className,
    required String timeProfileId,
    required int unitsPerDay,
    required List<String> workingDays,
  }) async {
    await _classes.doc(classId).set({
      'className': className,
      'timeProfileId': timeProfileId,
      'unitsPerDay': unitsPerDay,
      'workingDays': workingDays,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteClass(String classId) async {
    final slots = await _weekly.where('classId', isEqualTo: classId).get();

    const batchLimit = 400;
    final docs = slots.docs;
    for (var i = 0; i < docs.length; i += batchLimit) {
      final batch = _firestore.batch();
      for (final d in docs.skip(i).take(batchLimit)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
    await _classes.doc(classId).delete();
  }

  bool _timeRangesOverlap(String aStart, String aEnd, String bStart, String bEnd) {
    final aS = _parseTimeToMinutes(aStart);
    final aE = _parseTimeToMinutes(aEnd);
    final bS = _parseTimeToMinutes(bStart);
    final bE = _parseTimeToMinutes(bEnd);

    if (aS == null || aE == null || bS == null || bE == null) return false;
    return aS < bE && bS < aE;
  }

  int? _parseTimeToMinutes(String t) {
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
}
