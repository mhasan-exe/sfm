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
import '../../models/timetable_exception_model.dart';

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

/// One weekly slot merged with whatever exception applies to it on a
/// specific date — what a UI should actually render for "today"/"this
/// date", without ever needing a second materialized copy of the schedule.
class EffectiveSlot {
  final TimetableSlotModel weekly;
  final TimetableExceptionModel? exception;

  const EffectiveSlot({required this.weekly, this.exception});

  String get teacherId => exception?.teacherId ?? weekly.teacherId;
  String get teacherName => exception?.teacherName ?? weekly.teacherName;
  bool get isException => exception != null;
  String get effectiveType => exception?.type ?? weekly.type;
}

class TimetableService {
  final FirebaseFirestore _firestore;
  final AuditLogService _auditLogService;

  TimetableService({FirebaseFirestore? firestore, AuditLogService? auditLogService})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auditLogService = auditLogService ?? AuditLogService();

  CollectionReference<Map<String, dynamic>> get _weekly =>
      _firestore.collection('weekly_timetables');

  /// Sparse per-date deviations. REPLACES the old `daily_timetables`
  /// collection — see TimetableExceptionModel for why.
  CollectionReference<Map<String, dynamic>> get _exceptions =>
      _firestore.collection('timetable_exceptions');

  CollectionReference<Map<String, dynamic>> get _classes =>
      _firestore.collection('classes');

  String slotId(String classId, String day, int unit) =>
      '${classId}_${day}_$unit';

  /// Deterministic exception doc id for (slot, date). Deterministic IDs are
  /// what make every exception write idempotent: approving the same leave
  /// twice, a retried write after a dropped connection, or two admins
  /// approving the same request at once can never create two different
  /// documents for the same slot+date — the second write just overwrites
  /// the first with identical data.
  String exceptionId(String slotId, String dateKey) => '${slotId}_$dateKey';

