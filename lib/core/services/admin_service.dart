import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'notification_service.dart';

class AdminService {
  CollectionReference<Map<String, dynamic>> get _admins =>
      FirebaseFirestore.instance.collection('admins');

  Future<bool> isAdmin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    final doc = await _admins.doc(user.uid).get();
    return doc.exists;
  }

  
  Stream<QuerySnapshot<Map<String, dynamic>>> watchAdmins() {
    return _admins.snapshots();
  }

  Future<void> createAdmin({
    required String email,
    required String uid,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    final docId = uid.trim().isNotEmpty ? uid.trim() : normalizedEmail;

    await _admins.doc(docId).set({
      'email': normalizedEmail,
      'uid': uid.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> deleteAdmin(String docId) async {
    await _admins.doc(docId).delete();
  }

  // ---------------------------------------------------------------------
  // Teacher re-sync — pulls every Firebase Auth account and creates a
  // `users/{uid}` doc for any that don't already have one. Handles the
  // case where someone authenticated successfully (so they show up in the
  // Firebase Auth console) but never opened the app far enough for
  // `UserService.createUserIfNotExists()` to run, so no Firestore profile
  // ever got created for them.
  //
  // Must go through a Cloud Function — the client SDK can only see the
  // CURRENTLY signed-in user, never the full list of Auth accounts; that
  // requires the Admin SDK (server-side only). See functions/resyncTeachers.js.
  // ---------------------------------------------------------------------
  Future<Map<String, dynamic>> resyncTeachersFromAuth() async {
    final callable = FirebaseFunctions.instance.httpsCallable('resyncTeachers');
    final result = await callable.call();
    return Map<String, dynamic>.from(result.data as Map);
  }

  // ---------------------------------------------------------------------
  // deleteTeacher — REVERSAL NOTE: this used to run server-side (Admin
  // SDK) so the profile delete, per-class teachers[] cleanup, and
  // weekly_timetables cleanup happened together rather than as several
  // separate client writes that could partially fail. Now runs as direct
  // client writes by deliberate decision — a failure partway through
  // (e.g. after clearing classes but before clearing weekly_timetables)
  // is possible, so this is not fully atomic anymore. Caller should be
  // an admin (enforced by firestore.rules on the underlying writes, since
  // `classes`/`weekly_timetables`/`users` all require isAdmin() to write).
  //
  // IMPORTANT LIMITATION: [alsoDeleteAuthAccount] can no longer do
  // anything. Deleting another user's Firebase Auth account requires the
  // Admin SDK (`admin.auth().deleteUser`) — there is no client-side
  // equivalent; the Firebase client SDK can only ever delete the
  // CURRENTLY signed-in user's own account. If that person signs back in,
  // createUserIfNotExists() will recreate their profile, same as the
  // original Cloud Function's documented behavior when this flag wasn't
  // used. If you need to permanently block someone from signing back in,
  // remove them from the @akesp.net allow-list instead, or revoke access
  // manually from the Firebase Auth console.
  // ---------------------------------------------------------------------
  Future<Map<String, dynamic>> deleteTeacher(
    String teacherId, {
    bool alsoDeleteAuthAccount = false,
  }) async {
    final firestore = FirebaseFirestore.instance;

    // 1. Remove from every class's teachers[] array.
    final classesSnap = await firestore.collection('classes').get();
    for (final doc in classesSnap.docs) {
      final teachers = (doc.data()['teachers'] as List?) ?? [];
      final hasTeacher = teachers.any((t) => (t as Map)['teacherId'] == teacherId);
      if (hasTeacher) {
        final updated = teachers.where((t) => (t as Map)['teacherId'] != teacherId).toList();
        await doc.reference.update({'teachers': updated});
      }
    }

    // 2. Clear any weekly_timetables slots still pointing at them.
    final slotsSnap = await firestore
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: teacherId)
        .get();
    if (slotsSnap.docs.isNotEmpty) {
      final slotsBatch = firestore.batch();
      for (final d in slotsSnap.docs) {
        slotsBatch.update(d.reference, {'teacherId': '', 'teacherName': ''});
      }
      await slotsBatch.commit();
    }

    // 3. Delete the profile itself.
    await firestore.collection('users').doc(teacherId).delete();

    // NOTE: alsoDeleteAuthAccount can't be honored client-side; see the
    // doc comment above. Always reported false now.
    return {'ok': true, 'authAccountDeleted': false};
  }

  // ---------------------------------------------------------------------
  // clearTimetableSlot — REVERSAL NOTE: runs as a direct client write now
  // instead of the `clearTimetableSlot` Cloud Function. Removes the
  // assigned teacher from exactly ONE weekly_timetables slot (day/unit/
  // class), leaving every other slot for that teacher untouched. Backs
  // the admin timetable grid's "Clear slot / Remove teacher" popup option.
  // Enforcement that only an admin can do this now lives solely in
  // firestore.rules (weekly_timetables write: isAdmin()).
  // ---------------------------------------------------------------------
  Future<void> clearTimetableSlot(String slotId) async {
    final firestore = FirebaseFirestore.instance;
    final ref = firestore.collection('weekly_timetables').doc(slotId);
    final snap = await ref.get();
    if (!snap.exists) {
      throw Exception('Slot not found.');
    }
    final previousTeacherId = (snap.data()?['teacherId'] as String?) ?? '';

    await ref.set({
      'teacherId': '',
      'teacherName': '',
      'originalTeacherId': '',
      'type': 'permanent',
      'clearedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (previousTeacherId.isNotEmpty) {
      await NotificationService().notifyTeacher(
        teacherId: previousTeacherId,
        title: 'Timetable updated',
        body: 'You were removed from a slot on your weekly timetable.',
        type: NotificationType.classOccurring,
        data: {'slotId': slotId},
      );
    }
  }
}