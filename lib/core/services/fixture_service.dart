import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/fixture_model.dart';
import 'admin_config_service.dart';
import 'notification_service.dart';
import 'timetable_service.dart';

class FixtureService {
  CollectionReference<Map<String, dynamic>> get _fixtures =>
      FirebaseFirestore.instance.collection('fixtures');

  CollectionReference<Map<String, dynamic>> get _fixtureRequests =>
      FirebaseFirestore.instance.collection('fixture_requests');

  final AdminConfigService _adminConfig = AdminConfigService();
  final TimetableService _timetable = TimetableService();

  /// Deterministic fixture doc id for a (weekly slot, date) pair. This is
  /// what makes [createFixturesForSlots] idempotent: if leave approval
  /// retries (flaky connection, the same leave somehow getting resynced
  /// twice), the SAME fixture document is overwritten in place instead of a
  /// second "ghost" fixture being created for the same vacancy. Legacy
  /// pattern-only fixtures (no explicit date — not produced by the current
  /// leave flow, kept only for backward compatibility) fall back to an
  /// auto-generated id since they have no natural per-occurrence key.
  String? _deterministicFixtureId(String? sourceSlotId, String? date) {
    if (sourceSlotId == null || sourceSlotId.isEmpty) return null;
    if (date == null || date.isEmpty) return null;
    return '${sourceSlotId}_$date';
  }

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
      final explicitDate = slot['date'] as String?;
      final sourceSlotId = slot['sourceDailySlotId'] as String?;
      final deterministicId = _deterministicFixtureId(sourceSlotId, explicitDate);
      final fixtureDoc =
          deterministicId != null ? _fixtures.doc(deterministicId) : _fixtures.doc();

