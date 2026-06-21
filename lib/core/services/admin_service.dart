import 'package:cloud_firestore/cloud_firestore.dart';
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
}