import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/fixture_model.dart';
import 'admin_config_service.dart';
import 'notification_service.dart';

class FixtureService {
  CollectionReference<Map<String, dynamic>> get _fixtures =>
      FirebaseFirestore.instance.collection('fixtures');

  CollectionReference<Map<String, dynamic>> get _fixtureRequests =>
      FirebaseFirestore.instance.collection('fixture_requests');

  final AdminConfigService _adminConfig = AdminConfigService();

  // Create fixtures for uncovered slots (no assigned teacher)
  //
  // Each entry in uncoveredSlots may include:
  //   'date' (String 'YYYY-MM-DD') — exact calendar date this covers, if known
  //   'absentTeacherId' (String) — the teacher on leave who can't claim this
  Future<void> createFixturesForSlots({
    required List<Map<String, dynamic>> uncoveredSlots,
  }) async {
    final claimWindowHours = await _adminConfig.getFixtureClaimWindowHours();
    final batch = FirebaseFirestore.instance.batch();
    for (final slot in uncoveredSlots) {
      final fixtureDoc = _fixtures.doc();

      // Calculate expiry time: configurable window before the unit starts
      // (defaults to 1 hour; admins can tighten/loosen this in Settings).
      final startTime = slot['startTime'] as String?;
      final explicitDate = slot['date'] as String?;
      final expiresAt = (explicitDate != null && explicitDate.isNotEmpty)
          ? _calculateExpireTimeForDate(startTime, explicitDate, claimWindowHours)
          : _calculateExpireTime(startTime, slot['day'], claimWindowHours);

      batch.set(fixtureDoc, {
        'classId': slot['classId'],
        'className': slot['className'],
        'day': slot['day'],
        'unit': slot['unit'],
        'startTime': startTime,
        'endTime': slot['endTime'],
        'claimedBy': null,
        'claimedByName': null,
        'assignedTeacherId': null,
        'assignedTeacherName': null,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': expiresAt,
        'isExpired': false,
        'status': 'available',
        'date': explicitDate ?? '',
        'absentTeacherId': slot['absentTeacherId'],
        'sourceDailySlotId': slot['sourceDailySlotId'],
      });
    }

    await batch.commit();
  }

