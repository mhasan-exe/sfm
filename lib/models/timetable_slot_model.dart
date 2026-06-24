/// A single cell in a class timetable: one [unit] on one [day] for one class.
///
/// `weekly_timetables` is now the ONLY permanent store for this shape of
/// document — there is no more separate `daily_timetables` collection.
/// Per-date deviations (leave, exchanges, admin one-off overrides, fixture
/// cover) are sparse records in `timetable_exceptions`
/// (see TimetableExceptionModel) layered on top of the weekly slot at read
/// time, instead of a second full copy of every slot for every date. An
/// empty [teacherId] means the slot is unassigned.
class TimetableSlotModel {
  final String id;
  final String classId;
  final String className;
  final String teacherId;
  final String teacherName;
  final String day;
  final int unit;
  final String startTime;
  final String endTime;

  /// 'permanent' for the base weekly plan, 'override' once an admin or an
  /// exchange changes the assignment for a specific day/date.
  final String type;

  /// The teacher originally responsible for this slot (used so an exchange or
  /// override can be reverted and so fixtures know who is really absent).
  final String originalTeacherId;

  TimetableSlotModel({
    required this.id,
    required this.classId,
    required this.className,
    required this.day,
    required this.unit,
    required this.startTime,
    required this.endTime,
    required this.teacherId,
    required this.teacherName,
    required this.type,
    required this.originalTeacherId,
  });

  /// Whether a teacher is currently assigned to this slot.
  bool get isAssigned => teacherId.trim().isNotEmpty;

  /// Convenience: zero-based period index derived from the 1-based [unit].
  int get periodIndex => unit > 0 ? unit - 1 : 0;

  Map<String, dynamic> toMap() {
    return {
      'classId': classId,
      'className': className,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'day': day,
      'unit': unit,
      'startTime': startTime,
      'endTime': endTime,
      'type': type,
      'originalTeacherId': originalTeacherId,
    };
  }

  factory TimetableSlotModel.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    // Tolerate the legacy `assignedTeacherId`/`assignedTeacherName` field names
    // so older documents still render correctly after the schema unification.
    final teacherId = (map['teacherId'] as String?) ??
        (map['assignedTeacherId'] as String?) ??
        '';
    final teacherName = (map['teacherName'] as String?) ??
        (map['assignedTeacherName'] as String?) ??
        '';
    return TimetableSlotModel(
      id: id,
      classId: map['classId'] as String? ?? '',
      className: map['className'] as String? ?? '',
      teacherId: teacherId,
      teacherName: teacherName,
      day: map['day'] as String? ?? '',
      unit: (map['unit'] as num?)?.toInt() ?? 0,
      startTime: map['startTime'] as String? ?? '',
      endTime: map['endTime'] as String? ?? '',
      type: map['type'] as String? ?? 'permanent',
      originalTeacherId: map['originalTeacherId'] as String? ?? teacherId,
    );
  }

  TimetableSlotModel copyWith({
    String? teacherId,
    String? teacherName,
    String? type,
    String? originalTeacherId,
  }) {
    return TimetableSlotModel(
      id: id,
      classId: classId,
      className: className,
      day: day,
      unit: unit,
      startTime: startTime,
      endTime: endTime,
      teacherId: teacherId ?? this.teacherId,
      teacherName: teacherName ?? this.teacherName,
      type: type ?? this.type,
      originalTeacherId: originalTeacherId ?? this.originalTeacherId,
    );
  }
}
