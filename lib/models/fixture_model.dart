class FixtureModel {
  final String id;
  final String classId;
  final String className;
  final String day;
  final int unit;
  final String startTime;
  final String endTime;
  final String? claimedBy;
  final String? claimedByName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool isExpired;
  final String status; // 'available', 'claimed', 'assigned', 'expired'
  final String? assignedTeacherId;
  final String? assignedTeacherName;
  /// Exact calendar date this fixture covers, 'YYYY-MM-DD'. Empty for
  /// legacy/general fixtures created from a recurring weekday pattern only.
  final String date;
  /// If this fixture exists because of an approved leave, the teacher who
  /// is on leave (so they can be excluded from claiming any fixture that
  /// falls within their own leave window).
  final String? absentTeacherId;
  /// True once the system has escalated this fixture to admin because
  /// nobody claimed it and the claim window (1 hour before start) closed.
  /// This is a separate workflow from claims — it just flags the fixture
  /// so the admin's "Needs Manual Assignment" view can surface it.
  final bool manualAssignmentRequired;

  FixtureModel({
    required this.id,
    required this.classId,
    required this.className,
    required this.day,
    required this.unit,
    required this.startTime,
    required this.endTime,
    this.claimedBy,
    this.claimedByName,
    required this.createdAt,
    required this.expiresAt,
    required this.isExpired,
    required this.status,
    this.assignedTeacherId,
    this.assignedTeacherName,
    this.date = '',
    this.absentTeacherId,
    this.manualAssignmentRequired = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'classId': classId,
      'className': className,
      'day': day,
      'unit': unit,
      'startTime': startTime,
      'endTime': endTime,
      'claimedBy': claimedBy,
      'claimedByName': claimedByName,
      'createdAt': createdAt,
      'expiresAt': expiresAt,
      'isExpired': isExpired,
      'status': status,
      'assignedTeacherId': assignedTeacherId,
      'assignedTeacherName': assignedTeacherName,
      'date': date,
      'absentTeacherId': absentTeacherId,
      'manualAssignmentRequired': manualAssignmentRequired,
    };
  }

  factory FixtureModel.fromMap(String id, Map<String, dynamic> map) {
    return FixtureModel(
      id: id,
      classId: map['classId'] as String? ?? '',
      className: map['className'] as String? ?? '',
      day: map['day'] as String? ?? '',
      unit: map['unit'] as int? ?? 0,
      startTime: map['startTime'] as String? ?? '',
      endTime: map['endTime'] as String? ?? '',
      claimedBy: map['claimedBy'] as String?,
      claimedByName: map['claimedByName'] as String?,
      createdAt: (map['createdAt'] as dynamic)?.toDate() ?? DateTime.now(),
      expiresAt: (map['expiresAt'] as dynamic)?.toDate() ?? DateTime.now(),
      isExpired: map['isExpired'] as bool? ?? false,
      status: map['status'] as String? ?? 'available',
      assignedTeacherId: map['assignedTeacherId'] as String?,
      assignedTeacherName: map['assignedTeacherName'] as String?,
      date: map['date'] as String? ?? '',
      absentTeacherId: map['absentTeacherId'] as String?,
      manualAssignmentRequired: map['manualAssignmentRequired'] as bool? ?? false,
    );
  }

  FixtureModel copyWith({
    String? id,
    String? classId,
    String? className,
    String? day,
    int? unit,
    String? startTime,
    String? endTime,
    String? claimedBy,
    String? claimedByName,
    DateTime? createdAt,
    DateTime? expiresAt,
    bool? isExpired,
    String? status,
    String? assignedTeacherId,
    String? assignedTeacherName,
    String? date,
    String? absentTeacherId,
    bool? manualAssignmentRequired,
  }) {
    return FixtureModel(
      id: id ?? this.id,
      classId: classId ?? this.classId,
      className: className ?? this.className,
      day: day ?? this.day,
      unit: unit ?? this.unit,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      claimedBy: claimedBy ?? this.claimedBy,
      claimedByName: claimedByName ?? this.claimedByName,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      isExpired: isExpired ?? this.isExpired,
      status: status ?? this.status,
      assignedTeacherId: assignedTeacherId ?? this.assignedTeacherId,
      assignedTeacherName: assignedTeacherName ?? this.assignedTeacherName,
      date: date ?? this.date,
      absentTeacherId: absentTeacherId ?? this.absentTeacherId,
      manualAssignmentRequired:
          manualAssignmentRequired ?? this.manualAssignmentRequired,
    );
  }
}
