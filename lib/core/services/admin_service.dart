import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
  // deleteTeacher — runs server-side (Admin SDK) so the profile delete,
  // the per-class teachers[] cleanup, and the weekly_timetables cleanup
  // all happen together rather than as several separate client writes that
  // could partially fail. Set [alsoDeleteAuthAccount] to also revoke their
  // ability to sign back in.
  // ---------------------------------------------------------------------
  Future<Map<String, dynamic>> deleteTeacher(
    String teacherId, {
    bool alsoDeleteAuthAccount = false,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('deleteTeacher');
    final result = await callable.call({
      'teacherId': teacherId,
      'alsoDeleteAuthAccount': alsoDeleteAuthAccount,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  // ---------------------------------------------------------------------
  // clearTimetableSlot — removes the assigned teacher from exactly ONE
  // weekly_timetables slot (day/unit/class), leaving every other slot for
  // that teacher untouched. Backs the admin timetable grid's "Clear slot /
  // Remove teacher" popup option.
  // ---------------------------------------------------------------------
  Future<void> clearTimetableSlot(String slotId) async {
    final callable = FirebaseFunctions.instance.httpsCallable('clearTimetableSlot');
    await callable.call({'slotId': slotId});
  }
}