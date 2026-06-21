import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AuditLogService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  AuditLogService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Writes into `audit_logs`.
  /// Schema (simple + queryable):
  /// - action: string
  /// - adminId/performedBy: string
  /// - timestamp: serverTimestamp
  /// - details: Map payload
  Future<void> log({
    required String action,
    Map<String, dynamic>? details,
  }) async {
    final adminId = _auth.currentUser?.uid;
    if (adminId == null || adminId.isEmpty) return;

    await _firestore.collection('audit_logs').add({
      'action': action,
      'performedBy': adminId,
      'adminId': adminId,
      'timestamp': FieldValue.serverTimestamp(),
      'details': details ?? {},
    });
  }

  /// Streams audit logs ordered by newest first.
  /// Used by the Admin Logs dashboard.
  Stream<List<Map<String, dynamic>>> watchAuditLogs({
    int limit = 100,
  }) {
    return _firestore
        .collection('audit_logs')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => {
                ...doc.data(),
                'id': doc.id,
              })
          .toList();
    });
  }
}

