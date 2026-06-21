import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum AuditLevel { info, warning, critical }

class LoggingService {
  static final LoggingService _instance = LoggingService._internal();
  factory LoggingService() => _instance;
  LoggingService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Log any action with full transparency
  Future<void> logAction({
    required String action,
    required String description,
    Map<String, dynamic>? details,
    AuditLevel level = AuditLevel.info,
    String? impactedUserId,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      final logEntry = {
        'timestamp': FieldValue.serverTimestamp(),
        'userId': currentUser.uid,
        'userEmail': currentUser.email,
        'action': action,
        'description': description,
        'level': level.toString(),
        'details': details ?? {},
        'impactedUserId': impactedUserId,
        'platform': _getPlatform(),
      };

      // Write to both logs collection and archive
      await _firestore.collection('logs').add(logEntry);
      await _firestore.collection('audit_trail').add(logEntry);

      print('[LOG] $action: $description');
    } catch (e) {
      print('Error logging action: $e');
    }
  }

  // Log timetable changes
  Future<void> logTimetableChange({
    required String classId,
    required String className,
    required String change,
    Map<String, dynamic>? details,
  }) async {
    await logAction(
      action: 'timetable_change',
      description: '$className: $change',
      details: {
        'classId': classId,
        'className': className,
        ...?details,
      },
      level: AuditLevel.info,
    );
  }

  // Log teacher assignment
  Future<void> logTeacherAssignment({
    required String teacherId,
    required String teacherName,
    required String slotId,
    required String className,
    required String unitName,
  }) async {
    await logAction(
      action: 'teacher_assigned',
      description: '$teacherName assigned to $className - $unitName',
      details: {
        'teacherId': teacherId,
        'teacherName': teacherName,
        'slotId': slotId,
        'className': className,
        'unitName': unitName,
      },
      level: AuditLevel.info,
      impactedUserId: teacherId,
    );
  }

  // Log leave submission
  Future<void> logLeaveSubmission({
    required String teacherId,
    required String teacherName,
    required DateTime startDate,
    required DateTime endDate,
    required String reason,
  }) async {
    await logAction(
      action: 'leave_submitted',
      description: '$teacherName submitted leave from ${startDate.toString().split(' ')[0]} to ${endDate.toString().split(' ')[0]}',
      details: {
        'teacherId': teacherId,
        'teacherName': teacherName,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate.toIso8601String(),
        'reason': reason,
      },
      level: AuditLevel.info,
      impactedUserId: teacherId,
    );
  }

  // Log leave approval
  Future<void> logLeaveApproval({
    required String leaveRequestId,
    required String teacherName,
    required String adminName,
    required bool approved,
    String? rejectionReason,
  }) async {
    await logAction(
      action: approved ? 'leave_approved' : 'leave_rejected',
      description: '$adminName ${approved ? 'approved' : 'rejected'} leave for $teacherName${approved ? '' : ' - $rejectionReason'}',
      details: {
        'leaveRequestId': leaveRequestId,
        'teacherName': teacherName,
        'adminName': adminName,
        'approved': approved,
        'rejectionReason': rejectionReason,
      },
      level: approved ? AuditLevel.info : AuditLevel.warning,
    );
  }

  // Log fixture event
  Future<void> logFixtureEvent({
    required String fixtureId,
    required String eventType, // 'created', 'claimed', 'assigned', 'expired', 'released'
    required String className,
    required String? teacherName,
    Map<String, dynamic>? details,
  }) async {
    await logAction(
      action: 'fixture_$eventType',
      description: '$eventType - $className${teacherName != null ? ' - $teacherName' : ''}',
      details: {
        'fixtureId': fixtureId,
        'className': className,
        'teacherName': teacherName,
        ...?details,
      },
      level: AuditLevel.info,
    );
  }

  // Log admin configuration change
  Future<void> logConfigChange({
    required String configType, // 'schedule', 'settings', 'system'
    required String description,
    Map<String, dynamic>? oldValues,
    Map<String, dynamic>? newValues,
  }) async {
    await logAction(
      action: 'config_changed',
      description: '$configType: $description',
      details: {
        'configType': configType,
        'oldValues': oldValues,
        'newValues': newValues,
      },
      level: AuditLevel.critical,
    );
  }