      // Calculate expiry time: configurable window before the unit starts
      // (defaults to 1 hour; admins can tighten/loosen this in Settings).
      final startTime = slot['startTime'] as String?;
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
        // Kept under its historical field name for backward compatibility
        // with already-deployed data; this is now always the WEEKLY slot
        // id (weekly_timetables doc id), never a daily_timetables id —
        // that collection no longer exists.
        'sourceDailySlotId': sourceSlotId,
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }

  /// Called right after a teacher's OWN leave is approved: if they had
  /// themselves claimed or been admin-assigned someone else's fixture
  /// (covering a different absent teacher) on a date that now falls inside
  /// their own leave window, they obviously can't show up for that either.
  /// Releases each such fixture back to 'available' (clamped, never
  /// negative, decrement of their fixtureUnits) and reverts the underlying
  /// slot's exception back to vacant so it visibly needs cover again —
  /// instead of silently leaving a class "covered by" someone who is now
  /// also absent. Covers: "what if someone exchanges/claims a fixture and
  /// then gets their OWN leave approved?"
  Future<void> releaseFixturesForTeacherDuringLeave({
    required String teacherId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final claimedSnap = await _fixtures.where('claimedBy', isEqualTo: teacherId).get();
    final assignedSnap =
        await _fixtures.where('assignedTeacherId', isEqualTo: teacherId).get();

    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);

    final toRelease = <QueryDocumentSnapshot<Map<String, dynamic>>>{
      ...claimedSnap.docs,
      ...assignedSnap.docs,
    }.where((d) {
      final date = d.data()['date'] as String?;
      if (date == null || date.isEmpty) return false;
      final parts = date.split('-');
      if (parts.length != 3) return false;
      final fixtureDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      final status = d.data()['status'] as String?;
      if (status == 'expired' || status == 'available') return false;
      return !fixtureDate.isBefore(start) && !fixtureDate.isAfter(end);
    }).toList();

    for (final doc in toRelease) {
      try {
        await _releaseFixtureInternal(
          fixtureId: doc.id,
          teacherId: teacherId,
          reasonNote: 'auto-released: covering teacher went on approved leave',
        );
        await NotificationService().notifyAdmins(
          title: 'Cover needs reassignment',
          body:
              '${doc.data()['className'] ?? 'A class'} (unit ${doc.data()['unit']}, ${doc.data()['date']}) lost its cover — the covering teacher just went on approved leave too.',
          action: 'fixture_cover_lost_to_leave',
          data: {'fixtureId': doc.id},
        );
      } catch (_) {
        // Best-effort per fixture; one failure must not block the rest.
      }
    }
  }

  // Teachers can claim available fixtures
  /// True only when [teacherId] is completely free at [fixture]'s day/time —
  /// no weekly class, no exception-covered slot, no other claimed fixture,
  /// and not on approved leave. The marketplace UI uses this to disable/hide
  /// the "Claim" button up front instead of only finding out via a thrown
  /// exception after tapping it.
  Future<bool> isTeacherFreeForFixture(FixtureModel fixture, String teacherId) async {
    if (fixture.date.isNotEmpty) {
      final onLeave = await _isTeacherOnApprovedLeave(teacherId, fixture.date);
      if (onLeave) return false;
    }

    // Single equality filter + client-side filtering throughout this
    // method on purpose: weekly_timetables/timetable_exceptions/fixtures
    // are all small-ish per-teacher collections, and this guarantees no
    // new composite index is ever required in a freshly deployed school's
    // Firebase project.
    final weeklyBusySnap = await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: teacherId)
        .get();
    for (final d in weeklyBusySnap.docs) {
      final data = d.data();
      if (data['day']?.toString() != fixture.day) continue;
      if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
        return false;
      }
    }

    if (fixture.date.isNotEmpty) {
      final exceptionBusySnap = await FirebaseFirestore.instance
          .collection('timetable_exceptions')
          .where('date', isEqualTo: fixture.date)
          .where('teacherId', isEqualTo: teacherId)
          .get();
      for (final d in exceptionBusySnap.docs) {
        final data = d.data();
        if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
          return false;
        }
      }
    }

    final otherClaimedSnap = await _fixtures
        .where('claimedBy', isEqualTo: teacherId)
        .get();
    for (final d in otherClaimedSnap.docs) {
      if (d.id == fixture.id) continue;
      final data = d.data();
      if (data['day']?.toString() != fixture.day) continue;
      if (_overlaps(fixture.startTime, fixture.endTime, data['startTime']?.toString() ?? '', data['endTime']?.toString() ?? '')) {
        return false;
      }
    }

    return true;
  }

  /// Clamped, never-negative decrement: reads the user doc inside the
  /// transaction and floors the result at 0, instead of a bare
  /// `FieldValue.increment(-1)` that could drive `fixtureUnits` negative if
  /// a release/expiry/exchange races with another write touching the same
  /// counter (e.g. the periodic expiry sweep releasing a claim at the same
  /// moment the teacher releases it themselves). Addresses "what if weekly
  /// units become negative?".
  Future<void> _safeAdjustFixtureUnits(
    Transaction tx,
    String teacherId,
    int delta,
  ) async {
    if (teacherId.isEmpty) return;
    final ref = FirebaseFirestore.instance.collection('users').doc(teacherId);
    final snap = await tx.get(ref);
    final current = (snap.data()?['fixtureUnits'] as num?)?.toInt() ?? 0;
    final next = current + delta;
    tx.update(ref, {'fixtureUnits': next < 0 ? 0 : next});
  }

  Future<void> claimFixture({
    required String fixtureId,
    required String teacherId,
    required String teacherName,
  }) async {
    final fixtureRef = _fixtures.doc(fixtureId);

    // Pre-flight checks that need data the transaction doesn't strictly
    // need to re-verify (unified cutoff, leave, "is this teacher free"
    // cross-collection scan) are done before the transaction; the
    // transaction itself re-checks `status == 'available'` and the claim
    // window right before committing, which is what actually closes the
    // "two teachers tap Claim on the same fixture at the same instant"
    // race — only the first transaction to commit wins; the second sees
    // status already flipped and throws instead of silently double-claiming.
    final preCheckDoc = await fixtureRef.get();
    if (!preCheckDoc.exists) {
      throw Exception('Fixture not found');
    }
    final preCheck = preCheckDoc.data()!;

    final fixtureDate = preCheck['date'] as String?;
    if (fixtureDate != null && fixtureDate.isNotEmpty) {
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      if (fixtureDate == todayKey && await _adminConfig.isPastUnifiedCutoffNow()) {
        throw Exception('Same-day fixture claims are blocked after cutoff time');
      }
      final onLeave = await _isTeacherOnApprovedLeave(teacherId, fixtureDate);
      if (onLeave) {
        throw Exception('You are on approved leave on this date.');
      }
    }

    final isFree = await isTeacherFreeForFixture(
      FixtureModel.fromMap(fixtureId, preCheck),
      teacherId,
    );
    if (!isFree) {
      throw Exception('You already have a class (or another fixture) at this time — only free teachers can claim cover.');
    }

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(teacherId).get();
    if (!userDoc.exists) {
      throw Exception('Teacher not found');
    }
    final user = userDoc.data()!;
    final defaultUnits = user['defaultUnits'] as int? ?? 0;
    final fixtureUnits = user['fixtureUnits'] as int? ?? 0;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
    if (defaultUnits + fixtureUnits >= maxUnits) {
      throw Exception('You have reached your $maxUnits-unit weekly limit and cannot claim more cover.');
    }

    Map<String, dynamic>? committedFixture;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fixtureDoc = await tx.get(fixtureRef);
      if (!fixtureDoc.exists) {
        throw Exception('Fixture not found');
      }
      final fixture = fixtureDoc.data()!;
      if (fixture['status'] != 'available') {
        throw Exception('Fixture is no longer available — someone else just claimed it.');
      }
      final expiresAt = (fixture['expiresAt'] as Timestamp).toDate();
      if (DateTime.now().isAfter(expiresAt)) {
        throw Exception('Fixture claim window has expired');
      }

      tx.update(fixtureRef, {
        'claimedBy': teacherId,
        'claimedByName': teacherName,
        'status': 'claimed',
        'claimedAt': FieldValue.serverTimestamp(),
      });

      await _safeAdjustFixtureUnits(tx, teacherId, 1);
      committedFixture = fixture;
    });

    if (committedFixture == null) return;
    final fixture = committedFixture!;

    // The exception layer is the sole source of truth for the live
    // schedule — writing the claim into `fixtures` alone would leave the
    // underlying slot looking permanently vacant even after someone picks
    // it up.
    final sourceSlotId = fixture['sourceDailySlotId'] as String?;
    final date = fixture['date'] as String? ?? '';
    if (sourceSlotId != null && sourceSlotId.isNotEmpty && date.isNotEmpty) {
      await _timetable.markSlotCoveredForDate(
        slotId: sourceSlotId,
        date: date,
        teacherId: teacherId,
        teacherName: teacherName,
        sourceFixtureId: fixtureId,
      );
    }

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

  /// Shared release implementation used by both the teacher-initiated
  /// [releaseFixture] and the leave-triggered auto-release in
  /// [releaseFixturesForTeacherDuringLeave].
  Future<void> _releaseFixtureInternal({
    required String fixtureId,
    required String teacherId,
    String? reasonNote,
  }) async {
    final fixtureRef = _fixtures.doc(fixtureId);
    Map<String, dynamic>? released;

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fixtureDoc = await tx.get(fixtureRef);
      if (!fixtureDoc.exists) {
        throw Exception('Fixture not found');
      }
      final fixture = fixtureDoc.data()!;
      final currentHolder = (fixture['claimedBy'] as String?) ??
          (fixture['assignedTeacherId'] as String?) ??
          '';
      if (currentHolder != teacherId) {
        throw Exception('Only the current covering teacher can release this fixture');
      }
      if (fixture['status'] == 'available') {
        // Already released (e.g. by a concurrent call) — nothing to do.
        return;
      }

      tx.update(fixtureRef, {
        'claimedBy': null,
        'claimedByName': null,
        'assignedTeacherId': null,
        'assignedTeacherName': null,
        'status': 'available',
        'releasedAt': FieldValue.serverTimestamp(),
        if (reasonNote != null) 'releaseNote': reasonNote,
      });

      await _safeAdjustFixtureUnits(tx, teacherId, -1);
      released = fixture;
    });

    if (released == null) return;
    final fixture = released!;

    final sourceSlotId = fixture['sourceDailySlotId'] as String?;
    final date = fixture['date'] as String? ?? '';
    if (sourceSlotId != null && sourceSlotId.isNotEmpty && date.isNotEmpty) {
      await _timetable.revertSlotToVacantForDate(slotId: sourceSlotId, date: date);
    }

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

  // Teacher can release a claimed fixture
  Future<void> releaseFixture({
    required String fixtureId,
    required String teacherId,
  }) =>
      _releaseFixtureInternal(fixtureId: fixtureId, teacherId: teacherId);

  // Admin can assign fixtures 1 hour before or when expired
  Future<void> assignFixture({
    required String fixtureId,
    required String teacherId,
    required String teacherName,
  }) async {
    final fixtureRef = _fixtures.doc(fixtureId);

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(teacherId).get();
    if (!userDoc.exists) {
      throw Exception('Teacher not found');
    }
    final user = userDoc.data()!;
    final defaultUnits = user['defaultUnits'] as int? ?? 0;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    String? previousHolder;
    Map<String, dynamic>? committedFixture;

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fixtureDoc = await tx.get(fixtureRef);
      if (!fixtureDoc.exists) {
        throw Exception('Fixture not found');
      }
      final fixture = fixtureDoc.data()!;
      final expiresAt = (fixture['expiresAt'] as Timestamp).toDate();
      if (DateTime.now().isBefore(expiresAt)) {
        throw Exception('Can only assign fixtures 1 hour before they start');
      }

      final currentClaimedBy = fixture['claimedBy'] as String?;
      if (currentClaimedBy != null && currentClaimedBy != teacherId) {
        previousHolder = currentClaimedBy;
      }

      // Re-read the assignee's live fixtureUnits inside the transaction so
      // two concurrent admin assignments can't both pass a stale quota
      // check.
      final assigneeRef = FirebaseFirestore.instance.collection('users').doc(teacherId);
      final assigneeSnap = await tx.get(assigneeRef);
      final liveFixtureUnits = (assigneeSnap.data()?['fixtureUnits'] as num?)?.toInt() ?? 0;
      final alreadyCountsForThisFixture = currentClaimedBy == teacherId;
      final projectedFixtureUnits =
          alreadyCountsForThisFixture ? liveFixtureUnits : liveFixtureUnits + 1;

      if (defaultUnits + projectedFixtureUnits > maxUnits) {
        throw Exception('Assigning this fixture would exceed the teacher\'s $maxUnits-unit limit');
      }

      if (previousHolder != null) {
        await _safeAdjustFixtureUnits(tx, previousHolder!, -1);
      }
      if (!alreadyCountsForThisFixture) {
        await _safeAdjustFixtureUnits(tx, teacherId, 1);
      }

      tx.update(fixtureRef, {
        'assignedTeacherId': teacherId,
        'assignedTeacherName': teacherName,
        'status': 'assigned',
        'assignedAt': FieldValue.serverTimestamp(),
      });

      committedFixture = fixture;
    });

    if (committedFixture == null) return;
    final fixture = committedFixture!;

    await _fixtureRequests.add({
      'fixtureId': fixtureId,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'action': 'assigned_by_admin',
      'status': 'active',
      'createdAt': FieldValue.serverTimestamp(),
    });

    final sourceSlotId = fixture['sourceDailySlotId'] as String?;
    final date = fixture['date'] as String? ?? '';
    if (sourceSlotId != null && sourceSlotId.isNotEmpty && date.isNotEmpty) {
      await _timetable.markSlotCoveredForDate(
        slotId: sourceSlotId,
        date: date,
        teacherId: teacherId,
        teacherName: teacherName,
        sourceFixtureId: fixtureId,
      );
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
  //
  // IMPORTANT: this deliberately filters by a SINGLE equality field
  // (`isExpired`) at the database level and does the rest (the time
  // comparison + status check) client-side. Firestore flatly rejects any
  // query with inequality filters (<, <=, >, >=, !=) on more than one
  // field — combining `expiresAt < now` with `status != 'assigned'` used
  // to throw "Invalid query" every single time this ran. Filtering by one
  // equality field also means this never needs a manually-created
  // composite index in a new school's Firebase project.
  Future<void> expireFixtures() async {
    final now = DateTime.now();

    final snapshot = await _fixtures.where('isExpired', isEqualTo: false).get();
    final toExpire = snapshot.docs.where((doc) {
      final data = doc.data();
      final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
      final status = data['status']?.toString();
      return expiresAt != null && expiresAt.isBefore(now) && status != 'assigned';
    }).toList();

    if (toExpire.isEmpty) return;

    final batch = FirebaseFirestore.instance.batch();

    for (final doc in toExpire) {
      batch.update(doc.reference, {
        'isExpired': true,
        'status': 'expired',
        'expiredAt': FieldValue.serverTimestamp(),
      });

      // If someone had claimed it, release their unit count (clamped via a
      // read-then-write would be ideal, but this sweep already runs in a
      // single batch across many docs — falling back to increment here is
      // acceptable since expiry is a one-way transition guarded by
      // `isExpired == false`, so the same doc can't be expired twice).
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
    final fixtureRef = _fixtures.doc(fixtureId);

    final preCheckDoc = await fixtureRef.get();
    if (!preCheckDoc.exists) throw Exception('Fixture not found');
    final preCheck = preCheckDoc.data()!;

    final fixtureDate = preCheck['date'] as String?;
    if (fixtureDate != null && fixtureDate.isNotEmpty) {
      final now = DateTime.now();
      final todayKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      if (fixtureDate == todayKey && await _adminConfig.isPastUnifiedCutoffNow()) {
        throw Exception('Same-day fixture exchanges are blocked after cutoff time');
      }
      // The recipient must not themselves be on approved leave that date —
      // otherwise the exchange would just create a brand-new uncovered gap.
      final recipientOnLeave = await _isTeacherOnApprovedLeave(toTeacherId, fixtureDate);
      if (recipientOnLeave) {
        throw Exception('${toTeacherName.isEmpty ? "That teacher" : toTeacherName} is on approved leave on this date.');
      }
    }

    final recipientDoc = await FirebaseFirestore.instance.collection('users').doc(toTeacherId).get();
    if (!recipientDoc.exists) {
      throw Exception('Recipient teacher not found');
    }
    final recipient = recipientDoc.data()!;
    final defaultUnits = recipient['defaultUnits'] as int? ?? 0;
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();

    Map<String, dynamic>? committedFixture;
    await FirebaseFirestore.instance.runTransaction((tx) async {
      final fixtureDoc = await tx.get(fixtureRef);
      if (!fixtureDoc.exists) throw Exception('Fixture not found');
      final fixture = fixtureDoc.data()!;

      final currentHolder = (fixture['claimedBy'] as String?) ??
          (fixture['assignedTeacherId'] as String?) ??
          '';
      if (currentHolder != fromTeacherId) {
        throw Exception('Only the current teacher can exchange this fixture');
      }

      final recipientRef = FirebaseFirestore.instance.collection('users').doc(toTeacherId);
      final recipientSnap = await tx.get(recipientRef);
      final liveFixtureUnits = (recipientSnap.data()?['fixtureUnits'] as num?)?.toInt() ?? 0;
      if (defaultUnits + liveFixtureUnits >= maxUnits) {
        throw Exception('Recipient has reached their $maxUnits-unit limit');
      }

      tx.update(fixtureRef, {
        'claimedBy': toTeacherId,
        'claimedByName': toTeacherName,
        'assignedTeacherId': null,
        'assignedTeacherName': null,
        'status': 'claimed',
        'exchangedAt': FieldValue.serverTimestamp(),
      });

      await _safeAdjustFixtureUnits(tx, fromTeacherId, -1);
      await _safeAdjustFixtureUnits(tx, toTeacherId, 1);

      committedFixture = fixture;
    });

    if (committedFixture == null) return;
    final fixture = committedFixture!;

    final sourceSlotId = fixture['sourceDailySlotId'] as String?;
    final date = fixture['date'] as String? ?? '';
    if (sourceSlotId != null && sourceSlotId.isNotEmpty && date.isNotEmpty) {
      await _timetable.markSlotCoveredForDate(
        slotId: sourceSlotId,
        date: date,
        teacherId: toTeacherId,
        teacherName: toTeacherName,
        sourceFixtureId: fixtureId,
      );
    }

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
