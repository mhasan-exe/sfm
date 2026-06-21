import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/user_model.dart';
import 'admin_config_service.dart';

class UserService {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final FirebaseAuth auth = FirebaseAuth.instance;
  final AdminConfigService _adminConfig = AdminConfigService();

  CollectionReference<Map<String, dynamic>> get _users =>
      firestore.collection('users');

  // Create user if not exists
  Future<void> createUserIfNotExists() async {
    final user = auth.currentUser;

    if (user == null) return;

    final doc = await _users.doc(user.uid).get();

    if (!doc.exists) {
      final userModel = UserModel(
        uid: user.uid,
        name: user.displayName ?? '',
        email: user.email ?? '',
        role: 'teacher',
        isAdmin: false,
        defaultUnits: 0,
        fixtureUnits: 0,
        photoUrl: user.photoURL,
        bio: '',
      );

      await _users.doc(user.uid).set(userModel.toMap());
    }
  }

  // Get current user profile
  Future<UserModel?> getCurrentUserProfile() async {
    final user = auth.currentUser;
    if (user == null) return null;

    final doc = await _users.doc(user.uid).get();
    if (!doc.exists) return null;

    return UserModel.fromMap(doc.data()!);
  }

  // Get specific user profile
  Future<UserModel?> getUserProfile(String uid) async {
    final doc = await _users.doc(uid).get();
    if (!doc.exists) return null;

    return UserModel.fromMap(doc.data()!);
  }

