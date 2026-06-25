import 'package:cloud_firestore/cloud_firestore.dart';

import 'timetable_preset_service.dart';
import 'timetable_service.dart';

class TimetableGenerationSummary {
  final int classesGenerated;
  final int classesSkipped;
  final List<String> warnings;

  const TimetableGenerationSummary({
    required this.classesGenerated,
    required this.classesSkipped,
    required this.warnings,
  });
}

class AdminConfigService {
  CollectionReference<Map<String, dynamic>> get _configs =>
      FirebaseFirestore.instance.collection('admin_configs');

  // Save timetable generation schedule
  //
  // `mode` is 'generate' (run the algorithm fresh, the historical default)
  // or 'preset' (load a saved snapshot instead) — set `presetId` when mode
  // is 'preset'. Whatever external trigger eventually fires this schedule
  // (manual "Run now" button, or a scheduled job) should read this same
  // mode/presetId pair from [getTimetableGenerationSchedule] and act on it
  // via [triggerTimetableGeneration], which already branches correctly.
  Future<void> setTimetableGenerationSchedule({
    required String generationTime, // Format: "HH:mm" e.g., "23:30"
    required String generationDay, // e.g., "Sunday"
    String mode = 'generate',
    String? presetId,
  }) async {
    await _configs.doc('timetable_generation').set({
      'generationTime': generationTime,
      'generationDay': generationDay,
      'mode': mode,
      'presetId': presetId,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Save workload reset schedule
  Future<void> setWorkloadResetSchedule({
    required String resetTime, // Format: "HH:mm"
    required String resetDay, // e.g., "Monday"
  }) async {
    await _configs.doc('workload_reset').set({
      'resetTime': resetTime,
      'resetDay': resetDay,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Get timetable generation schedule
  Future<Map<String, dynamic>?> getTimetableGenerationSchedule() async {
    final doc = await _configs.doc('timetable_generation').get();
    return doc.data();
  }

  // Get workload reset schedule
  Future<Map<String, dynamic>?> getWorkloadResetSchedule() async {
    final doc = await _configs.doc('workload_reset').get();
    return doc.data();
  }

  // Watch timetable generation schedule changes
  Stream<Map<String, dynamic>?> watchTimetableGenerationSchedule() {
    return _configs.doc('timetable_generation').snapshots().map((doc) {
      return doc.data();
    });
  }

  // Watch workload reset schedule changes
  Stream<Map<String, dynamic>?> watchWorkloadResetSchedule() {
    return _configs.doc('workload_reset').snapshots().map((doc) {
      return doc.data();
    });
  }

  // Manual trigger for timetable generation.
  //
  // FIX: this previously did the exact same thing as triggerWorkloadReset()
  // (just zeroed out defaultUnits/fixtureUnits on every user) — it never
  // actually generated a single timetable slot. It now runs the real
  // per-class generator (the same one the "Generate" button on each class's
  // Timetable page uses) across every class.
  Future<TimetableGenerationSummary> triggerTimetableGeneration({
    required String triggeredBy,
    String? triggeredByName,
  }) async {
    final schedule = await getTimetableGenerationSchedule();
    final mode = schedule?['mode']?.toString() ?? 'generate';
    final presetId = schedule?['presetId']?.toString();

    if (mode == 'preset' && presetId != null && presetId.isNotEmpty) {
      try {
        await TimetablePresetService().loadPreset(
          presetId,
          loadedBy: triggeredBy,
          loadedByName: triggeredByName ?? triggeredBy,
        );
        return const TimetableGenerationSummary(
          classesGenerated: 0,
          classesSkipped: 0,
          warnings: ['Loaded saved preset instead of generating fresh.'],
        );
      } catch (e) {
        return TimetableGenerationSummary(
          classesGenerated: 0,
          classesSkipped: 0,
          warnings: ['Failed to load preset: $e'],
        );
      }
    }

    final classesSnapshot =
        await FirebaseFirestore.instance.collection('classes').get();

    final timetableService = TimetableService();
    var classesGenerated = 0;
    var classesSkipped = 0;
    final allWarnings = <String>[];

    for (final classDoc in classesSnapshot.docs) {
      final className = (classDoc.data()['className'] as String?) ?? classDoc.id;
      try {
        final outcome = await timetableService.generateAndApplyClassTimetable(
          classId: classDoc.id,
        );
        classesGenerated++;
        allWarnings.addAll(outcome.warnings.map((w) => '$className: $w'));
      } catch (e) {
        classesSkipped++;
        allWarnings.add('$className: generation failed — $e');
      }
    }

    await FirebaseFirestore.instance.collection('audit_logs').add({
      'action': 'timetable_generation_manual',
      'triggeredBy': triggeredBy,
      'classesGenerated': classesGenerated,
      'classesSkipped': classesSkipped,
      'timestamp': FieldValue.serverTimestamp(),
    });

    return TimetableGenerationSummary(
      classesGenerated: classesGenerated,
      classesSkipped: classesSkipped,
      warnings: allWarnings,
    );
  }

  // Manual trigger for workload reset.
  //
  // Only `fixtureUnits` is meaningfully reset here. `defaultUnits` is no
  // longer read from the stored field anywhere in the app — it's always
  // computed live from `weekly_timetables` (see
  // UserService.getLivePermanentUnits) — so continuing to zero it here
  // would silently do nothing while the button claimed otherwise.
  Future<void> triggerWorkloadReset({
    required String triggeredBy,
  }) async {
    await FirebaseFirestore.instance.collection('audit_logs').add({
      'action': 'workload_reset_manual',
      'triggeredBy': triggeredBy,
      'timestamp': FieldValue.serverTimestamp(),
    });

    // Reset all teacher fixture-cover unit counts.
    final usersSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .get();

    final batch = FirebaseFirestore.instance.batch();

    for (final userDoc in usersSnapshot.docs) {
      batch.update(userDoc.reference, {
        'fixtureUnits': 0,
        'lastResetAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  // Set system-wide settings
  //
  // `sameDayLeaveCutoffTime` is kept (and still written) purely for backward
  // compatibility with old documents/dashboards — the single source of
  // truth going forward is `unifiedCutoffTime`, which now gates leave
  // requests, fixture claims, fixture exchanges AND daily slot exchanges
  // identically (see AdminConfigService.isPastUnifiedCutoffNow).
  Future<void> updateSystemSettings({
    required bool allowFixtureMarketplace,
    required bool allowTeacherLeaveRequests,
    required bool requireApprovalForLeaves,
    required int maxUnitsPerTeacher,
    required String unifiedCutoffTime, // Format: "HH:mm" e.g. "12:45"
    int rejectionCooldownHours = 24,
    int fixtureClaimWindowHours = 1,
    int fixtureAutoAssignMinutes = 5,
    bool breakDutyRemindersEnabled = true,
    List<int> reminderOffsetsMinutes = const [30, 15],
    bool allowQuotaOverride = true,
    bool protectFirstUnitForClassTeacher = true,
  }) async {
    await _configs.doc('system_settings').set({
      'allowFixtureMarketplace': allowFixtureMarketplace,
      'allowTeacherLeaveRequests': allowTeacherLeaveRequests,
      'requireApprovalForLeaves': requireApprovalForLeaves,
      'maxUnitsPerTeacher': maxUnitsPerTeacher,
      'unifiedCutoffTime': unifiedCutoffTime,
      'sameDayLeaveCutoffTime': unifiedCutoffTime,
      'rejectionCooldownHours': rejectionCooldownHours,
      'fixtureClaimWindowHours': fixtureClaimWindowHours,
      'fixtureAutoAssignMinutes': fixtureAutoAssignMinutes,
      'breakDutyRemindersEnabled': breakDutyRemindersEnabled,
      'reminderOffsetsMinutes': reminderOffsetsMinutes,
      'allowQuotaOverride': allowQuotaOverride,
      'protectFirstUnitForClassTeacher': protectFirstUnitForClassTeacher,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Get system settings
  Future<Map<String, dynamic>?> getSystemSettings() async {
    final doc = await _configs.doc('system_settings').get();
    return doc.data();
  }

  // Watch system settings
  Stream<Map<String, dynamic>?> watchSystemSettings() {
    return _configs.doc('system_settings').snapshots().map((doc) {
      return doc.data();
    });
  }

  /// The single cutoff time string ("HH:mm") that gates *all* same-day
  /// leave/fixture-claim/fixture-exchange/slot-exchange actions. Falls back
  /// to the legacy field, then a hardcoded sane default, so older deployed
  /// schools that haven't re-saved settings yet keep working.
  Future<String> getUnifiedCutoffTime() async {
    final settings = await getSystemSettings();
    final unified = settings?['unifiedCutoffTime'] as String?;
    if (unified != null && unified.trim().isNotEmpty) return unified;
    final legacy = settings?['sameDayLeaveCutoffTime'] as String?;
    if (legacy != null && legacy.trim().isNotEmpty) return legacy;
    return '12:45';
  }

  /// True once "now" is past today's unified cutoff. Same-day leave
  /// requests, fixture claims, fixture exchanges and daily slot exchanges
  /// must all check this before proceeding.
  Future<bool> isPastUnifiedCutoffNow() async {
    final cutoff = await getUnifiedCutoffTime();
    final parts = cutoff.split(':');
    if (parts.length != 2) return false;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return false;
    final now = DateTime.now();
    final cutoffDateTime =
        DateTime(now.year, now.month, now.day, hour, minute);
    return now.isAfter(cutoffDateTime);
  }

  Future<int> getMaxUnitsPerTeacher() async {
    final settings = await getSystemSettings();
    return (settings?['maxUnitsPerTeacher'] as num?)?.toInt() ?? 24;
  }

  Future<int> getRejectionCooldownHours() async {
    final settings = await getSystemSettings();
    return (settings?['rejectionCooldownHours'] as num?)?.toInt() ?? 24;
  }

  Future<int> getFixtureClaimWindowHours() async {
    final settings = await getSystemSettings();
    return (settings?['fixtureClaimWindowHours'] as num?)?.toInt() ?? 1;
  }

  Future<int> getFixtureAutoAssignMinutes() async {
    final settings = await getSystemSettings();
    return (settings?['fixtureAutoAssignMinutes'] as num?)?.toInt() ?? 5;
  }

  Future<bool> getAllowQuotaOverride() async {
    final settings = await getSystemSettings();
    return settings?['allowQuotaOverride'] as bool? ?? true;
  }

  /// Whether unit 1 of every working day is locked to the class's
  /// configured class teacher. Defaults to true (the school's normal
  /// rule). Admins can still bypass this per-assignment with an explicit
  /// "assign anyway" warning — this setting only controls whether the
  /// *protection itself* is active, not whether it can ever be overridden
  /// (a manual admin override is always possible, with a warning).
  Future<bool> getProtectFirstUnitForClassTeacher() async {
    final settings = await getSystemSettings();
    return settings?['protectFirstUnitForClassTeacher'] as bool? ?? true;
  }


  Future<List<int>> getReminderOffsetsMinutes() async {
    final settings = await getSystemSettings();
    final raw = settings?['reminderOffsetsMinutes'];
    if (raw is List && raw.isNotEmpty) {
      final list = raw.map((e) => (e as num).toInt()).toList();
      list.sort((a, b) => b.compareTo(a));
      return list;
    }
    return const [30, 15];
  }

  // Log admin action
  Future<void> logAdminAction({
    required String adminId,
    required String action,
    required String details,
  }) async {
    await FirebaseFirestore.instance.collection('audit_logs').add({
      'adminId': adminId,
      'action': action,
      'details': details,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  // Get audit logs
  Future<List<Map<String, dynamic>>> getAuditLogs({
    int limit = 100,
    String? adminId,
    String? action,
  }) async {
    Query query = FirebaseFirestore.instance
        .collection('audit_logs')
        .orderBy('timestamp', descending: true)
        .limit(limit);

    if (adminId != null) {
      query = query.where('adminId', isEqualTo: adminId);
    }

    if (action != null) {
      query = query.where('action', isEqualTo: action);
    }

    final snapshot = await query.get();

    return snapshot.docs.map((doc) {
      final data = doc.data() as Map<String, dynamic>;
      return {...data, 'id': doc.id};
    }).toList();
  }

  // Stream audit logs
  Stream<List<Map<String, dynamic>>> watchAuditLogs() {
    return FirebaseFirestore.instance
        .collection('audit_logs')
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {...data, 'id': doc.id};
      }).toList();
    });
  }
}
