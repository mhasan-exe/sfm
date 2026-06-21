import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/break_duty_model.dart';
import 'notification_service.dart';

class BreakDutyService {
  CollectionReference<Map<String, dynamic>> get _duties =>
      FirebaseFirestore.instance.collection('break_duties');

  Stream<List<BreakDutyModel>> watchAll() {
    return _duties.snapshots().map((snap) {
      final list =
          snap.docs.map((d) => BreakDutyModel.fromMap(d.id, d.data())).toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    });
  }

  /// Duties that include [teacherId] on [day] — used by the teacher's home
  /// screen to surface "you have break duty today" and to drive reminders.
  Stream<List<BreakDutyModel>> watchForTeacher(String teacherId) {
    return _duties
        .where('teacherIds', arrayContains: teacherId)
        .snapshots()
        .map((snap) {
      final list =
          snap.docs.map((d) => BreakDutyModel.fromMap(d.id, d.data())).toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    });
  }

  Future<String> createDuty(BreakDutyModel duty) async {
    final ref = await _duties.add({
      ...duty.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    for (final teacherId in duty.teacherIds) {
      await NotificationService().notifyTeacher(
        teacherId: teacherId,
        title: 'Break duty assigned',
        body:
            '${duty.name} on ${duty.days.join(', ')} (${duty.startTime}-${duty.endTime})',
        type: NotificationType.classOccurring,
        data: {'breakDutyId': ref.id},
      );
    }
    return ref.id;
  }

  Future<void> updateDuty(BreakDutyModel duty) async {
    await _duties.doc(duty.id).set({
      ...duty.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    for (final teacherId in duty.teacherIds) {
      await NotificationService().notifyTeacher(
        teacherId: teacherId,
        title: 'Break duty updated',
        body:
            '${duty.name} on ${duty.days.join(', ')} (${duty.startTime}-${duty.endTime})',
        type: NotificationType.classOccurring,
        data: {'breakDutyId': duty.id},
      );
    }
  }

  Future<void> deleteDuty(String id) async {
    final doc = await _duties.doc(id).get();
    final data = doc.data();
    await _duties.doc(id).delete();

    if (data == null) return;
    final teacherIds = data['teacherIds'] is List
        ? (data['teacherIds'] as List).map((e) => e.toString()).toList()
        : <String>[];
    final name = data['name']?.toString() ?? 'Break duty';
    for (final teacherId in teacherIds) {
      await NotificationService().notifyTeacher(
        teacherId: teacherId,
        title: 'Break duty removed',
        body: '$name has been removed from the roster.',
        type: NotificationType.classOccurring,
        data: {},
      );
    }
  }
}
