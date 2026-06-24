/// A single sparse "deviation from the weekly pattern" record.
///
/// REPLACES the old `daily_timetables` collection. Instead of materializing
/// every slot for every date forever (a second full copy of the entire
/// timetable that could drift out of sync with `weekly_timetables`), we now
/// store ONLY the exceptional dates where something is different from the
/// permanent weekly plan: an approved leave vacating a unit, a one-off
/// teacher exchange for a single day, an admin override for a single day, or
/// a fixture (cover) assignment.
///
/// `weekly_timetables` is the single permanent source of truth for "what
/// normally happens". `timetable_exceptions` is the single source of truth
/// for "what's different on this specific date, and why". A UI that wants
/// "today's effective schedule" merges both: start from the weekly slot,
/// then apply any exception that exists for today's date on top of it.
///
/// The document ID is always deterministic: `${slotId}_${date}` (see
/// [TimetableService.exceptionId]). This makes every write idempotent —
/// approving the same leave twice, or a flaky connection retrying a write,
/// can never create a duplicate/"ghost" exception for the same slot+date.
class TimetableExceptionModel {
  final String id;

  /// The weekly_timetables slot this exception overrides.
  final String slotId;
  final String classId;
  final String className;
  final String day;
  final int unit;
  final String startTime;
  final String endTime;

  /// 'YYYY-MM-DD' — the exact calendar date this exception applies to.
  final String date;

  /// Why this date differs from the weekly pattern:
  /// - 'leave': the normally-assigned teacher has approved leave; vacated
  ///   (or covered, once a fixture is claimed/assigned).
  /// - 'exchange': a teacher-initiated same-day swap between two slots.
  /// - 'admin_override': a manual one-off admin edit for this single date.
  /// - 'fixture_assigned': a fixture (cover) has been claimed/assigned for
  ///   a slot that was vacated by leave.
  final String type;

  /// Who is actually teaching this slot on this date. Empty = vacant.
  final String teacherId;
  final String teacherName;

  /// Who the weekly pattern says SHOULD be teaching this slot. Kept
  /// separate from [teacherId] on purpose — querying "is teacher X affected
  /// today" must never depend on a field that goes blank the moment the
  /// slot is vacated, or the affected teacher's own view of their day stops
  /// showing the vacancy the instant it's created.
  final String originalTeacherId;
  final String originalTeacherName;

  /// Free-form id of whatever caused this exception (a leave_requests doc
  /// id, a fixtures doc id, or an admin uid) — lets a cascade-delete or an
  /// audit trail trace an exception back to its cause.
  final String sourceId;

  TimetableExceptionModel({
    required this.id,
    required this.slotId,
    required this.classId,
    required this.className,
    required this.day,
    required this.unit,
    required this.startTime,
    required this.endTime,
    required this.date,
    required this.type,
    required this.teacherId,
    required this.teacherName,
    required this.originalTeacherId,
    required this.originalTeacherName,
    this.sourceId = '',
  });

  bool get isVacant => teacherId.trim().isEmpty;

  Map<String, dynamic> toMap() => {
        'slotId': slotId,
        'classId': classId,
        'className': className,
        'day': day,
        'unit': unit,
        'startTime': startTime,
        'endTime': endTime,
        'date': date,
        'type': type,
        'teacherId': teacherId,
        'teacherName': teacherName,
        'originalTeacherId': originalTeacherId,
        'originalTeacherName': originalTeacherName,
        'sourceId': sourceId,
      };

  factory TimetableExceptionModel.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return TimetableExceptionModel(
      id: id,
      slotId: map['slotId'] as String? ?? '',
      classId: map['classId'] as String? ?? '',
      className: map['className'] as String? ?? '',
      day: map['day'] as String? ?? '',
      unit: (map['unit'] as num?)?.toInt() ?? 0,
      startTime: map['startTime'] as String? ?? '',
      endTime: map['endTime'] as String? ?? '',
      date: map['date'] as String? ?? '',
      type: map['type'] as String? ?? 'admin_override',
      teacherId: map['teacherId'] as String? ?? '',
      teacherName: map['teacherName'] as String? ?? '',
      originalTeacherId: map['originalTeacherId'] as String? ?? '',
      originalTeacherName: map['originalTeacherName'] as String? ?? '',
      sourceId: map['sourceId'] as String? ?? '',
    );
  }
}
