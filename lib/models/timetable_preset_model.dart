import 'package:cloud_firestore/cloud_firestore.dart';

/// A named, point-in-time snapshot of the ENTIRE school's weekly timetable
/// (every class, every slot) — saved so an admin can regenerate freely and
/// still roll back to a known-good arrangement later, or schedule
/// automation to load a preset instead of re-running the generator.
class TimetablePresetModel {
  final String id;
  final String name;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final int classCount;
  final int slotCount;
  final bool isAutoBackup;

  TimetablePresetModel({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.classCount,
    required this.slotCount,
    this.isAutoBackup = false,
  });

  factory TimetablePresetModel.fromMap(String id, Map<String, dynamic> map) {
    return TimetablePresetModel(
      id: id,
      name: map['name']?.toString() ?? 'Untitled preset',
      createdBy: map['createdBy']?.toString() ?? '',
      createdByName: map['createdByName']?.toString() ?? 'Admin',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      classCount: (map['classCount'] as num?)?.toInt() ?? 0,
      slotCount: (map['slotCount'] as num?)?.toInt() ?? 0,
      isAutoBackup: map['isAutoBackup'] as bool? ?? false,
    );
  }
}