  // Log absence marking
  Future<void> logAbsenceMarking({
    required String teacherId,
    required String teacherName,
    required DateTime date,
    required String reason,
  }) async {
    await logAction(
      action: 'absence_marked',
      description: '$teacherName marked absent on ${date.toString().split(' ')[0]}',
      details: {
        'teacherId': teacherId,
        'teacherName': teacherName,
        'date': date.toIso8601String(),
        'reason': reason,
      },
      level: AuditLevel.warning,
      impactedUserId: teacherId,
    );
  }

  // Log fixture marketplace event
  Future<void> logMarketplaceEvent({
    required String fixtureId,
    required String eventType,
    required String className,
    required String? teacherName,
    Map<String, dynamic>? details,
  }) async {
    final levels = {
      'marketplace_opened': AuditLevel.info,
      'fixture_claimed': AuditLevel.info,
      'fixture_expired': AuditLevel.warning,
      'fixture_assigned': AuditLevel.info,
    };

    await logAction(
      action: 'marketplace_event',
      description: '$eventType - $className${teacherName != null ? ' - $teacherName' : ''}',
      details: {
        'fixtureId': fixtureId,
        'eventType': eventType,
        'className': className,
        'teacherName': teacherName,
        ...?details,
      },
      level: levels[eventType] ?? AuditLevel.info,
    );
  }

  // Get audit logs with filters
  Future<List<Map<String, dynamic>>> getAuditLogs({
    DateTime? startDate,
    DateTime? endDate,
    String? action,
    String? userId,
    int limit = 100,
  }) async {
    try {
      Query query = _firestore.collection('audit_trail');

      if (startDate != null) {
        query = query.where('timestamp',
            isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }

      if (endDate != null) {
        query = query.where('timestamp',
            isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }

      if (action != null) {
        query = query.where('action', isEqualTo: action);
      }

      if (userId != null) {
        query = query.where('userId', isEqualTo: userId);
      }

      final results = await query
          .orderBy('timestamp', descending: true)
          .limit(limit)
          .get();

      return results.docs
          .map((doc) => {
                ...doc.data() as Map<String, dynamic>,
                'id': doc.id,
              })
          .toList();
    } catch (e) {
      print('Error fetching audit logs: $e');
      return [];
    }
  }

  // Watch audit logs (real-time)
  Stream<List<Map<String, dynamic>>> watchAuditLogs({
    DateTime? startDate,
    int limit = 50,
  }) {
    Query query = _firestore
        .collection('audit_trail')
        .orderBy('timestamp', descending: true)
        .limit(limit);

    if (startDate != null) {
      query = query.where('timestamp',
          isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
    }

    return query.snapshots().map((snapshot) => snapshot.docs
        .map((doc) => {
              ...doc.data() as Map<String, dynamic>,
              'id': doc.id,
            })
        .toList());
  }

  // Get activity summary
  Future<Map<String, dynamic>> getActivitySummary({
    Duration period = const Duration(days: 7),
  }) async {
    try {
      final startDate = DateTime.now().subtract(period);

      final logs = await getAuditLogs(
        startDate: startDate,
        limit: 1000,
      );

      final summary = {
        'totalActions': logs.length,
        'criticalActions': logs
            .where((log) => log['level'] == 'AuditLevel.critical')
            .length,
        'byType': <String, int>{},
        'byUser': <String, int>{},
      };

      final byType = summary['byType'] as Map<String, int>;
      final byUser = summary['byUser'] as Map<String, int>;

      for (final log in logs) {
        final action = log['action'] as String? ?? 'unknown';
        final userId = log['userId'] as String? ?? 'unknown';

        byType.update(action, (v) => v + 1, ifAbsent: () => 1);
        byUser.update(userId, (v) => v + 1, ifAbsent: () => 1);
      }



      return summary;
    } catch (e) {
      print('Error getting activity summary: $e');
      return {};
    }
  }

  String _getPlatform() {
    // Placeholder - would need dart:io to implement properly
    return 'web';
  }
}


