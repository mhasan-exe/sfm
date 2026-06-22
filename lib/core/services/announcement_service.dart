import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/announcement_model.dart';
import 'notification_service.dart';
import 'user_service.dart';

class AnnouncementService {
  CollectionReference<Map<String, dynamic>> get _announcements =>
      FirebaseFirestore.instance.collection('announcements');

  CollectionReference<Map<String, dynamic>> get _acks =>
      FirebaseFirestore.instance.collection('announcement_acks');

  /// Milestones (minutes before [AnnouncementModel.eventAt]) at which
  /// teachers who haven't acknowledged yet get an extra push reminder —
  /// "reminded of it until it happens". The always-visible acknowledge
  /// prompt (see [watchUnacknowledgedForUser]) is separate and persists
  /// regardless of these milestones.
  static const List<int> eventReminderOffsetsMinutes = [1440, 360, 60, 15, 0];

  Future<String> createAnnouncement({
    required String title,
    required String message,
    required String createdBy,
    required String createdByName,
    DateTime? eventAt,
  }) async {
    final type = eventAt != null ? 'event' : 'message';
    final ref = await _announcements.add(
      AnnouncementModel(
        id: '',
        title: title,
        message: message,
        type: type,
        eventAt: eventAt,
        createdBy: createdBy,
        createdByName: createdByName,
        createdAt: DateTime.now(),
        active: true,
      ).toMap(),
    );

    // Also drop a normal notification-center entry for every teacher so it
    // shows up in their bell icon / badge count too, in addition to the
    // blocking acknowledge prompt.
    final teachers = await UserService().getAllTeachers();
    for (final t in teachers) {
      await NotificationService().notifyTeacher(
        teacherId: t.uid,
        title: eventAt != null ? '📅 $title' : '📢 $title',
        body: message,
        type: NotificationType.adminNotification,
        data: {'announcementId': ref.id},
      );
    }

    return ref.id;
  }

  Future<void> endAnnouncement(String id) async {
    await _announcements.doc(id).set({'active': false}, SetOptions(merge: true));
  }

  Future<void> deleteAnnouncement(String id) async {
    await _announcements.doc(id).delete();
    final acks = await _acks.where('announcementId', isEqualTo: id).get();
    for (final doc in acks.docs) {
      await doc.reference.delete();
    }
  }

  Stream<List<AnnouncementModel>> watchAllAnnouncements() {
    return _announcements.snapshots().map((snap) {
      final list = snap.docs
          .map((d) => AnnouncementModel.fromMap(d.id, d.data()))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Every announcement still active and NOT yet acknowledged by [uid] —
  /// the teacher-facing app shows the first of these as a blocking prompt
  /// until it's acknowledged, then moves to the next.
  Stream<List<AnnouncementModel>> watchUnacknowledgedForUser(String uid) {
    return _announcements
        .where('active', isEqualTo: true)
        .snapshots()
        .asyncMap((snap) async {
      if (snap.docs.isEmpty) return <AnnouncementModel>[];

      final ackedSnap =
          await _acks.where('uid', isEqualTo: uid).get();
      final ackedIds = ackedSnap.docs
          .map((d) => d.data()['announcementId']?.toString() ?? '')
          .toSet();

      final list = snap.docs
          .where((d) => !ackedIds.contains(d.id))
          .map((d) => AnnouncementModel.fromMap(d.id, d.data()))
          .toList();
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return list;
    });
  }

  Future<void> acknowledge(String announcementId, String uid, String name) async {
    await _acks.doc('${announcementId}_$uid').set({
      'announcementId': announcementId,
      'uid': uid,
      'name': name,
      'ackedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<List<Map<String, dynamic>>> getAcknowledgements(String announcementId) async {
    final snap = await _acks.where('announcementId', isEqualTo: announcementId).get();
    return snap.docs.map((d) => d.data()).toList();
  }

  /// Counts how many of the currently-known teachers have acknowledged —
  /// used by the admin list to show "12/30 acknowledged".
  Future<int> getAcknowledgementCount(String announcementId) async {
    final snap = await _acks.where('announcementId', isEqualTo: announcementId).get();
    return snap.docs.length;
  }

  /// Periodic housekeeping (called from the same global ticker that runs
  /// class/break-duty reminders): for every active event announcement
  /// whose time hasn't passed yet, pushes a reminder to [uid] at each
  /// milestone in [eventReminderOffsetsMinutes] — but only if they haven't
  /// acknowledged it yet. Once the event time passes, reminders stop
  /// (the acknowledge prompt itself may still show until dismissed).
  Future<void> runEventReminderSweep(String uid) async {
    try {
      // Single equality filter (`type`) + client-side filtering for
      // `active` — this is a brand-new collection in every school's
      // Firebase project, so there's no pre-existing composite index for
      // a two-field query like (active, type). Filtering one field here
      // guarantees this never silently breaks on a fresh deployment.
      final snap = await _announcements.where('type', isEqualTo: 'event').get();
      final activeDocs = snap.docs.where((d) => d.data()['active'] == true).toList();
      if (activeDocs.isEmpty) return;

      final ackedSnap = await _acks.where('uid', isEqualTo: uid).get();
      final ackedIds = ackedSnap.docs
          .map((d) => d.data()['announcementId']?.toString() ?? '')
          .toSet();

      final now = DateTime.now();
      for (final doc in activeDocs) {
        if (ackedIds.contains(doc.id)) continue;
        final announcement = AnnouncementModel.fromMap(doc.id, doc.data());
        final eventAt = announcement.eventAt;
        if (eventAt == null || now.isAfter(eventAt)) continue;

        for (final offset in eventReminderOffsetsMinutes) {
          final triggerAt = eventAt.subtract(Duration(minutes: offset));
          final secondsSinceTrigger = now.difference(triggerAt).inSeconds;
          if (secondsSinceTrigger < 0 || secondsSinceTrigger > 90) continue;

          final dedupeKey = '${uid}_event_${doc.id}_$offset';
          final already = await FirebaseFirestore.instance
              .collection('reminder_log')
              .doc(dedupeKey)
              .get();
          if (already.exists) continue;

          await FirebaseFirestore.instance.collection('reminder_log').doc(dedupeKey).set({
            'uid': uid,
            'sentAt': FieldValue.serverTimestamp(),
          });

          final label = offset >= 1440
              ? '1 day'
              : offset >= 60
                  ? '${offset ~/ 60}h'
                  : offset == 0
                      ? 'now'
                      : '${offset}m';

          await NotificationService().notifyTeacher(
            teacherId: uid,
            title: offset == 0 ? '📅 ${announcement.title} is starting' : '📅 ${announcement.title} in $label',
            body: announcement.message,
            type: NotificationType.adminNotification,
            data: {'announcementId': doc.id},
          );
        }
      }
    } catch (_) {
      // Background housekeeping — never let it surface to the user.
    }
  }
}
