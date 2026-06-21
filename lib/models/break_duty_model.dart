/// A recurring weekly break/recess/lunch supervision duty assigned to one
/// or more teachers. Independent of the class timetable — duties are about
/// covering the playground/canteen/corridor during a break period, not
/// about teaching a class.
class BreakDutyModel {
  final String id;
  final String name;

  /// Working days this duty repeats on, e.g. ['Monday','Wednesday'].
  final List<String> days;

  final String startTime;
  final String endTime;

  /// Optional link back to the TimeProfile break period this duty mirrors,
  /// so editing the break's time in the time profile can prompt a re-check.
  final String timeProfileId;
  final String periodLabel;

  final List<String> teacherIds;
  final List<String> teacherNames;

  final String location;
  final String notes;

  BreakDutyModel({
    required this.id,
    required this.name,
    required this.days,
    required this.startTime,
    required this.endTime,
    this.timeProfileId = '',
    this.periodLabel = '',
    this.teacherIds = const [],
    this.teacherNames = const [],
    this.location = '',
    this.notes = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'days': days,
      'startTime': startTime,
      'endTime': endTime,
      'timeProfileId': timeProfileId,
      'periodLabel': periodLabel,
      'teacherIds': teacherIds,
      'teacherNames': teacherNames,
      'location': location,
      'notes': notes,
    };
  }

  factory BreakDutyModel.fromMap(String id, Map<String, dynamic> map) {
    return BreakDutyModel(
      id: id,
      name: map['name']?.toString() ?? 'Break Duty',
      days: map['days'] is List
          ? (map['days'] as List).map((e) => e.toString()).toList()
          : <String>[],
      startTime: map['startTime']?.toString() ?? '',
      endTime: map['endTime']?.toString() ?? '',
      timeProfileId: map['timeProfileId']?.toString() ?? '',
      periodLabel: map['periodLabel']?.toString() ?? '',
      teacherIds: map['teacherIds'] is List
          ? (map['teacherIds'] as List).map((e) => e.toString()).toList()
          : <String>[],
      teacherNames: map['teacherNames'] is List
          ? (map['teacherNames'] as List).map((e) => e.toString()).toList()
          : <String>[],
      location: map['location']?.toString() ?? '',
      notes: map['notes']?.toString() ?? '',
    );
  }

  BreakDutyModel copyWith({
    String? name,
    List<String>? days,
    String? startTime,
    String? endTime,
    List<String>? teacherIds,
    List<String>? teacherNames,
    String? location,
    String? notes,
  }) {
    return BreakDutyModel(
      id: id,
      name: name ?? this.name,
      days: days ?? this.days,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      timeProfileId: timeProfileId,
      periodLabel: periodLabel,
      teacherIds: teacherIds ?? this.teacherIds,
      teacherNames: teacherNames ?? this.teacherNames,
      location: location ?? this.location,
      notes: notes ?? this.notes,
    );
  }
}