  String dateKeyFor(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

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

  /// Every exception for a given calendar date, optionally restricted to one
  /// class. This is the ONLY thing a UI needs (on top of the weekly stream)
  /// to render "today" / "this specific date" correctly — no materialization
  /// step required, because exceptions are written the moment they happen
  /// (leave approved, exchange confirmed, fixture covered).
  Stream<List<TimetableExceptionModel>> streamExceptionsForDate(
    String dateKey, {
    String? classId,
  }) {
    Query<Map<String, dynamic>> q = _exceptions.where('date', isEqualTo: dateKey);
    if (classId != null) q = q.where('classId', isEqualTo: classId);
    return q.snapshots().map((snap) => snap.docs
        .map((d) => TimetableExceptionModel.fromMap(d.id, d.data()))
        .toList());
  }

  /// Every exception that affects [teacherId] on [dateKey] — either because
  /// it's normally their slot (originalTeacherId) or because they're now
  /// covering it (teacherId). Queried as two separate equality filters and
  /// merged client-side on purpose: a single `where` on `originalTeacherId`
  /// alone would miss cover assignments, and querying by the *current*
  /// `teacherId` alone is exactly the bug this replaces — that field goes
  /// blank the instant a slot is vacated, so the affected teacher's own
  /// view would stop showing their own vacancy.
  Stream<List<TimetableExceptionModel>> streamExceptionsForTeacherDate(
    String teacherId,
    String dateKey,
  ) {
    final ownStream = _exceptions
        .where('date', isEqualTo: dateKey)
        .where('originalTeacherId', isEqualTo: teacherId)
        .snapshots();
    final coveringStream = _exceptions
        .where('date', isEqualTo: dateKey)
        .where('teacherId', isEqualTo: teacherId)
        .snapshots();

    return Stream.multi((sink) {
      List<TimetableExceptionModel> own = [];
      List<TimetableExceptionModel> covering = [];

      void emit() {
        final byId = <String, TimetableExceptionModel>{};
        for (final e in own) byId[e.id] = e;
        for (final e in covering) byId[e.id] = e;
        sink.add(byId.values.toList());
      }

      final s1 = ownStream.listen((snap) {
        own = snap.docs.map((d) => TimetableExceptionModel.fromMap(d.id, d.data())).toList();
        emit();
      }, onError: sink.addError);
      final s2 = coveringStream.listen((snap) {
        covering = snap.docs.map((d) => TimetableExceptionModel.fromMap(d.id, d.data())).toList();
        emit();
      }, onError: sink.addError);

      sink.onCancel = () async {
        await s1.cancel();
        await s2.cancel();
      };
    });
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
  // Leave-conflict / first-unit-protection guard rails
  // ---------------------------------------------------------------------------

  /// True if [teacherId] has an approved leave overlapping any future (or
  /// today's) occurrence of [day] within the next [horizonDays] — i.e.
  /// assigning them to this weekly slot would immediately get auto-vacated
  /// for at least one upcoming date. Used to warn before a *permanent*
  /// weekly assignment is made into a teacher who's currently on leave.
  Future<List<DateTime>> _upcomingLeaveDatesForDay({
    required String teacherId,
    required String day,
    int horizonDays = 60,
  }) async {
    if (teacherId.isEmpty) return const [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final horizon = today.add(Duration(days: horizonDays));

    final snap = await _firestore
        .collection('leave_requests')
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    final hits = <DateTime>[];
    for (final doc in snap.docs) {
      final data = doc.data();
      final start = (data['startDate'] as Timestamp?)?.toDate();
      final end = (data['endDate'] as Timestamp?)?.toDate();
      if (start == null || end == null) continue;

      var cursor = DateTime(start.year, start.month, start.day);
      final last = DateTime(end.year, end.month, end.day);
      if (last.isBefore(today)) continue; // leave already fully in the past

      while (!cursor.isAfter(last) && !cursor.isAfter(horizon)) {
        if (!cursor.isBefore(today) && dayNameForDate(cursor) == day) {
          hits.add(cursor);
        }
        cursor = cursor.add(const Duration(days: 1));
      }
    }
    hits.sort();
    return hits;
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
    bool allowLeaveOverride = false,
    bool bypassFirstUnitProtection = false,
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

    // ---------------------------------------------------------------
    // Guard rail: unit 1 reserved for the class teacher. Manual admin
    // action only — bypassFirstUnitProtection:true, with a warning.
    // ---------------------------------------------------------------
    if (destUnitNum == 1 && !bypassFirstUnitProtection) {
      final protectFirstUnit =
          await AdminConfigService().getProtectFirstUnitForClassTeacher();
      if (protectFirstUnit) {
        final cls = await getClass(classId);
        final classTeacherId = cls?.classTeacherId ?? '';
        if (classTeacherId.isNotEmpty && classTeacherId != draggedTeacherId) {
          return ClashAssignmentOutcome(
            assigned: false,
            warnings: [
              'Unit 1 is reserved for the class teacher (${cls?.classTeacherName ?? classTeacherId}).',
            ],
            firstUnitConflict: true,
          );
        }
      }
    }

    // ---------------------------------------------------------------
    // Guard rail: approved leave. Automation must NEVER push through this
    // — only a manual admin "assign anyway" (allowLeaveOverride:true) may,
    // and even then the leave's own dates stay vacated afterwards (see
    // resyncTeacherLeaveExceptions, called below once assignment commits).
    // ---------------------------------------------------------------
    if (!allowLeaveOverride) {
      final leaveDates = await _upcomingLeaveDatesForDay(
        teacherId: draggedTeacherId,
        day: destDay,
      );
      if (leaveDates.isNotEmpty) {
        final preview = leaveDates.take(3).map(dateKeyFor).join(', ');
        return ClashAssignmentOutcome(
          assigned: false,
          warnings: [
            '${draggedTeacherName.isEmpty ? draggedTeacherId : draggedTeacherName} has approved leave covering this day ($preview${leaveDates.length > 3 ? ', …' : ''}). Those dates will stay vacated for cover even if you assign them permanently.',
          ],
          leaveConflict: true,
        );
      }
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
        // Single equality filter (`classId`) + client-side teacherId
        // filter — avoids needing a manually-created composite index for
        // this exact (classId, teacherId) combo in every school's
        // Firebase project. A class's weekly slot count is always small
        // (one school day's worth of periods), so this is cheap.
        final currentCountSnap = await _weekly
            .where('classId', isEqualTo: classId)
            .get();
        final currentCount = currentCountSnap.docs
            .where((d) => d.id != destinationSlotId && d.data()['teacherId'] == draggedTeacherId)
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
          await _afterWeeklyAssignmentChanged([draggedTeacherId]);
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
            await _afterWeeklyAssignmentChanged([draggedTeacherId]);
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

    // Capture who was previously assigned BEFORE overwriting, so their
    // stale exceptions can be resynced too (see _afterWeeklyAssignmentChanged).
    final previousTeacherId = (dest['teacherId'] as String?) ?? '';

    await assignTeacher(
      slotId: destinationSlotId,
      teacherId: draggedTeacherId,
      teacherName: draggedTeacherName,
    );
    await _afterWeeklyAssignmentChanged([draggedTeacherId, previousTeacherId]);

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

    String teacher1 = '';
    String teacher2 = '';

    await _firestore.runTransaction((tx) async {
      final s1 = await tx.get(ref1);
      final s2 = await tx.get(ref2);
      if (!s1.exists || !s2.exists) {
        throw Exception('One of the slots no longer exists.');
      }
      final d1 = s1.data()!;
      final d2 = s2.data()!;
      teacher1 = (d1['teacherId'] as String?) ?? '';
      teacher2 = (d2['teacherId'] as String?) ?? '';

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

    // Both teachers' day/unit ownership just changed permanently — make
    // sure any leave-driven exceptions tied to their OLD slots are
    // re-validated against their new weekly reality.
    await _afterWeeklyAssignmentChanged([teacher1, teacher2]);
  }

  /// Same-day, single-date swap between two slots' EFFECTIVE assignment for
  /// [date] only — the permanent weekly template is never touched. This
  /// REPLACES the old `exchangeDailySlots`, which used to write into the
  /// `daily_timetables` collection; it now writes two 'exchange'
  /// [TimetableExceptionModel] docs instead. Tomorrow, the weekly pattern
  /// (and therefore tomorrow's effective schedule) is unaffected.
  ///
  /// Neither slot may be locked by an approved-leave exception for [date] —
  /// a teacher's own same-day exchange must never be able to override a
  /// leave (only a manual admin override elsewhere can).
  Future<void> exchangeForDate({
    required String weeklySlotId1,
    required String weeklySlotId2,
    required DateTime date,
  }) async {
    if (weeklySlotId1 == weeklySlotId2) return;
    final dateKey = dateKeyFor(date);
    final ref1 = _weekly.doc(weeklySlotId1);
    final ref2 = _weekly.doc(weeklySlotId2);
    final excRef1 = _exceptions.doc(exceptionId(weeklySlotId1, dateKey));
    final excRef2 = _exceptions.doc(exceptionId(weeklySlotId2, dateKey));

    Map<String, dynamic>? notifyD1;
    Map<String, dynamic>? notifyD2;
    String notifyTeacher1 = '';
    String notifyTeacher2 = '';

    await _firestore.runTransaction((tx) async {
      final s1 = await tx.get(ref1);
      final s2 = await tx.get(ref2);
      if (!s1.exists || !s2.exists) {
        throw Exception('One of the slots no longer exists.');
      }
      final exc1 = await tx.get(excRef1);
      final exc2 = await tx.get(excRef2);

      if ((exc1.exists && exc1.data()?['type'] == 'leave') ||
          (exc2.exists && exc2.data()?['type'] == 'leave')) {
        throw Exception(
            'One of these slots is vacated by approved leave on this date and cannot be exchanged.');
      }

      final d1 = s1.data()!;
      final d2 = s2.data()!;

      // Effective (weekly, unless an existing non-leave exception already
      // overrides it for this date) teacher for each side.
      final eff1TeacherId = exc1.exists ? (exc1.data()?['teacherId'] as String? ?? '') : (d1['teacherId'] as String? ?? '');
      final eff1TeacherName = exc1.exists ? (exc1.data()?['teacherName'] as String? ?? '') : (d1['teacherName'] as String? ?? '');
      final eff2TeacherId = exc2.exists ? (exc2.data()?['teacherId'] as String? ?? '') : (d2['teacherId'] as String? ?? '');
      final eff2TeacherName = exc2.exists ? (exc2.data()?['teacherName'] as String? ?? '') : (d2['teacherName'] as String? ?? '');

      tx.set(excRef1, {
        'slotId': weeklySlotId1,
        'classId': d1['classId'] ?? '',
        'className': d1['className'] ?? '',
        'day': d1['day'] ?? '',
        'unit': d1['unit'] ?? 0,
        'startTime': d1['startTime'] ?? '',
        'endTime': d1['endTime'] ?? '',
        'date': dateKey,
        'type': 'exchange',
        'teacherId': eff2TeacherId,
        'teacherName': eff2TeacherName,
        'originalTeacherId': d1['teacherId'] ?? '',
        'originalTeacherName': d1['teacherName'] ?? '',
        'sourceId': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.set(excRef2, {
        'slotId': weeklySlotId2,
        'classId': d2['classId'] ?? '',
        'className': d2['className'] ?? '',
        'day': d2['day'] ?? '',
        'unit': d2['unit'] ?? 0,
        'startTime': d2['startTime'] ?? '',
        'endTime': d2['endTime'] ?? '',
        'date': dateKey,
        'type': 'exchange',
        'teacherId': eff1TeacherId,
        'teacherName': eff1TeacherName,
        'originalTeacherId': d2['teacherId'] ?? '',
        'originalTeacherName': d2['teacherName'] ?? '',
        'sourceId': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      notifyD1 = d1;
      notifyD2 = d2;
      notifyTeacher1 = eff2TeacherId;
      notifyTeacher2 = eff1TeacherId;
    });

    if (notifyTeacher1.isNotEmpty && notifyD1 != null) {
      await NotificationService().notifyTimetableChange(
        teacherId: notifyTeacher1,
        className: notifyD1!['className']?.toString() ?? '',
        day: notifyD1!['day']?.toString() ?? '',
        unit: (notifyD1!['unit'] as num?)?.toInt() ?? 0,
        isPermanent: false,
      );
    }
    if (notifyTeacher2.isNotEmpty && notifyD2 != null) {
      await NotificationService().notifyTimetableChange(
        teacherId: notifyTeacher2,
        className: notifyD2!['className']?.toString() ?? '',
        day: notifyD2!['day']?.toString() ?? '',
        unit: (notifyD2!['unit'] as num?)?.toInt() ?? 0,
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

    // Teachers who held a slot in this class BEFORE regeneration — needed
    // afterwards to clean up any now-stale leave/exception data tied to a
    // slot that no longer belongs to them (regeneration changing WHO
    // teaches a slot must never leave behind a leave exception that still
    // refers to the old, now-irrelevant teacher).
    final previousTeacherIds = slots.map((s) => s.teacherId).toSet();

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

    // Generation is intentionally neutral and randomized (see
    // TimetableGenerator) — every run reshuffles tie-break order with a
    // fresh Random() seed, and load is spread by penalizing repeats/streaks
    // rather than ever hard-pinning "whoever's first in the list". Leave is
    // deliberately NOT fed into the generator as a hard exclusion: the
    // weekly pattern is a recurring template, leave is date-bound, so the
    // correct behaviour is "generate the normal recurring pattern, then let
    // the per-date exception layer vacate just the specific leave dates" —
    // never the other way around. This is also why automation can never
    // "override" a leave: it doesn't even touch the exception layer where
    // leave lives.
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

    // Resync exceptions for every teacher touched by this regeneration —
    // both newly-assigned teachers (so any of THEIR active leave dates get
    // (re)vacated for their new slots) and previously-assigned teachers
    // who may have lost a slot (so stale leave exceptions tied to a slot
    // they no longer teach get cleaned up instead of lingering as ghost
    // data). See "what if a teacher requests leave after fixture
    // assignment / what if generation runs after leave already exists".
    final affectedTeacherIds = <String>{
      ...result.slotIdToTeacherId.values,
      ...previousTeacherIds,
    }..removeWhere((id) => id.isEmpty);
    await _afterWeeklyAssignmentChanged(affectedTeacherIds.toList());

    // Real notification: tell each affected teacher their timetable for
    // this class changed, instead of changing it silently behind the scenes.
    for (final teacherId in result.slotIdToTeacherId.values.toSet()) {
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
  // Leave-driven exception sync (REPLACES the old "daily clearing")
  // ---------------------------------------------------------------------------

  /// Called any time a teacher's WEEKLY assignment(s) may have changed
  /// (manual assign, exchange, regeneration, or right after a leave is
  /// approved) — re-derives every leave exception that should exist for
  /// [teacherIds] from scratch:
  ///  - For every teacher with an active/future approved leave, ensures a
  ///    'leave' exception exists for each (slot, date) where the CURRENT
  ///    weekly pattern says they teach. This is what makes "if I'm on
  ///    leave, my units empty out even on a class/slot that's brand new or
  ///    was just edited" actually true — it's re-derived from the weekly
  ///    pattern every time it changes, not written once and forgotten.
  ///  - Removes any existing 'leave' exception that no longer corresponds
  ///    to reality (the slot was reassigned away from the on-leave teacher,
  ///    or the leave no longer covers that date) instead of leaving it
  ///    behind as ghost data.
  /// Never touches 'exchange' or 'admin_override' exceptions belonging to
  /// other teachers — those are independent, one-off records.
  Future<void> _afterWeeklyAssignmentChanged(List<String> teacherIds) async {
    for (final teacherId in teacherIds.toSet()) {
      if (teacherId.isEmpty) continue;
      try {
        await resyncTeacherLeaveExceptions(teacherId);
      } catch (_) {
        // Best-effort: a sync hiccup for one teacher must never block the
        // assignment/generation that triggered it. An admin can always
        // re-run "Resync leave" from the leave management screen.
      }
    }
  }

  /// Re-derives every 'leave' exception for [teacherId] against their
  /// CURRENT approved leave window(s) and CURRENT weekly assignments.
  /// Safe to call repeatedly (idempotent — deterministic doc IDs).
  Future<List<Map<String, dynamic>>> resyncTeacherLeaveExceptions(
    String teacherId, {
    int horizonDays = 60,
  }) async {
    if (teacherId.isEmpty) return const [];
    final vacated = <Map<String, dynamic>>[];

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final horizon = today.add(Duration(days: horizonDays));

    final leavesSnap = await _firestore
        .collection('leave_requests')
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    // Every date (within the horizon) this teacher is on approved leave.
    final leaveDateKeys = <String>{};
    for (final doc in leavesSnap.docs) {
      final data = doc.data();
      final start = (data['startDate'] as Timestamp?)?.toDate();
      final end = (data['endDate'] as Timestamp?)?.toDate();
      if (start == null || end == null) continue;
      var cursor = DateTime(start.year, start.month, start.day);
      final last = DateTime(end.year, end.month, end.day);
      final clampedLast = last.isAfter(horizon) ? horizon : last;
      while (!cursor.isAfter(clampedLast)) {
        leaveDateKeys.add(dateKeyFor(cursor));
        cursor = cursor.add(const Duration(days: 1));
      }
    }

    // This teacher's current weekly assignments.
    final weeklySnap = await _weekly.where('teacherId', isEqualTo: teacherId).get();

    // Existing leave exceptions ANYWHERE for this teacher (as the original
    // owner of the slot) within the horizon — used to find stale ones to
    // remove (slot reassigned away, or leave no longer covers that date).
    final existingSnap = await _exceptions
        .where('originalTeacherId', isEqualTo: teacherId)
        .where('type', isEqualTo: 'leave')
        .get();

    final stillValidIds = <String>{};

    for (final slotDoc in weeklySnap.docs) {
      final slot = TimetableSlotModel.fromMap(slotDoc.id, slotDoc.data());
      for (final dateKey in leaveDateKeys) {
        // Only create/refresh for dates that actually fall on this slot's
        // weekday within the horizon.
        final parts = dateKey.split('-');
        final d = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        if (dayNameForDate(d) != slot.day) continue;

        final id = exceptionId(slot.id, dateKey);
        stillValidIds.add(id);

        await _exceptions.doc(id).set({
          'slotId': slot.id,
          'classId': slot.classId,
          'className': slot.className,
          'day': slot.day,
          'unit': slot.unit,
          'startTime': slot.startTime,
          'endTime': slot.endTime,
          'date': dateKey,
          'type': 'leave',
          'teacherId': '',
          'teacherName': '',
          'originalTeacherId': teacherId,
          'originalTeacherName': slot.teacherName,
          'sourceId': '',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        vacated.add({
          'classId': slot.classId,
          'className': slot.className,
          'day': slot.day,
          'unit': slot.unit,
          'startTime': slot.startTime,
          'endTime': slot.endTime,
          'date': dateKey,
          'absentTeacherId': teacherId,
          'sourceDailySlotId': slot.id,
        });
      }
    }

    // Remove stale leave exceptions: still flagged 'leave' for this teacher
    // but no longer valid (slot reassigned, or date dropped off the leave).
    final batch = _firestore.batch();
    var deletions = 0;
    for (final doc in existingSnap.docs) {
      if (stillValidIds.contains(doc.id)) continue;
      // Never delete one that's already been picked up by a fixture cover
      // — that's a real, intentional state (someone is now covering this
      // vacancy), not ghost data. Leave it as 'fixture_assigned' history;
      // FixtureService manages its own lifecycle for those.
      if (doc.data()['type'] != 'leave') continue;
      batch.delete(doc.reference);
      deletions++;
      if (deletions >= 400) break; // stay under one batch's limit per pass
    }
    if (deletions > 0) await batch.commit();

    return vacated;
  }

  // ---------------------------------------------------------------------------
  // Effective (merged) schedule helpers
  // ---------------------------------------------------------------------------

  /// One-shot read of the merged weekly+exception schedule for [classId] on
  /// [date]. Prefer the stream-based merge in the UI layer for live
  /// updates; this is for one-off reads (e.g. building a printable view).
  Future<List<EffectiveSlot>> getEffectiveSlotsForDate({
    required String classId,
    required DateTime date,
  }) async {
    final dateKey = dateKeyFor(date);
    final weeklySnap = await _weekly.where('classId', isEqualTo: classId).get();
    final excSnap = await _exceptions
        .where('classId', isEqualTo: classId)
        .where('date', isEqualTo: dateKey)
        .get();

    final excBySlotId = <String, TimetableExceptionModel>{};
    for (final d in excSnap.docs) {
      final e = TimetableExceptionModel.fromMap(d.id, d.data());
      excBySlotId[e.slotId] = e;
    }

    return weeklySnap.docs.map((d) {
      final slot = TimetableSlotModel.fromMap(d.id, d.data());
      return EffectiveSlot(weekly: slot, exception: excBySlotId[slot.id]);
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Fixture-cover <-> exception bridge (used by FixtureService)
  // ---------------------------------------------------------------------------

  /// Marks the exception for (slotId, date) as now covered by [teacherId]
  /// (a fixture claim/assignment). Merges onto whatever exception already
  /// exists for that slot+date (normally a 'leave' exception created by
  /// [resyncTeacherLeaveExceptions]) so originalTeacherId/class/day/unit
  /// metadata is preserved.
  Future<void> markSlotCoveredForDate({
    required String slotId,
    required String date,
    required String teacherId,
    required String teacherName,
    required String sourceFixtureId,
  }) async {
    await _exceptions.doc(exceptionId(slotId, date)).set({
      'slotId': slotId,
      'date': date,
      'type': 'fixture_assigned',
      'teacherId': teacherId,
      'teacherName': teacherName,
      'sourceId': sourceFixtureId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Reverts the exception for (slotId, date) back to vacant — used when a
  /// fixture covering that slot is released/expired. Stays type 'leave' so
  /// the slot is correctly shown as "vacated, needs cover" rather than
  /// disappearing back to looking like a normal staffed slot.
  Future<void> revertSlotToVacantForDate({
    required String slotId,
    required String date,
  }) async {
    await _exceptions.doc(exceptionId(slotId, date)).set({
      'slotId': slotId,
      'date': date,
      'type': 'leave',
      'teacherId': '',
      'teacherName': '',
      'sourceId': '',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// One-shot lookup of the exception (if any) for (slotId, date) — used by
  /// FixtureService to check whether a slot is currently locked by an
  /// approved-leave exception before allowing a same-day exchange/claim to
  /// touch it.
  Future<TimetableExceptionModel?> getExceptionForDate(
    String slotId,
    String date,
  ) async {
    final doc = await _exceptions.doc(exceptionId(slotId, date)).get();
    if (!doc.exists) return null;
    return TimetableExceptionModel.fromMap(doc.id, doc.data()!);
  }

  // ---------------------------------------------------------------------------
  // Presets — named snapshots of a class's weekly assignment, restorable
  // later. Lets an admin safely try a regeneration or a big manual reshuffle
  // and get back to a known-good schedule with one tap instead of having to
  // remember/redo every assignment by hand.
  // ---------------------------------------------------------------------------

  CollectionReference<Map<String, dynamic>> get _presets =>
      _firestore.collection('timetable_presets');

  /// Snapshots every weekly slot's current teacher for [classId] under
  /// [name]. Unassigned slots are saved too (as empty), so restoring a
  /// preset is a true "go back to exactly this" rather than a partial merge.
  Future<String> saveWeeklyPreset({
    required String classId,
    required String name,
    String? createdBy,
  }) async {
    final snap = await _weekly.where('classId', isEqualTo: classId).get();
    final slots = snap.docs.map((d) {
      final data = d.data();
      return {
        'day': data['day'] ?? '',
        'unit': data['unit'] ?? 0,
        'teacherId': data['teacherId'] ?? '',
        'teacherName': data['teacherName'] ?? '',
      };
    }).toList();

    final ref = await _presets.add({
      'classId': classId,
      'name': name,
      'slotCount': slots.length,
      'slots': slots,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': createdBy ?? '',
    });

    await _log('save_timetable_preset', {
      'classId': classId,
      'presetId': ref.id,
      'name': name,
      'slotCount': slots.length,
    });

    return ref.id;
  }

  /// Every saved preset for [classId], newest first.
  Stream<List<Map<String, dynamic>>> watchPresets(String classId) {
    return _presets.where('classId', isEqualTo: classId).snapshots().map((snap) {
      final list = snap.docs.map((d) => {...d.data(), 'id': d.id}).toList();
      list.sort((a, b) {
        final ta = a['createdAt'];
        final tb = b['createdAt'];
        final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da);
      });
      return list;
    });
  }

  Future<void> deletePreset(String presetId) async {
    await _presets.doc(presetId).delete();
  }

  /// Overwrites the current weekly assignment for the preset's class with
  /// whatever was saved in it, then resyncs leave exceptions for every
  /// teacher touched — both newly-restored ones (so their active leave
  /// vacates the right slots again) and whoever currently held those slots
  /// before the restore (so a stale leave exception tied to a teacher who
  /// no longer teaches that slot doesn't linger as ghost data). This is
  /// the exact same "diff old vs new assignment, resync both sides" pattern
  /// used by regeneration and exchanges, applied here too on purpose — a
  /// restore is just another way a weekly assignment can change.
  Future<void> restorePreset(String presetId) async {
    final doc = await _presets.doc(presetId).get();
    if (!doc.exists) throw Exception('Preset not found');
    final data = doc.data()!;
    final classId = (data['classId'] as String?) ?? '';
    if (classId.isEmpty) throw Exception('Preset is missing its class');

    final currentSnap = await _weekly.where('classId', isEqualTo: classId).get();
    final previousTeacherIds = currentSnap.docs
        .map((d) => (d.data()['teacherId'] as String?) ?? '')
        .toSet();

    final rawSlots = (data['slots'] as List?) ?? const [];
    const batchLimit = 400;
    for (var i = 0; i < rawSlots.length; i += batchLimit) {
      final batch = _firestore.batch();
      for (final raw in rawSlots.skip(i).take(batchLimit)) {
        final entry = raw as Map<String, dynamic>;
        final day = (entry['day'] as String?) ?? '';
        final unit = (entry['unit'] as num?)?.toInt() ?? 0;
        if (day.isEmpty || unit <= 0) continue;
        final id = slotId(classId, day, unit);
        batch.set(_weekly.doc(id), {
          'teacherId': entry['teacherId'] ?? '',
          'teacherName': entry['teacherName'] ?? '',
          'originalTeacherId': entry['teacherId'] ?? '',
          'type': 'permanent',
          'restoredAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      await batch.commit();
    }

    final restoredTeacherIds = rawSlots
        .map((e) => ((e as Map<String, dynamic>)['teacherId'] as String?) ?? '')
        .toSet();
    final affected = <String>{...previousTeacherIds, ...restoredTeacherIds}
      ..removeWhere((id) => id.isEmpty);
    await _afterWeeklyAssignmentChanged(affected.toList());

    await _log('restore_timetable_preset', {
      'classId': classId,
      'presetId': presetId,
      'slotCount': rawSlots.length,
    });
  }

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

  /// Deletes a class AND every piece of data that refers to it, in one
  /// pass — weekly slots, every per-date exception, every fixture (cover
  /// request) ever created against it, and the fixture_requests audit
  /// trail rows for those fixtures. Without this, deleting a class used to
  /// leave a trail of orphaned ("ghost") fixtures and exceptions that would
  /// still show up in the marketplace, in teachers' "today" views, and in
  /// admin reports, referencing a class that no longer exists — even when
  /// an automation (e.g. a scheduled regeneration) ran afterwards.
  Future<void> deleteClass(String classId) async {
    const batchLimit = 400;

    Future<void> deleteAllDocs(QuerySnapshot<Map<String, dynamic>> snap) async {
      final docs = snap.docs;
      for (var i = 0; i < docs.length; i += batchLimit) {
        final batch = _firestore.batch();
        for (final d in docs.skip(i).take(batchLimit)) {
          batch.delete(d.reference);
        }
        await batch.commit();
      }
    }

    // 1) Weekly slots.
    final slots = await _weekly.where('classId', isEqualTo: classId).get();
    await deleteAllDocs(slots);

    // 2) Every per-date exception for this class.
    final exceptions = await _exceptions.where('classId', isEqualTo: classId).get();
    await deleteAllDocs(exceptions);

    // 3) Every fixture (open/claimed/assigned/expired cover) for this
    // class, plus the fixture_requests audit rows that reference them.
    try {
      final fixturesSnap = await _firestore
          .collection('fixtures')
          .where('classId', isEqualTo: classId)
          .get();
      final fixtureIds = fixturesSnap.docs.map((d) => d.id).toSet();

      if (fixtureIds.isNotEmpty) {
        final requestsSnap =
            await _firestore.collection('fixture_requests').get();
        final orphanedRequests = requestsSnap.docs
            .where((d) => fixtureIds.contains(d.data()['fixtureId']))
            .toList();
        for (var i = 0; i < orphanedRequests.length; i += batchLimit) {
          final batch = _firestore.batch();
          for (final d in orphanedRequests.skip(i).take(batchLimit)) {
            batch.delete(d.reference);
          }
          await batch.commit();
        }
      }
      await deleteAllDocs(fixturesSnap);
    } catch (_) {
      // Cascade of secondary (fixture) data must never block the actual
      // class deletion the admin asked for.
    }

    // 4) The class document itself, last.
    await _classes.doc(classId).delete();

    await _log('delete_class_cascade', {
      'classId': classId,
      'weeklySlotsDeleted': slots.docs.length,
      'exceptionsDeleted': exceptions.docs.length,
    });
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