  // Teachers can claim available fixtures
  /// True only when [teacherId] is completely free at [fixture]'s day/time —
  /// no weekly class, no daily override, no other claimed fixture, and not
  /// on approved leave. The marketplace UI uses this to disable/hide the
  /// "Claim" button up front instead of only finding out via a thrown
  /// exception after tapping it.
  Future<bool> isTeacherFreeForFixture(FixtureModel fixture, String teacherId) async {
    if (fixture.date.isNotEmpty) {
      final onLeave = await _isTeacherOnApprovedLeave(teacherId, fixture.date);
      if (onLeave) return false;
    }

    final weeklyBusySnap = await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: teacherId)
        .where('day', isEqualTo: fixture.day)
        .get();
    for (final d in weeklyBusySnap.docs) {
      final data = d.data();
      if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
        return false;
      }
    }

    if (fixture.date.isNotEmpty) {
      final dailyBusySnap = await FirebaseFirestore.instance
          .collection('daily_timetables')
          .where('teacherId', isEqualTo: teacherId)
          .where('date', isEqualTo: fixture.date)
          .get();
      for (final d in dailyBusySnap.docs) {
        final data = d.data();
        if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
          return false;
        }
      }
    }

    final otherClaimedSnap = await _fixtures
        .where('claimedBy', isEqualTo: teacherId)
        .where('day', isEqualTo: fixture.day)
        .get();
    for (final d in otherClaimedSnap.docs) {
      if (d.id == fixture.id) continue;
      final data = d.data();
      if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
        return false;
      }
    }

    return true;
  }

  Future<void> claimFixture({
    required String fixtureId,
    required String teacherId,
    required String teacherName,
  }) async {
    final fixtureDoc = await _fixtures.doc(fixtureId).get();

    if (!fixtureDoc.exists) {
      throw Exception('Fixture not found');
    }

    final fixture = fixtureDoc.data()!;

    if (fixture['status'] != 'available') {
      throw Exception('Fixture is no longer available');
    }

    final expiresAt = (fixture['expiresAt'] as Timestamp).toDate();
    if (DateTime.now().isAfter(expiresAt)) {
      throw Exception('Fixture claim window has expired');
    }

    // Unified cutoff: same-day fixture claims are blocked after the
    // school's single configured cutoff time, exactly like leave requests
    // and exchanges.
    final fixtureDate = fixture['date'] as String?;
    if (fixtureDate != null && fixtureDate.isNotEmpty) {
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      if (fixtureDate == todayKey && await _adminConfig.isPastUnifiedCutoffNow()) {
        throw Exception('Same-day fixture claims are blocked after cutoff time');
      }
    }

    // A teacher on approved leave that day can't claim a fixture for it —
    // they're not supposed to be working at all.
    if (fixtureDate != null && fixtureDate.isNotEmpty) {
      final onLeave = await _isTeacherOnApprovedLeave(teacherId, fixtureDate);
      if (onLeave) {
        throw Exception('You are on approved leave on this date.');
      }
    }

    // Only FREE teachers can claim cover — block if this teacher already
    // has a class (or another fixture) at the exact same day/time. Checks
    // both the recurring weekly pattern and that specific date's daily
    // overrides, so an already-claimed fixture for the same slot also
    // counts as "busy".
    final fixtureDay = fixture['day']?.toString() ?? '';
    final fixtureStart = fixture['startTime']?.toString() ?? '';
    final fixtureEnd = fixture['endTime']?.toString() ?? '';
    if (fixtureDay.isNotEmpty && fixtureStart.isNotEmpty && fixtureEnd.isNotEmpty) {
      final weeklyBusySnap = await FirebaseFirestore.instance
          .collection('weekly_timetables')
          .where('teacherId', isEqualTo: teacherId)
          .where('day', isEqualTo: fixtureDay)
          .get();
      for (final d in weeklyBusySnap.docs) {
        final data = d.data();
        if (_overlaps(fixtureStart, fixtureEnd, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
          throw Exception('You already have a class at this time — only free teachers can claim cover.');
        }
      }

      if (fixtureDate != null && fixtureDate.isNotEmpty) {
        final dailyBusySnap = await FirebaseFirestore.instance
            .collection('daily_timetables')
            .where('teacherId', isEqualTo: teacherId)
            .where('date', isEqualTo: fixtureDate)
            .get();
        for (final d in dailyBusySnap.docs) {
          final data = d.data();
          if (_overlaps(fixtureStart, fixtureEnd, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
            throw Exception('You already have a class at this time — only free teachers can claim cover.');
          }
        }
      }

      final otherClaimedSnap = await _fixtures
          .where('claimedBy', isEqualTo: teacherId)
          .where('day', isEqualTo: fixtureDay)
          .get();
      for (final d in otherClaimedSnap.docs) {
        if (d.id == fixtureId) continue;
        final data = d.data();
        if (_overlaps(fixtureStart, fixtureEnd, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
          throw Exception('You\'re already covering another fixture at this time.');
        }
      }
    }

    // Check if teacher can take this fixture (unit limits) — actively
    // blocked, not just warned, so a teacher can never be pushed past the
    // school's configured quota by claiming.
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(teacherId)
        .get();

    if (!userDoc.exists) {
      throw Exception('Teacher not found');
    }

    final user = userDoc.data()!;
    final defaultUnits = user['defaultUnits'] as int? ?? 0;
    final fixtureUnits = user['fixtureUnits'] as int? ?? 0;
    final total = defaultUnits + fixtureUnits;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    if (total >= maxUnits) {
      throw Exception('You have reached your $maxUnits-unit weekly limit and cannot claim more cover.');
    }

    // Claim the fixture
    await _fixtures.doc(fixtureId).update({
      'claimedBy': teacherId,
      'claimedByName': teacherName,
      'status': 'claimed',
      'claimedAt': FieldValue.serverTimestamp(),
    });

    // Update teacher's fixture units
    await FirebaseFirestore.instance
        .collection('users')
        .doc(teacherId)
        .update({
      'fixtureUnits': FieldValue.increment(1),
    });

    // Daily is the sole source of truth for the live schedule — writing the
    // claim into `fixtures` alone would leave the actual daily_timetables
    // slot looking permanently vacant even after someone picks it up.
    final sourceDailySlotId = fixture['sourceDailySlotId'] as String?;
    if (sourceDailySlotId != null && sourceDailySlotId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('daily_timetables')
          .doc(sourceDailySlotId)
          .set({
        'teacherId': teacherId,
        'teacherName': teacherName,
        'type': 'fixture_assigned',
        'coveredAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    // Create a fixture request record
    await _fixtureRequests.add({
      'fixtureId': fixtureId,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'action': 'claimed',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    final className = fixture['className'] as String? ?? 'a class';
    final day = fixture['day'] as String? ?? '';
    final unit = fixture['unit'];
    await NotificationService().notifyTeacher(
      teacherId: teacherId,
      title: 'Cover confirmed',
      body: 'You\'re now covering $className (unit $unit) on $day.',
      type: NotificationType.fixtureClaimed,
      data: {'fixtureId': fixtureId},
    );
    await NotificationService().notifyAdmins(
      title: 'Fixture claimed',
      body: '$teacherName picked up $className (unit $unit, $day).',
      action: 'fixture_claimed',
      data: {'fixtureId': fixtureId},
    );
  }

  // Teacher can release a claimed fixture
  Future<void> releaseFixture({
    required String fixtureId,
    required String teacherId,
  }) async {
    final fixtureDoc = await _fixtures.doc(fixtureId).get();

    if (!fixtureDoc.exists) {
      throw Exception('Fixture not found');
    }

    final fixture = fixtureDoc.data()!;

    if (fixture['claimedBy'] != teacherId) {
      throw Exception('Only the claiming teacher can release this fixture');
    }

    // Release the fixture
    await _fixtures.doc(fixtureId).update({
      'claimedBy': null,
      'claimedByName': null,
      'status': 'available',
      'releasedAt': FieldValue.serverTimestamp(),
    });

    // Reduce teacher's fixture units
    await FirebaseFirestore.instance
        .collection('users')
        .doc(teacherId)
        .update({
      'fixtureUnits': FieldValue.increment(-1),
    });

    // Revert the daily slot back to vacant so the live schedule stays
    // accurate — it's open for someone else to cover again.
    final sourceDailySlotId = fixture['sourceDailySlotId'] as String?;
    if (sourceDailySlotId != null && sourceDailySlotId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('daily_timetables')
          .doc(sourceDailySlotId)
          .set({
        'teacherId': '',
        'teacherName': '',
        'type': 'on_leave',
        'releasedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    // Update fixture request record
    await _fixtureRequests
        .where('fixtureId', isEqualTo: fixtureId)
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'active')
        .limit(1)
        .get()
        .then((snapshot) {
      if (snapshot.docs.isNotEmpty) {
        snapshot.docs.first.reference.update({
          'status': 'released',
          'releasedAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  // Admin can assign fixtures 1 hour before or when expired
  Future<void> assignFixture({
    required String fixtureId,
    required String teacherId,
    required String teacherName,
  }) async {
    final fixtureDoc = await _fixtures.doc(fixtureId).get();

    if (!fixtureDoc.exists) {
      throw Exception('Fixture not found');
    }

    final fixture = fixtureDoc.data()!;
    final expiresAt = (fixture['expiresAt'] as Timestamp).toDate();

    // Can only assign after expiry or 1 hour before
    if (DateTime.now().isBefore(expiresAt)) {
      throw Exception('Can only assign fixtures 1 hour before they start');
    }

    // If already claimed by someone else, release them first
    if (fixture['claimedBy'] != null && fixture['claimedBy'] != teacherId) {
      final claimedBy = fixture['claimedBy'];
      await FirebaseFirestore.instance
          .collection('users')
          .doc(claimedBy)
          .update({
        'fixtureUnits': FieldValue.increment(-1),
      });
    }

    // Check unit limits for new teacher
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(teacherId)
        .get();

    if (!userDoc.exists) {
      throw Exception('Teacher not found');
    }

    final user = userDoc.data()!;
    final defaultUnits = user['defaultUnits'] as int? ?? 0;
    final fixtureUnits = user['fixtureUnits'] as int? ?? 0;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    // Don't count current teacher if they already claimed it
    int currentTeacherFixtures = fixtureUnits;
    if (fixture['claimedBy'] != teacherId) {
      currentTeacherFixtures = fixtureUnits + 1;
    }

    if (defaultUnits + currentTeacherFixtures > maxUnits) {
      throw Exception(
        'Assigning this fixture would exceed the teacher\'s $maxUnits-unit limit',
      );
    }

    // Assign the fixture
    await _fixtures.doc(fixtureId).update({
      'assignedTeacherId': teacherId,
      'assignedTeacherName': teacherName,
      'status': 'assigned',
      'assignedAt': FieldValue.serverTimestamp(),
    });

    // If not already counted in fixtures, increment
    if (fixture['claimedBy'] != teacherId) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(teacherId)
          .update({
        'fixtureUnits': FieldValue.increment(1),
      });
    }

    // Update fixture request record
    await _fixtureRequests.add({
      'fixtureId': fixtureId,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'action': 'assigned_by_admin',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // Daily is the sole source of truth for the live schedule.
    final sourceDailySlotId = fixture['sourceDailySlotId'] as String?;
    if (sourceDailySlotId != null && sourceDailySlotId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('daily_timetables')
          .doc(sourceDailySlotId)
          .set({
        'teacherId': teacherId,
        'teacherName': teacherName,
        'type': 'fixture_assigned',
        'coveredAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    final className = fixture['className'] as String? ?? 'a class';
    final day = fixture['day'] as String? ?? '';
    final unit = fixture['unit'];
    await NotificationService().notifyTeacher(
      teacherId: teacherId,
      title: 'Cover assigned',
      body: 'An admin assigned you to cover $className (unit $unit) on $day.',
      type: NotificationType.fixtureAssigned,
      data: {'fixtureId': fixtureId},
    );
  }

  // Mark fixtures as expired if past expiry time
  Future<void> expireFixtures() async {
    final now = DateTime.now();

    final expiredSnapshot = await _fixtures
        .where('expiresAt', isLessThan: now)
        .where('isExpired', isEqualTo: false)
        .where('status', isNotEqualTo: 'assigned')
        .get();

    if (expiredSnapshot.docs.isEmpty) return;

    final batch = FirebaseFirestore.instance.batch();

    for (final doc in expiredSnapshot.docs) {
      batch.update(doc.reference, {
        'isExpired': true,
        'status': 'expired',
        'expiredAt': FieldValue.serverTimestamp(),
      });

      // If someone had claimed it, release them.
      // IMPORTANT: don't await inside the loop (can exceed UI/framework timeouts).
      final claimedBy = doc.data()['claimedBy'];
      if (claimedBy != null) {
        batch.update(
          FirebaseFirestore.instance.collection('users').doc(claimedBy),
          {
            'fixtureUnits': FieldValue.increment(-1),
          },
        );
      }
    }

    await batch.commit();
  }

  // Stream of available fixtures for a teacher to claim
  Stream<List<FixtureModel>> watchAvailableFixtures() {
    return _fixtures
        .where('status', isEqualTo: 'available')
        .where('isExpired', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => FixtureModel.fromMap(doc.id, doc.data()))
              .toList();
        });
  }

  /// Same as [watchAvailableFixtures] but hides any fixture whose date
  /// falls within [teacherId]'s own approved leave — they're not supposed
  /// to be working that day, so they shouldn't be able to pick up cover.
  Stream<List<FixtureModel>> watchAvailableFixturesForTeacher(String teacherId) {
    return watchAvailableFixtures().asyncMap((fixtures) async {
      if (fixtures.isEmpty) return fixtures;

      final leaveSnap = await FirebaseFirestore.instance
          .collection('leave_requests')
          .where('teacherId', isEqualTo: teacherId)
          .where('status', isEqualTo: 'approved')
          .get();

      if (leaveSnap.docs.isEmpty) return fixtures;

      final leaveRanges = leaveSnap.docs.map((d) {
        final data = d.data();
        final start = (data['startDate'] as Timestamp?)?.toDate();
        final end = (data['endDate'] as Timestamp?)?.toDate() ?? start;
        return (start, end);
      }).where((r) => r.$1 != null).toList();

      return fixtures.where((f) {
        if (f.date.isEmpty) return true; // legacy pattern-only fixture, can't check
        final parts = f.date.split('-');
        if (parts.length != 3) return true;
        final fixtureDate = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        for (final range in leaveRanges) {
          final start = DateTime(range.$1!.year, range.$1!.month, range.$1!.day);
          final end = DateTime(range.$2!.year, range.$2!.month, range.$2!.day);
          if (!fixtureDate.isBefore(start) && !fixtureDate.isAfter(end)) {
            return false; // falls within this teacher's own leave window
          }
        }
        return true;
      }).toList();
    });
  }

  /// Every 'YYYY-MM-DD' date this teacher is on approved leave for. Used by
  /// the marketplace UI to hide fixtures landing on the teacher's own leave.
  Future<Set<String>> getApprovedLeaveDatesForTeacher(String teacherId) async {
    final leaveSnap = await FirebaseFirestore.instance
        .collection('leave_requests')
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    final dates = <String>{};
    for (final doc in leaveSnap.docs) {
      final data = doc.data();
      final start = (data['startDate'] as Timestamp?)?.toDate();
      final end = (data['endDate'] as Timestamp?)?.toDate() ?? start;
      if (start == null) continue;
      var cursor = DateTime(start.year, start.month, start.day);
      final last = DateTime(end!.year, end.month, end.day);
      while (!cursor.isAfter(last)) {
        dates.add(
          '${cursor.year.toString().padLeft(4, '0')}-${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}',
        );
        cursor = cursor.add(const Duration(days: 1));
      }
    }
    return dates;
  }

  Future<bool> _isTeacherOnApprovedLeave(String teacherId, String dateKey) async {
    final parts = dateKey.split('-');
    if (parts.length != 3) return false;
    final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));

    final leaveSnap = await FirebaseFirestore.instance
        .collection('leave_requests')
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    for (final doc in leaveSnap.docs) {
      final data = doc.data();
      final start = (data['startDate'] as Timestamp?)?.toDate();
      final end = (data['endDate'] as Timestamp?)?.toDate() ?? start;
      if (start == null) continue;
      final s = DateTime(start.year, start.month, start.day);
      final e = DateTime(end!.year, end.month, end.day);
      if (!date.isBefore(s) && !date.isAfter(e)) return true;
    }
    return false;
  }

  // Stream of claimed fixtures for a teacher
  Stream<List<FixtureModel>> watchClaimedFixtures(String teacherId) {
    return _fixtures
        .where('claimedBy', isEqualTo: teacherId)
        .where('status', isNotEqualTo: 'expired')
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) => FixtureModel.fromMap(doc.id, doc.data()))
              .toList();
        });
  }

  // Stream of all fixtures for admin view
  Stream<List<FixtureModel>> watchAllFixtures() {
    return _fixtures.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => FixtureModel.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Get fixtures that need admin assignment (expired or 1 hour before)
  Future<List<FixtureModel>> getFixturesNeedingAssignment() async {
    final oneHourLater = DateTime.now().add(const Duration(hours: 1));

    final snapshot = await _fixtures
        .where('status', whereIn: ['available', 'claimed'])
        .where('isExpired', isEqualTo: false)
        .get();

    final needsAssignment = <FixtureModel>[];

    for (final doc in snapshot.docs) {
      final fixture = FixtureModel.fromMap(doc.id, doc.data());
      if (fixture.expiresAt.isBefore(oneHourLater)) {
        needsAssignment.add(fixture);
      }
    }

    return needsAssignment;
  }

  /// Escalates unclaimed fixtures once their claim window (1 hour before
  /// the unit starts, i.e. `expiresAt`) has been reached. This is a
  /// SEPARATE workflow from claiming — it never auto-assigns a teacher, it
  /// only flags the fixture as `manualAssignmentRequired` and notifies the
  /// admin so they can settle it manually from the Fixture tab.
  ///
  /// Safe to call repeatedly (e.g. from a periodic timer): already-escalated
  /// fixtures are skipped so admins aren't spammed with duplicate alerts.
  Future<int> escalateUnclaimedFixtures() async {
    final now = DateTime.now();

    final snapshot = await _fixtures
        .where('status', isEqualTo: 'available')
        .where('isExpired', isEqualTo: false)
        .where('manualAssignmentRequired', isEqualTo: false)
        .get();

    var escalated = 0;
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
      if (expiresAt == null || now.isBefore(expiresAt)) continue;

      await doc.reference.update({
        'manualAssignmentRequired': true,
        'manualAssignmentNotifiedAt': FieldValue.serverTimestamp(),
      });

      final className = data['className'] as String? ?? 'a class';
      final day = data['day'] as String? ?? '';
      final unit = data['unit'];
      await NotificationService().notifyAdmins(
        title: 'Manual assignment needed',
        body: 'Nobody claimed $className (unit $unit, $day) and the claim window has closed. Please assign a teacher manually.',
        action: 'fixture_manual_assignment_required',
        data: {'fixtureId': doc.id},
      );

      escalated++;
    }

    return escalated;
  }

  /// Stream of fixtures the admin must settle manually — unclaimed and past
  /// the 1-hour claim window. Kept separate from [watchAllFixtures] so the
  /// "Needs Manual Assignment" view doesn't get conflated with the normal
  /// claim-marketplace listing.
  Stream<List<FixtureModel>> watchFixturesNeedingManualAssignment() {
    return _fixtures
        .where('status', isEqualTo: 'available')
        .where('manualAssignmentRequired', isEqualTo: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => FixtureModel.fromMap(d.id, d.data())).toList());
  }

  static int? _minutesOf(String t) {
    final trimmed = t.trim();
    if (trimmed.isEmpty) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$').firstMatch(trimmed);
    if (m == null) return null;
    var hour = int.parse(m.group(1)!);
    final minute = int.parse(m.group(2)!);
    final ampm = m.group(3);
    if (ampm != null) {
      final isPM = ampm.toUpperCase() == 'PM';
      if (hour == 12) {
        hour = isPM ? 12 : 0;
      } else {
        hour = isPM ? hour + 12 : hour;
      }
    }
    return hour * 60 + minute;
  }

  static bool _overlaps(String aStart, String aEnd, String bStart, String bEnd) {
    final s1 = _minutesOf(aStart);
    final e1 = _minutesOf(aEnd);
    final s2 = _minutesOf(bStart);
    final e2 = _minutesOf(bEnd);
    if (s1 == null || e1 == null || s2 == null || e2 == null) return false;
    return s1 < e2 && s2 < e1;
  }

  /// Ranked list of teachers best suited to cover [fixture] — used both by
  /// the marketplace ("Recommended for you") and the admin assignment
  /// dialog ("Suggested teachers" sorted first). Excludes anyone busy at
  /// that exact day/time, on approved leave that date, or already at/over
  /// quota. Sorted by ascending current workload so cover is spread fairly.
  Future<List<Map<String, dynamic>>> getRecommendedTeachers(
    FixtureModel fixture, {
    int limit = 5,
  }) async {
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    final usersSnap = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'teacher')
        .get();

    // Busy lookup: every weekly slot on this fixture's day, grouped by teacher.
    final weeklySnap = await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .where('day', isEqualTo: fixture.day)
        .get();

    final busyTeacherIds = <String>{};
    for (final d in weeklySnap.docs) {
      final data = d.data();
      final tId = data['teacherId']?.toString() ?? '';
      if (tId.isEmpty) continue;
      final s = data['startTime']?.toString() ?? '';
      final e = data['endTime']?.toString() ?? '';
      if (_overlaps(fixture.startTime, fixture.endTime, s, e)) {
        busyTeacherIds.add(tId);
      }
    }

    final onLeaveIds = <String>{};
    if (fixture.date.isNotEmpty) {
      final leaveSnap = await FirebaseFirestore.instance
          .collection('leave_requests')
          .where('status', isEqualTo: 'approved')
          .get();
      final parts = fixture.date.split('-');
      if (parts.length == 3) {
        final fDate = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        for (final doc in leaveSnap.docs) {
          final data = doc.data();
          final start = (data['startDate'] as Timestamp?)?.toDate();
          final end = (data['endDate'] as Timestamp?)?.toDate() ?? start;
          if (start == null) continue;
          final s = DateTime(start.year, start.month, start.day);
          final e = DateTime(end!.year, end.month, end.day);
          if (!fDate.isBefore(s) && !fDate.isAfter(e)) {
            onLeaveIds.add(data['teacherId']?.toString() ?? '');
          }
        }
      }
    }

    final candidates = <Map<String, dynamic>>[];
    for (final doc in usersSnap.docs) {
      final data = doc.data();
      if (busyTeacherIds.contains(doc.id) || onLeaveIds.contains(doc.id)) continue;
      final defaultUnits = (data['defaultUnits'] as num?)?.toInt() ?? 0;
      final fixtureUnits = (data['fixtureUnits'] as num?)?.toInt() ?? 0;
      final total = defaultUnits + fixtureUnits;
      if (total >= maxUnits) continue;

      candidates.add({
        'teacherId': doc.id,
        'teacherName': data['name']?.toString() ?? data['email']?.toString() ?? 'Teacher',
        'totalUnits': total,
        'maxUnits': maxUnits,
      });
    }

    candidates.sort((a, b) => (a['totalUnits'] as int).compareTo(b['totalUnits'] as int));
    return candidates.take(limit).toList();
  }

  /// Periodic housekeeping (call roughly once a minute): any fixture still
  /// unclaimed once it's within [fixtureAutoAssignMinutes] of its actual
  /// start time gets auto-assigned to the best-ranked recommended teacher
  /// so cover is never left to the wire. Falls through gracefully (and
  /// still relies on [escalateUnclaimedFixtures]) if nobody qualifies.
  Future<int> autoAssignNearStartFixtures() async {
    final autoAssignMinutes = await _adminConfig.getFixtureAutoAssignMinutes();
    final now = DateTime.now();

    final snapshot = await _fixtures
        .where('status', isEqualTo: 'available')
        .where('isExpired', isEqualTo: false)
        .get();

    var assignedCount = 0;
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final fixture = FixtureModel.fromMap(doc.id, data);

      final startDateTime = _actualStartDateTime(fixture, now);
      if (startDateTime == null) continue;

      final minutesUntilStart = startDateTime.difference(now).inMinutes;
      // Window: due to auto-assign, but hasn't already started.
      if (minutesUntilStart > autoAssignMinutes || minutesUntilStart < 0) continue;

      final recommended = await getRecommendedTeachers(fixture, limit: 1);
      if (recommended.isEmpty) continue;

      final pick = recommended.first;
      try {
        await assignFixture(
          fixtureId: doc.id,
          teacherId: pick['teacherId'] as String,
          teacherName: pick['teacherName'] as String,
        );
        await _fixtures.doc(doc.id).set({
          'autoAssigned': true,
        }, SetOptions(merge: true));
        await NotificationService().notifyAdmins(
          title: 'Auto-assigned cover',
          body:
              '${pick['teacherName']} was automatically assigned to cover ${fixture.className} (unit ${fixture.unit}) — nobody claimed it $autoAssignMinutes minutes before start.',
          action: 'fixture_auto_assigned',
          data: {'fixtureId': doc.id},
        );
        assignedCount++;
      } catch (_) {
        // assignFixture enforces its own invariants (expiry/quota); if it
        // refuses, just leave the fixture for manual escalation.
      }
    }

    return assignedCount;
  }

  /// Best-effort real start [DateTime] for a fixture "now" or in the near
  /// future, used only by the auto-assign sweep (separate from the claim
  /// window/[expiresAt], which is intentionally earlier).
  DateTime? _actualStartDateTime(FixtureModel fixture, DateTime now) {
    final startMinutes = _minutesOf(fixture.startTime);
    if (startMinutes == null) return null;
    final hour = startMinutes ~/ 60;
    final minute = startMinutes % 60;

    if (fixture.date.isNotEmpty) {
      final parts = fixture.date.split('-');
      if (parts.length != 3) return null;
      try {
        return DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
          hour,
          minute,
        );
      } catch (_) {
        return null;
      }
    }

    // Legacy pattern-only fixture (no explicit date) — resolve against the
    // next occurrence of fixture.day from today.
    final dayNames = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    ];
    final targetDayIndex = dayNames.indexOf(fixture.day);
    if (targetDayIndex == -1) return null;
    final todayDayIndex = now.weekday - 1;
    var daysToAdd = targetDayIndex - todayDayIndex;
    if (daysToAdd < 0) daysToAdd += 7;
    final date = now.add(Duration(days: daysToAdd));
    return DateTime(date.year, date.month, date.day, hour, minute);
  }

  // Exchange fixtures between teachers
  Future<void> exchangeFixture({
    required String fixtureId,
    required String fromTeacherId,
    required String fromTeacherName,
    required String toTeacherId,
    required String toTeacherName,
  }) async {
    final fixtureDoc = await _fixtures.doc(fixtureId).get();

    if (!fixtureDoc.exists) {
      throw Exception('Fixture not found');
    }

    final fixture = fixtureDoc.data()!;

    if (fixture['claimedBy'] != fromTeacherId &&
        fixture['assignedTeacherId'] != fromTeacherId) {
      throw Exception('Only the current teacher can exchange this fixture');
    }

    // Unified cutoff applies to fixture exchanges too, exactly like leave
    // and fixture claims.
    final fixtureDate = fixture['date'] as String?;
    if (fixtureDate != null && fixtureDate.isNotEmpty) {
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      if (fixtureDate == todayKey && await _adminConfig.isPastUnifiedCutoffNow()) {
        throw Exception('Same-day fixture exchanges are blocked after cutoff time');
      }
    }

    // Check unit limits for recipient
    final recipientDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(toTeacherId)
        .get();

    if (!recipientDoc.exists) {
      throw Exception('Recipient teacher not found');
    }

    final recipient = recipientDoc.data()!;
    final defaultUnits = recipient['defaultUnits'] as int? ?? 0;
    final fixtureUnits = recipient['fixtureUnits'] as int? ?? 0;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    if (defaultUnits + fixtureUnits >= maxUnits) {
      throw Exception('Recipient has reached their $maxUnits-unit limit');
    }

    // Perform exchange
    await _fixtures.doc(fixtureId).update({
      'claimedBy': toTeacherId,
      'claimedByName': toTeacherName,
      'assignedTeacherId': null,
      'assignedTeacherName': null,
      'status': 'claimed',
      'exchangedAt': FieldValue.serverTimestamp(),
    });

    // Update both teachers' units
    await FirebaseFirestore.instance
        .collection('users')
        .doc(fromTeacherId)
        .update({
      'fixtureUnits': FieldValue.increment(-1),
    });

    await FirebaseFirestore.instance
        .collection('users')
        .doc(toTeacherId)
        .update({
      'fixtureUnits': FieldValue.increment(1),
    });

    // Log exchange
    await _fixtureRequests.add({
      'fixtureId': fixtureId,
      'fromTeacherId': fromTeacherId,
      'fromTeacherName': fromTeacherName,
      'toTeacherId': toTeacherId,
      'toTeacherName': toTeacherName,
      'action': 'exchanged',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Mark teacher as absent for a fixture
  Future<void> markTeacherAbsent({
    required String fixtureId,
    required String teacherId,
    required String reason,
  }) async {
    final fixtureDoc = await _fixtures.doc(fixtureId).get();

    if (!fixtureDoc.exists) {
      throw Exception('Fixture not found');
    }

    // Mark as absent
    await _fixtures.doc(fixtureId).update({
      'isAbsent': true,
      'absentTeacherId': teacherId,
      'absentReason': reason,
      'markedAbsentAt': FieldValue.serverTimestamp(),
    });

    // Log the absence
    await _fixtureRequests.add({
      'fixtureId': fixtureId,
      'teacherId': teacherId,
      'action': 'marked_absent',
      'reason': reason,
      'status': 'completed',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  // Helper method to calculate expiry time when we already know the exact
  // calendar date (leave-driven fixtures) — no weekday-pattern guessing needed.
  DateTime _calculateExpireTimeForDate(String? startTime, String dateKey, int claimWindowHours) {
    try {
      final dateParts = dateKey.split('-');
      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);

      if (startTime == null || startTime.isEmpty) {
        return DateTime(year, month, day, 0, 0).subtract(Duration(hours: claimWindowHours));
      }

      final timeParts = startTime.split(':');
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);

      return DateTime(year, month, day, hour, minute).subtract(Duration(hours: claimWindowHours));
    } catch (e) {
      return DateTime.now().add(const Duration(hours: 23));
    }
  }

  // Helper method to calculate expiry time (configurable window before unit starts)
  DateTime _calculateExpireTime(String? startTime, String day, int claimWindowHours) {
    if (startTime == null || startTime.isEmpty) {
      return DateTime.now().add(const Duration(hours: 23));
    }

    try {
      // Parse time like "08:30"
      final timeParts = startTime.split(':');
      final hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);

      // Get today or tomorrow based on day name
      DateTime classDateTime = DateTime.now();
      final dayNames = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ];
      final targetDayIndex = dayNames.indexOf(day);

      if (targetDayIndex != -1) {
        final todayDayIndex = classDateTime.weekday - 1;
        int daysToAdd = targetDayIndex - todayDayIndex;

        if (daysToAdd < 0) {
          daysToAdd += 7;
        } else if (daysToAdd == 0) {
          // If same day but time has passed, add 7 days
          final classTime =
              classDateTime.copyWith(hour: hour, minute: minute, second: 0);
          if (classDateTime.isAfter(classTime)) {
            daysToAdd = 7;
          }
        }

        classDateTime =
            classDateTime.add(Duration(days: daysToAdd));
      }

      // Set class time and subtract the claim window
      classDateTime =
          classDateTime.copyWith(hour: hour, minute: minute, second: 0);
      return classDateTime.subtract(Duration(hours: claimWindowHours));
    } catch (e) {
      return DateTime.now().add(const Duration(hours: 23));
    }
  }
}
