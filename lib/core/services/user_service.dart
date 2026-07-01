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

  // ---------------------------------------------------------------------
  // Create user if not exists — hardened against concurrent logins.
  //
  // THE BUG this replaces: the old version did a plain `get()` then a
  // plain `set()`. If two logins for a brand-new account land close
  // together (two devices, a flaky reconnect that retries the sign-in
  // flow, AuthGate's own admin-seed check firing alongside the login
  // screen's call, etc), both could read "doesn't exist" before either
  // write lands. Firestore then evaluates whichever `set()` arrives
  // second, after the doc already exists, as an UPDATE rather than a
  // CREATE — and `firestore.rules`' `selfEditableUserFields()` only
  // allows a self-update to touch name/bio/photoUrl/fixtureUnits, not the
  // full profile (role, isAdmin, defaultUnits, email) a fresh-account
  // write contains. That mismatch is what surfaced as "user creation
  // fails" under concurrent logins.
  //
  // THE FIX, two layers:
  //  1. In-process queue: concurrent calls for the SAME uid within this
  //     app instance (e.g. AuthGate's admin-seed check and the login
  //     screen both triggering this around the same moment) share one
  //     in-flight Future instead of racing separate reads/writes.
  //  2. Firestore transaction: the actual existence-check-then-create
  //     happens inside a transaction, so if a genuinely separate login
  //     (a different device/session) wins the race, this transaction is
  //     told to retry by Firestore, re-reads, sees the doc now exists,
  //     and safely no-ops instead of attempting a conflicting write.
  // Safe and cheap to call on every login attempt and on every app
  // start/resume while signed in — retries with backoff on transient
  // failures (e.g. a flaky connection) rather than silently giving up
  // after one attempt.
  // ---------------------------------------------------------------------
  static final Map<String, Future<void>> _pendingCreates = {};

  Future<void> createUserIfNotExists() async {
    final user = auth.currentUser;
    if (user == null) return;

    final existing = _pendingCreates[user.uid];
    if (existing != null) {
      await existing;
      return;
    }

    final future = _createUserIfNotExistsWithRetry(user);
    _pendingCreates[user.uid] = future;
    try {
      await future;
    } finally {
      _pendingCreates.remove(user.uid);
    }
  }

  Future<void> _createUserIfNotExistsWithRetry(User user) async {
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await firestore.runTransaction((tx) async {
          final ref = _users.doc(user.uid);
          final snap = await tx.get(ref);
          if (snap.exists) return; // another concurrent login already created it

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
          tx.set(ref, userModel.toMap());
        });
        return;
      } catch (_) {
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }
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

  // ---------------------------------------------------------------------
  // Delete teacher — removes the Firestore profile AND cleans up every
  // place that referenced them, so deleting a teacher doesn't leave ghost
  // entries in class "units" config or stale assignments on the live
  // timetable.
  //
  // NOTE: this only deletes the Firestore `users/{uid}` doc. It does NOT
  // delete the underlying Firebase Auth account — that requires the Admin
  // SDK and can't be done from the client. If the same person signs back
  // in, `createUserIfNotExists()` will silently recreate their profile. To
  // permanently block them, also delete/disable the Auth account via a
  // Cloud Function (see the resyncTeachers function for the pattern), or
  // remove them from the @akesp.net allow-list.
  // ---------------------------------------------------------------------
  Future<void> deleteTeacher(String uid) async {
    // 1. Remove from every class's teachers[] array so the per-class
    // "units" config doesn't keep pointing at a deleted teacher.
    final classesSnap = await firestore.collection('classes').get();
    for (final doc in classesSnap.docs) {
      final teachers = (doc.data()['teachers'] as List?) ?? [];
      final hasTeacher = teachers.any((t) => (t as Map)['teacherId'] == uid);
      if (hasTeacher) {
        final updated = teachers.where((t) => (t as Map)['teacherId'] != uid).toList();
        await doc.reference.update({'teachers': updated});
      }
    }

    // 2. Clear any weekly_timetables slots still assigned to them so the
    // timetable doesn't keep showing a deleted teacher's name.
    final slotsSnap =
        await firestore.collection('weekly_timetables').where('teacherId', isEqualTo: uid).get();
    for (final s in slotsSnap.docs) {
      await s.reference.update({'teacherId': '', 'teacherName': ''});
    }

    // 3. Finally delete the profile itself.
    await _users.doc(uid).delete();
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

  // ---------------------------------------------------------------------
  // Live workload — REPLACES trusting the `defaultUnits` field.
  //
  // THE BUG: `defaultUnits` on the user doc is a manually-maintained
  // counter. Nothing in the app — not assignTeacher, not exchangeSlots,
  // not the generator, not preset restore — ever increments or
  // decrements it when a teacher's actual weekly_timetables assignments
  // change. The ONLY code that ever touches it is the workload-reset
  // flow, which zeroes it. So every screen reading `teacher.defaultUnits`
  // (Profiles cards, fixture-claim quota checks, the "prefer least loaded
  // teacher" sort) was reading a number with no relationship to reality —
  // usually 0 forever, since nothing ever sets it back up.
  //
  // THE FIX: compute it live from `weekly_timetables`, the actual source
  // of truth for what a teacher teaches, every time it's needed. One
  // query for the whole school's teachers at once where possible, so
  // this stays cheap even on a list screen.
  // ---------------------------------------------------------------------

  /// Every teacher's CURRENT permanent weekly unit count, computed
  /// directly from `weekly_timetables` in a single query. Use this (not
  /// `user.defaultUnits`) anywhere multiple teachers' workload is shown
  /// or compared at once (Profiles grid, "least loaded" sort, etc).
  Future<Map<String, int>> getLivePermanentUnitsForAllTeachers() async {
    final snap = await firestore.collection('weekly_timetables').get();
    final counts = <String, int>{};
    for (final doc in snap.docs) {
      final teacherId = (doc.data()['teacherId'] as String?) ?? '';
      if (teacherId.isEmpty) continue;
      counts[teacherId] = (counts[teacherId] ?? 0) + 1;
    }
    return counts;
  }

  /// Same as above for a single teacher — slightly more expensive than
  /// the bulk version if you need more than one teacher's count, but
  /// fine for a single profile/detail view.
  Future<int> getLivePermanentUnits(String uid) async {
    final snap = await firestore
        .collection('weekly_timetables')
        .where('teacherId', isEqualTo: uid)
        .get();
    return snap.docs.length;
  }

  // Get teacher workload
  Future<Map<String, dynamic>> getTeacherWorkload(String uid) async {
    final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
    final doc = await _users.doc(uid).get();
    final defaultUnits = await getLivePermanentUnits(uid);
    if (!doc.exists) {
      return {
        'defaultUnits': defaultUnits,
        'fixtureUnits': 0,
        'totalUnits': defaultUnits,
        'availableSlots': maxUnits - defaultUnits,
        'maxUnits': maxUnits,
      };
    }

    final user = doc.data()!;
    final fixtureUnits = user['fixtureUnits'] as int? ?? 0;

    return {
      'defaultUnits': defaultUnits,
      'fixtureUnits': fixtureUnits,
      'totalUnits': defaultUnits + fixtureUnits,
      'availableSlots': maxUnits - (defaultUnits + fixtureUnits),
      'maxUnits': maxUnits,
    };
  }

  // Stream teacher workload. Re-reads the configurable quota AND the live
  // permanent-units count each time the user doc changes — cheap, and
  // means both a Settings change and a schedule change are reflected on
  // the next snapshot without the screen needing a manual refresh. Note:
  // this only re-fires on a `users/{uid}` doc change (e.g. fixtureUnits
  // changing), not on every weekly_timetables write — for a screen that
  // needs to react live to schedule edits too, prefer one-shot
  // [getTeacherWorkload] on a timer/refresh, or layer your own
  // weekly_timetables stream alongside this one.
  Stream<Map<String, dynamic>> watchTeacherWorkload(String uid) {
    return _users.doc(uid).snapshots().asyncMap((doc) async {
      final maxUnits = await _adminConfig.getMaxUnitsPerTeacher();
      final defaultUnits = await getLivePermanentUnits(uid);
      if (!doc.exists) {
        return {
          'defaultUnits': defaultUnits,
          'fixtureUnits': 0,
          'totalUnits': defaultUnits,
          'availableSlots': maxUnits - defaultUnits,
          'maxUnits': maxUnits,
        };
      }

      final user = doc.data()!;
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
  Future<List<UserModel>> getAvailableTeachers({int? maxUnitsPerTeacher}) async {
    final maxUnits = maxUnitsPerTeacher ?? await _adminConfig.getMaxUnitsPerTeacher();
    final snapshot = await _users
        .where('role', isEqualTo: 'teacher')
        .get();
    final liveUnits = await getLivePermanentUnitsForAllTeachers();

    final available = <UserModel>[];

    for (final doc in snapshot.docs) {
      final user = UserModel.fromMap(doc.data());
      final workload = (liveUnits[user.uid] ?? 0) + user.fixtureUnits;

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
    final liveUnits = await getLivePermanentUnitsForAllTeachers();

    final teachers = <Map<String, dynamic>>[];

    for (final doc in snapshot.docs) {
      final user = UserModel.fromMap(doc.data());
      final defaultUnits = liveUnits[user.uid] ?? 0;
      final workload = defaultUnits + user.fixtureUnits;

      teachers.add({
        'uid': user.uid,
        'name': user.name,
        'email': user.email,
        'defaultUnits': defaultUnits,
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

  // Reset teacher workload. Only `fixtureUnits` is meaningful to reset —
  // `defaultUnits` is no longer read from the stored field anywhere (see
  // getLivePermanentUnits above), it's always computed live from
  // weekly_timetables, so zeroing it here would do nothing except leave
  // a misleading number sitting in Firestore. The field is left alone
  // (not deleted) for any external reporting that might still reference
  // it, but the app itself never trusts it again after this fix.
  Future<void> resetTeacherWorkload(String uid) async {
    await _users.doc(uid).update({
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
