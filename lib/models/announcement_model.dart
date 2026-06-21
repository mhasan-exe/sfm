import 'package:cloud_firestore/cloud_firestore.dart';

/// An admin-broadcast item shown to every teacher as a blocking "must
/// acknowledge" prompt. Two flavours:
///  - `message`: a plain announcement (no time attached).
///  - `event`: has [eventAt] — a meeting/event teachers are periodically
///    reminded about until that moment passes.
class AnnouncementModel {
  final String id;
  final String title;
  final String message;
  final String type; // 'message' | 'event'
  final DateTime? eventAt;
  final String createdBy;
  final String createdByName;
  final DateTime createdAt;
  final bool active;

  AnnouncementModel({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    required this.active,
    this.eventAt,
  });

  bool get isEvent => type == 'event' && eventAt != null;
  bool get eventHasPassed => isEvent && DateTime.now().isAfter(eventAt!);

  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'message': message,
      'type': type,
      'eventAt': eventAt != null ? Timestamp.fromDate(eventAt!) : null,
      'createdBy': createdBy,
      'createdByName': createdByName,
      'createdAt': FieldValue.serverTimestamp(),
      'active': active,
    };
  }

  factory AnnouncementModel.fromMap(String id, Map<String, dynamic> map) {
    return AnnouncementModel(
      id: id,
      title: map['title']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
      type: map['type']?.toString() ?? 'message',
      eventAt: (map['eventAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy']?.toString() ?? '',
      createdByName: map['createdByName']?.toString() ?? 'Admin',
      createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      active: map['active'] as bool? ?? true,
    );
  }
}
