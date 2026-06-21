import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/timetable_slot_model.dart';

class RealtimeTimetableService {
  final firestore = FirebaseFirestore.instance;

  // =====================
  // STREAM TIMETABLE
  // =====================
  Stream<List<TimetableSlotModel>> streamClassTimetable(
    String classId,
  ) {
    return firestore
        .collection('daily_timetables')
        .where('classId', isEqualTo: classId)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return TimetableSlotModel.fromMap(
          doc.id,
          doc.data(),
        );
      }).toList();
    });
  }

  // =====================
  // ASSIGN TEACHER
  // =====================
  Future<void> assignTeacher({
    required String slotId,
    required String teacherId,
    required String teacherName,
  }) async {
    await firestore.collection('daily_timetables').doc(slotId).update({
      'teacherId': teacherId,
      'teacherName': teacherName,
      'type': 'override',
    });
  }

  // =====================
  // CREATE WEEKLY SLOT
  // =====================
  Future<void> createSlot({
    required String classId,
    required String className,
    required String teacherId,
    required String teacherName,
    required String day,
    required int unit,
    required String startTime,
    required String endTime,
  }) async {
    await firestore.collection('weekly_timetables').add({
      'classId': classId,
      'className': className,
      'teacherId': teacherId,
      'teacherName': teacherName,
      'day': day,
      'unit': unit,
      'startTime': startTime,
      'endTime': endTime,
      'type': 'permanent',
      'originalTeacherId': teacherId,
    });
  }

  // =====================
  // GENERATE DAILY
  // =====================
  Future<void> generateDailyTimetable({
    required String date,
  }) async {
    final weekly = await firestore.collection('weekly_timetables').get();
    final batch = firestore.batch();
    final dailyCollection = firestore.collection('daily_timetables');

    for (final doc in weekly.docs) {
      final data = doc.data();
      final newDoc = dailyCollection.doc();
      batch.set(newDoc, {
        ...data,
        'date': date,
        'type': data['type'] ?? 'permanent',
        'originalTeacherId': data['originalTeacherId'] ?? data['teacherId'] ?? '',
      });
    }

    await batch.commit();
  }
}