  // Update user profile
  Future<void> updateUserProfile({
    required String uid,
    String? name,
    String? bio,
    String? photoUrl,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (bio != null) updates['bio'] = bio;
    if (photoUrl != null) updates['photoUrl'] = photoUrl;

    if (updates.isNotEmpty) {
      await _users.doc(uid).update(updates);
    }
  }

  // Stream all teachers
  Stream<List<UserModel>> watchTeachers() {
    return _users
        .where('role', isEqualTo: 'teacher')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => UserModel.fromMap(doc.data()))
          .toList();
    });
  }

  // One-shot fetch of every teacher — used by broadcast/announcement flows
  // that need the full roster regardless of current workload.
  Future<List<UserModel>> getAllTeachers() async {
    final snapshot = await _users.where('role', isEqualTo: 'teacher').get();
    return snapshot.docs.map((doc) => UserModel.fromMap(doc.data())).toList();
  }

  // Stream all users
  Stream<List<UserModel>> watchAllUsers() {
    return _users.snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => UserModel.fromMap(doc.data()))
          .toList();
    });
  }

  // Get teacher workload
  Future<Map<String, dynamic>> getTeacherWorkload(String uid) async {
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
    final doc = await _users.doc(uid).get();
    if (!doc.exists) {
      return {'defaultUnits': 0, 'fixtureUnits': 0, 'totalUnits': 0, 'availableSlots': maxUnits, 'maxUnits': maxUnits};
    }

    final user = doc.data()!;
    final defaultUnits = user['defaultUnits'] as int? ?? 0;
    final fixtureUnits = user['fixtureUnits'] as int? ?? 0;

    return {
      'defaultUnits': defaultUnits,
      'fixtureUnits': fixtureUnits,
      'totalUnits': defaultUnits + fixtureUnits,
      'availableSlots': maxUnits - (defaultUnits + fixtureUnits),
      'maxUnits': maxUnits,
    };
  }

  // Stream teacher workload. Re-reads the configurable quota each time the
  // user doc changes — cheap, and means a Settings change is reflected on
  // the next snapshot without the screen needing a manual refresh.
  Stream<Map<String, dynamic>> watchTeacherWorkload(String uid) {
    return _users.doc(uid).snapshots().asyncMap((doc) async {
      final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
      if (!doc.exists) {
        return {
          'defaultUnits': 0,
          'fixtureUnits': 0,
          'totalUnits': 0,
          'availableSlots': maxUnits,
          'maxUnits': maxUnits,
        };
      }

      final user = doc.data()!;
      final defaultUnits = user['defaultUnits'] as int? ?? 0;
      final fixtureUnits = user['fixtureUnits'] as int? ?? 0;

      return {
        'defaultUnits': defaultUnits,
        'fixtureUnits': fixtureUnits,
        'totalUnits': defaultUnits + fixtureUnits,
        'availableSlots': maxUnits - (defaultUnits + fixtureUnits),
        'maxUnits': maxUnits,
      };
    });
  }

  // Get free teachers (available for fixtures)
  Future<List<UserModel>> getAvailableTeachers({int? maxUnitsPerTeacher}) async {    final maxUnits = maxUnitsPerTeacher ?? await _adminConfig.getMaxUnitsPerTeacher();
    final snapshot = await _users
        .where('role', isEqualTo: 'teacher')
        .get();

    final available = <UserModel>[];

    for (final doc in snapshot.docs) {
      final user = UserModel.fromMap(doc.data());
      final workload = user.defaultUnits + user.fixtureUnits;

      if (workload < maxUnits) {
        available.add(user);
      }
    }

    return available;
  }

  // Get teachers by workload (for recommendations)
  Future<List<Map<String, dynamic>>> getTeachersByWorkload() async {
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
    final snapshot = await _users
        .where('role', isEqualTo: 'teacher')
        .get();

    final teachers = <Map<String, dynamic>>[];

    for (final doc in snapshot.docs) {
      final user = UserModel.fromMap(doc.data());
      final workload = user.defaultUnits + user.fixtureUnits;

      teachers.add({
        'uid': user.uid,
        'name': user.name,
        'email': user.email,
        'defaultUnits': user.defaultUnits,
        'fixtureUnits': user.fixtureUnits,
        'totalUnits': workload,
        'availableSlots': maxUnits - workload,
        'maxUnits': maxUnits,
      });
    }

    // Sort by available slots (descending)
    teachers.sort((a, b) =>
        (b['availableSlots'] as int).compareTo(a['availableSlots'] as int));

    return teachers;
  }

  // Reset teacher workload
  Future<void> resetTeacherWorkload(String uid) async {
    await _users.doc(uid).update({
      'defaultUnits': 0,
      'fixtureUnits': 0,
      'lastResetAt': FieldValue.serverTimestamp(),
    });
  }

  // Batch reset all teacher workloads
  Future<void> resetAllTeacherWorkloads() async {
    final snapshot = await _users
        .where('role', isEqualTo: 'teacher')
        .get();

    final batch = firestore.batch();

    for (final doc in snapshot.docs) {
      batch.update(doc.reference, {
        'defaultUnits': 0,
        'fixtureUnits': 0,
        'lastResetAt': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  // Get teacher schedule summary
  Future<Map<String, dynamic>> getTeacherScheduleSummary(String uid) async {
    // Get weekly timetable slots
    final weeklySnapshot = await firestore
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: uid)
        .get();

    // Get fixture slots
    final fixturesSnapshot = await firestore
        .collection('fixtures')
        .where('assignedTeacherId', isEqualTo: uid)
        .get();

    final days = <String, int>{};
    
    for (final doc in weeklySnapshot.docs) {
      final data = doc.data();
      final day = data['day'] as String;
      days[day] = (days[day] ?? 0) + 1;
    }

    for (final doc in fixturesSnapshot.docs) {
      final data = doc.data();
      final day = data['day'] as String;
      days[day] = (days[day] ?? 0) + 1;
    }

    return {
      'weeklySlots': weeklySnapshot.size,
      'fixtureSlots': fixturesSnapshot.size,
      'totalSlots': weeklySnapshot.size + fixturesSnapshot.size,
      'slotsByDay': days,
    };
  }

  // Mark teacher as absent
  Future<void> markTeacherAbsent({
    required String uid,
    required DateTime date,
    required String reason,
  }) async {
    await firestore.collection('absences').add({
      'teacherId': uid,
      'date': Timestamp.fromDate(date),
      'reason': reason,
      'markedAt': FieldValue.serverTimestamp(),
    });
  }

  // Get teacher absences
  Stream<List<Map<String, dynamic>>> watchTeacherAbsences(String uid) {
    return firestore
        .collection('absences')
        .where('teacherId', isEqualTo: uid)
        .orderBy('date', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {...data, 'id': doc.id};
      }).toList();
    });
  }
}
