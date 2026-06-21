import 'package:cloud_firestore/cloud_firestore.dart';

import 'admin_config_service.dart';
import 'notification_service.dart';
import 'timetable_service.dart';
import 'fixture_service.dart';

class LeaveService {
  CollectionReference<Map<String, dynamic>> get _leaveRequests =>
      FirebaseFirestore.instance.collection('leave_requests');

  final AdminConfigService _adminConfig = AdminConfigService();

  /// Compares two Firestore values that should be Timestamps (handles
  /// null/missing gracefully so a doc with no value sorts last instead of
  /// throwing). Used to sort client-side and avoid needing a composite
  /// Firestore index for where()+orderBy() queries.
  int _compareTimestamps(dynamic a, dynamic b) {
    final da = a is Timestamp ? a.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
    final db = b is Timestamp ? b.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
    return da.compareTo(db);
  }

  // Submit a leave request
  Future<String> submitLeave({
    required String teacherId,
    required String teacherName,
    required DateTime startDate,
    required DateTime endDate,
    required String reason,
  }) async {
    if (endDate.isBefore(startDate)) {
      throw Exception('End date cannot be before start date');
    }

    // Admin-configurable cutoff:
    // - Reject same-day requests after cutoff time.
    // - Allow only startDate >= tomorrow when it is a same-day request.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));

    final isSameDayRequest =
        DateTime(startDate.year, startDate.month, startDate.day) == today;

    // --- Anti-spam: block if a pending request already exists, or a
    // recent rejection is still inside its cooldown window. This applies
    // regardless of which dates are requested — one open conversation
    // about leave at a time per teacher. ---
    final existingSnapshot =
        await _leaveRequests.where('teacherId', isEqualTo: teacherId).get();

    DateTime? mostRecentRejectedAt;
    for (final doc in existingSnapshot.docs) {
      final data = doc.data();
      final status = data['status']?.toString();
      if (status == 'pending') {
        throw Exception(
            'You already have a pending leave request. Please wait for it to be reviewed before submitting another.');
      }
      if (status == 'rejected') {
        final rejectedAt = data['rejectedAt'];
        final dt = rejectedAt is Timestamp ? rejectedAt.toDate() : null;
        if (dt != null &&
            (mostRecentRejectedAt == null || dt.isAfter(mostRecentRejectedAt))) {
          mostRecentRejectedAt = dt;
        }
      }
    }

    if (mostRecentRejectedAt != null) {
      final cooldownHours = await _adminConfig.getRejectionCooldownHours();
      final cooldownEnds =
          mostRecentRejectedAt.add(Duration(hours: cooldownHours));
      if (now.isBefore(cooldownEnds)) {
        final remaining = cooldownEnds.difference(now);
        final hoursLeft = remaining.inHours;
        final minutesLeft = remaining.inMinutes % 60;
        throw Exception(
            'Your last leave request was rejected. Please wait ${hoursLeft}h ${minutesLeft}m before submitting another.');
      }
    }

    if (isSameDayRequest) {
      // Single unified cutoff governs leave/fixture-claim/fixture-exchange
      // alike — see AdminConfigService.isPastUnifiedCutoffNow.
      if (await _adminConfig.isPastUnifiedCutoffNow()) {
        throw Exception('Same-day leave requests are blocked after cutoff time');
      }

      // Before/at cutoff allowed, but spec requires: startDate == today only allowed before cutoff.
      // Otherwise, force startDate >= tomorrow.
      // (No extra check here because above covers the only forbidden condition.)
    } else {
      // If somehow caller tries startDate < today, reject as well.
      final startDay = DateTime(startDate.year, startDate.month, startDate.day);
      if (startDay.isBefore(today)) {
        throw Exception('Leave start date cannot be in the past');
      }
      // If startDate is today it is handled above.
      // startDate >= tomorrow is allowed.
      if (startDay.isBefore(tomorrow) && !isSameDayRequest) {
        throw Exception('Invalid leave start date');
      }
    }

    final docRef = await _leaveRequests.add({
      'teacherId': teacherId,
      'teacherName': teacherName,
      'startDate': Timestamp.fromDate(startDate),
      'endDate': Timestamp.fromDate(endDate),
      'reason': reason,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'approvedAt': null,
      'rejectedAt': null,
      'approvedBy': null,
      'rejectionReason': null,
    });

    // Real notification: tell every admin a new leave request is waiting.
    final dateLabel = endDate.difference(startDate).inDays == 0
        ? _formatDate(startDate)
        : '${_formatDate(startDate)} – ${_formatDate(endDate)}';
    await NotificationService().notifyAdmins(
      title: 'New leave request',
      body: '$teacherName requested leave for $dateLabel',
      action: 'leave_submitted',
      data: {'leaveRequestId': docRef.id, 'teacherId': teacherId},
    );

    return docRef.id;
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Returns true if the teacher already has an *approved* leave that overlaps
  /// the provided [startDate]..[endDate] (inclusive).
  Future<bool> hasApprovedLeaveOverlap({
    required String teacherId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    if (endDate.isBefore(startDate)) return false;

    final snapshot = await _leaveRequests
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    for (final doc in snapshot.docs) {
      final leave = doc.data();
      final approvedStart = (leave['startDate'] as Timestamp).toDate();
      final approvedEnd = (leave['endDate'] as Timestamp).toDate();

      // inclusive overlap
      final overlaps = !approvedEnd.isBefore(startDate) &&
          !approvedStart.isAfter(endDate);

      if (overlaps) return true;
    }

    return false;
  }

  // Approve a leave request
  Future<void> approveLeave({
    required String leaveRequestId,
    required String adminId,
    String? adminComment,
  }) async {
    final leaveRef = _leaveRequests.doc(leaveRequestId);
    final leaveDoc = await leaveRef.get();

    if (!leaveDoc.exists) {
      throw Exception('Leave request not found');
    }

    final data = leaveDoc.data()!;
    final teacherId = (data['teacherId'] as String?) ?? '';
    if (teacherId.isEmpty) {
      throw Exception('Leave request missing teacherId');
    }

    final startDate = (data['startDate'] as Timestamp).toDate();
    final endDate = (data['endDate'] as Timestamp).toDate();
    if (endDate.isBefore(startDate)) {
      throw Exception('Invalid leave date range');
    }

    // 1) Mark approved first (source of truth).
    await leaveRef.update({
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
      'approvedBy': adminId,
      'adminComment': adminComment,
    });

    // 2) Clear the teacher's DAILY schedule for every day in the leave
    // range (never the permanent weekly pattern — they're still expected
    // back on a normal week once leave ends), and open each vacated slot
    // as a fixture other teachers can cover.
    List<Map<String, dynamic>> vacatedSlots = [];
    try {
      vacatedSlots = await TimetableService().clearScheduleForApprovedLeave(
        teacherId: teacherId,
        startDate: startDate,
        endDate: endDate,
      );
      if (vacatedSlots.isNotEmpty) {
        await FixtureService().createFixturesForSlots(uncoveredSlots: vacatedSlots);
      }
    } catch (_) {
      // Don't let a clearing/fixture-creation hiccup block the approval
      // itself — the leave is approved either way; an admin can manually
      // patch up any uncovered slot from the timetable editor if needed.
    }

    // Real notification: tell the teacher their leave was approved, and
    // exactly which classes/units were freed up so they can see at a
    // glance what's been affected.
    final dateLabel = endDate.difference(startDate).inDays == 0
        ? _formatDate(startDate)
        : '${_formatDate(startDate)} – ${_formatDate(endDate)}';
    final affectedSummary = vacatedSlots.isEmpty
        ? ''
        : ' ${vacatedSlots.length} class unit(s) (${vacatedSlots.map((s) => '${s['className']} U${s['unit']}').toSet().take(5).join(', ')}) have been opened up for cover.';
    await NotificationService().notifyTeacher(
      teacherId: teacherId,
      title: 'Leave approved',
      body: 'Your leave request for $dateLabel has been approved.$affectedSummary',
      type: NotificationType.leaveApproved,
      data: {'leaveRequestId': leaveRequestId},
    );

    // 2) Apply leave effect to `daily_timetables` on all dates in the
    // approved range.
    //
    // TeacherTimetableScreen renders from:
    // - weekly_timetables (permanent)
    // - daily_timetables filtered by `date == yyyy-MM-dd`
    // and treats empty teacherName/teacherId as an empty slot.

    // Find all classes that include this teacher in their configured
    // `teachers` list.
    final classesSnap = await FirebaseFirestore.instance
        .collection('classes')
        .get();

    final classIds = <String>{};
    for (final cdoc in classesSnap.docs) {
      final data = cdoc.data();
      final rawTeachers = data['teachers'];
      if (rawTeachers is! List) continue;

      final matches = rawTeachers.whereType<Map>().any((t) {
        final tid = t['teacherId']?.toString() ?? '';
        return tid == teacherId;
      });

      if (matches) classIds.add(cdoc.id);
    }

    if (classIds.isNotEmpty) {
      DateTime cursor = DateTime(startDate.year, startDate.month, startDate.day);
      final last = DateTime(endDate.year, endDate.month, endDate.day);

      while (!cursor.isAfter(last)) {
        final dateKey =
            '${cursor.year.toString().padLeft(4, '0')}-'
            '${cursor.month.toString().padLeft(2, '0')}-'
            '${cursor.day.toString().padLeft(2, '0')}';

        // For each class, clear teacher assignments for this date.
        for (final classId in classIds) {
          final snap = await FirebaseFirestore.instance
              .collection('daily_timetables')
              .where('classId', isEqualTo: classId)
              .where('teacherId', isEqualTo: teacherId)
              .where('date', isEqualTo: dateKey)
              .get();

          if (snap.docs.isEmpty) continue;

          final batch = FirebaseFirestore.instance.batch();
          for (final doc in snap.docs) {
            batch.set(
              doc.reference,
              {
                'teacherId': '',
                'teacherName': '',
                'type': 'leave',
                'leaveAppliedAt': FieldValue.serverTimestamp(),
                // keep teacher slot identifiers (day/unit/classId/start/end)
              },
              SetOptions(merge: true),
            );
          }
          await batch.commit();
        }

        cursor = cursor.add(const Duration(days: 1));
      }
    }

  }

  // Reject a leave request
  Future<void> rejectLeave({
    required String leaveRequestId,
    required String adminId,
    required String reason,
  }) async {
    final leaveDoc = await _leaveRequests.doc(leaveRequestId).get();

    if (!leaveDoc.exists) {
      throw Exception('Leave request not found');
    }

    final data = leaveDoc.data()!;
    final teacherId = (data['teacherId'] as String?) ?? '';

    await _leaveRequests.doc(leaveRequestId).update({
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
      'approvedBy': adminId,
      'rejectionReason': reason,
    });

    if (teacherId.isNotEmpty) {
      await NotificationService().notifyTeacher(
        teacherId: teacherId,
        title: 'Leave request declined',
        body: reason.isEmpty
            ? 'Your leave request was declined.'
            : 'Your leave request was declined: $reason',
        type: NotificationType.leaveRejected,
        data: {'leaveRequestId': leaveRequestId},
      );
    }
  }

  // Get all pending leave requests for admin review
  Stream<List<Map<String, dynamic>>> watchPendingLeaves() {
    return _leaveRequests
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) {
        final data = doc.data();
        return {...data, 'id': doc.id};
      }).toList();
      list.sort((a, b) => _compareTimestamps(b['createdAt'], a['createdAt']));
      return list;
    });
  }

  // Get all approved leave requests
  Stream<List<Map<String, dynamic>>> watchApprovedLeaves() {
    return _leaveRequests
        .where('status', isEqualTo: 'approved')
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) {
        final data = doc.data();
        return {...data, 'id': doc.id};
      }).toList();
      list.sort((a, b) => _compareTimestamps(b['startDate'], a['startDate']));
      return list;
    });
  }

  // Get leave requests for a specific teacher
  Stream<List<Map<String, dynamic>>> watchTeacherLeaves(String teacherId) {
    return _leaveRequests
        .where('teacherId', isEqualTo: teacherId)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) {
        final data = doc.data();
        return {...data, 'id': doc.id};
      }).toList();
      list.sort((a, b) => _compareTimestamps(b['createdAt'], a['createdAt']));
      return list;
    });
  }

  // Check if teacher has approved leave on specific date
  Future<bool> hasApprovedLeaveOnDate(
    String teacherId,
    DateTime date,
  ) async {
    final snapshot = await _leaveRequests
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    for (final doc in snapshot.docs) {
      final leave = doc.data();
      final startDate = (leave['startDate'] as Timestamp).toDate();
      final endDate = (leave['endDate'] as Timestamp).toDate();

      // Check if date falls within the leave period
      if (!date.isBefore(startDate) && !date.isAfter(endDate)) {
        return true;
      }
    }

    return false;
  }

  // Get overlapping leave requests for teachers (for conflict detection)
  Future<List<Map<String, dynamic>>> getOverlappingLeaves(
    DateTime startDate,
    DateTime endDate,
  ) async {
    final snapshot = await _leaveRequests
        .where('status', isEqualTo: 'approved')
        .get();

    final overlapping = <Map<String, dynamic>>[];

    for (final doc in snapshot.docs) {
      final leave = doc.data();
      final leaveStart = (leave['startDate'] as Timestamp).toDate();
      final leaveEnd = (leave['endDate'] as Timestamp).toDate();

      // Check if date ranges overlap
      if (leaveStart.isBefore(endDate) && leaveEnd.isAfter(startDate)) {
        overlapping.add({...leave, 'id': doc.id});
      }
    }

    return overlapping;
  }

  // Get leave statistics
  Future<Map<String, dynamic>> getLeaveStats(String teacherId) async {
    final snapshot = await _leaveRequests
        .where('teacherId', isEqualTo: teacherId)
        .where('status', isEqualTo: 'approved')
        .get();

    int totalDays = 0;
    int totalLeaves = 0;

    for (final doc in snapshot.docs) {
      final leave = doc.data();
      final startDate = (leave['startDate'] as Timestamp).toDate();
      final endDate = (leave['endDate'] as Timestamp).toDate();

      final days = endDate.difference(startDate).inDays + 1;
      totalDays += days;
      totalLeaves += 1;
    }

    return {
      'totalLeaves': totalLeaves,
      'totalDays': totalDays,
      'averageDaysPerLeave': totalLeaves > 0 ? totalDays / totalLeaves : 0,
    };
  }

  // Cancel a pending leave request
  Future<void> cancelLeave({required String leaveRequestId}) async {
    final leaveDoc = await _leaveRequests.doc(leaveRequestId).get();

    if (!leaveDoc.exists) {
      throw Exception('Leave request not found');
    }

    final leave = leaveDoc.data()!;

    if (leave['status'] != 'pending') {
      throw Exception('Only pending leaves can be cancelled');
    }

    await _leaveRequests.doc(leaveRequestId).update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }
}

