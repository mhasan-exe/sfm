import '../core/utils/timetable_constants.dart';

/// One teacher's commitment to a specific class.
///
/// [unitsWeek] is how many permanent periods this teacher should teach this
/// class per week. [isClassTeacher] marks the single teacher who always takes
/// the first unit of every day for the class.
class ClassTeacherAssignment {
  final String teacherId;
  final String teacherName;
  final int unitsWeek;
  final bool isClassTeacher;

  const ClassTeacherAssignment({
    required this.teacherId,
    required this.teacherName,
    required this.unitsWeek,
    this.isClassTeacher = false,
  });

  Map<String, dynamic> toMap() => {
        'teacherId': teacherId,
        'teacherName': teacherName,
        'unitsWeek': unitsWeek,
        'isClassTeacher': isClassTeacher,
      };

  factory ClassTeacherAssignment.fromMap(Map<String, dynamic> map) {
    return ClassTeacherAssignment(
      teacherId: map['teacherId'] as String? ?? '',
      teacherName: map['teacherName'] as String? ?? '',
      unitsWeek: (map['unitsWeek'] as num?)?.toInt() ?? 0,
      isClassTeacher: map['isClassTeacher'] as bool? ?? false,
    );
  }

  ClassTeacherAssignment copyWith({
    String? teacherName,
    int? unitsWeek,
    bool? isClassTeacher,
  }) {
    return ClassTeacherAssignment(
      teacherId: teacherId,
      teacherName: teacherName ?? this.teacherName,
      unitsWeek: unitsWeek ?? this.unitsWeek,
      isClassTeacher: isClassTeacher ?? this.isClassTeacher,
    );
  }
}

class ClassModel {
  final String id;
  final String className;
  final String timeProfileId;
  final int unitsPerDay;

  /// Working days this class runs on. Defaults to the canonical week.
  final List<String> workingDays;

  /// The class teacher (owns the first unit of every day). May be empty.
  final String classTeacherId;
  final String classTeacherName;

  /// Per-teacher weekly unit quotas for this class (incl. the class teacher).
  final List<ClassTeacherAssignment> teachers;

  ClassModel({
    required this.id,
    required this.className,
    required this.timeProfileId,
    required this.unitsPerDay,
    this.workingDays = kWorkingDays,
    this.classTeacherId = '',
    this.classTeacherName = '',
    this.teachers = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'className': className,
      'timeProfileId': timeProfileId,
      'unitsPerDay': unitsPerDay,
      'workingDays': workingDays,
      'classTeacherId': classTeacherId,
      'classTeacherName': classTeacherName,
      'teachers': teachers.map((t) => t.toMap()).toList(),
    };
  }

  factory ClassModel.fromMap(Map<String, dynamic> map) {
    final rawDays = map['workingDays'];
    final days = rawDays is List && rawDays.isNotEmpty
        ? rawDays.map((e) => e.toString()).toList()
        : kWorkingDays;

    final rawTeachers = map['teachers'];
    final teachers = rawTeachers is List
        ? rawTeachers
            .whereType<Map>()
            .map((e) =>
                ClassTeacherAssignment.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <ClassTeacherAssignment>[];

    return ClassModel(
      id: map['id'] as String? ?? '',
      className: map['className'] as String? ?? '',
      timeProfileId: map['timeProfileId'] as String? ?? '',
      unitsPerDay: (map['unitsPerDay'] as num?)?.toInt() ?? 0,
      workingDays: days,
      classTeacherId: map['classTeacherId'] as String? ?? '',
      classTeacherName: map['classTeacherName'] as String? ?? '',
      teachers: teachers,
    );
  }
}
