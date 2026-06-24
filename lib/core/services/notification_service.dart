import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:timezone/timezone.dart' as tz;
import 'dart:io';

import 'web_notifier.dart';

enum NotificationType {
  classReminder,
  classOccurring,
  leaveApproved,
  leaveRejected,
  fixtureAvailable,
  fixtureClaimed,
  fixtureAssigned,
  fixtureExpired,
  absenceMarked,
  adminNotification,
  breakDuty,
  timetableChangePermanent,
  timetableChangeTemporary,
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _initialized = false;

  /// How many minutes before a unit starts to send a "coming up" reminder.
  /// Configurable from System Settings; defaults to 30 and 15 minutes,
  /// matching the "periodic 15-30 minute reminders" requirement.
  List<int> reminderOffsetsMinutes = const [30, 15];

  Future<void> initialize() async {
    if (_initialized) return;

    // Request permissions (works on Android/iOS/web; safe no-op on desktop).
    try {
      await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
    } catch (_) {
      // ignore — some platforms (e.g. plain desktop without FCM wiring)
      // don't support this and shouldn't block app startup.
    }

    if (kIsWeb) {
      // Browser/PC notifications go through the Notification Web API.
      await requestWebNotificationPermission();
    }

    // Subscribe to baseline topics (best-effort; no backend required for subscription)
    try {
      final user = _auth.currentUser;
      if (user != null) {
        final userDoc = await _firestore.collection('users').doc(user.uid).get();
        final role = userDoc.data()?['role']?.toString();
        if (role == 'teacher') {
          await _messaging.subscribeToTopic('teachers');
        } else {
          await _messaging.subscribeToTopic('students');
        }
      }
    } catch (_) {
      // ignore
    }

    // flutter_local_notifications targets Android/iOS only here — web/PC
    // gets its popups from web_notifier.dart instead.
    if (!kIsWeb) {
      try {
        const androidSettings =
            AndroidInitializationSettings('@mipmap/ic_launcher');
        const iosSettings = DarwinInitializationSettings();
        const settings = InitializationSettings(
          android: androidSettings,
          iOS: iosSettings,
        );

        await _localNotifications.initialize(
          settings,
          onDidReceiveNotificationResponse: _onNotificationTapped,
        );
      } catch (_) {
        // Local notification plugin not available on this platform/build —
        // FCM + in-app notification center still work without it.
      }
    }

    // FCM message handlers
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(_handleBackgroundMessage);
    }

    _initialized = true;
  }

  // Schedule reminder notifications (30, 20, 15, 10, 5 minutes before and at class time)
  Future<void> scheduleClassReminders({
    required String classId,
    required String className,
    required DateTime classStartTime,
    required String unitName,
  }) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    final now = DateTime.now();
    final reminders = [
      (minutes: 30, title: 'Class in 30 minutes'),
      (minutes: 20, title: 'Class in 20 minutes'),
      (minutes: 15, title: 'Class in 15 minutes'),
      (minutes: 10, title: 'Class in 10 minutes'),
      (minutes: 5, title: 'Class in 5 minutes'),
      (minutes: 0, title: 'Class occurring now'),
    ];

    for (final reminder in reminders) {
      final reminderTime =
          classStartTime.subtract(Duration(minutes: reminder.minutes));

      if (reminderTime.isAfter(now)) {
        await _scheduleLocalNotification(
          id: '${classId}_${reminder.minutes}'.hashCode,
          title: reminder.title,
          body: '$className - $unitName',
          scheduledTime: reminderTime,
          payload: {
            'type': NotificationType.classReminder.toString(),
            'classId': classId,
            'className': className,
          },
        );
      }
    }

    // Log this scheduling event
    await _logNotificationEvent(
      action: 'scheduled_class_reminders',
      details: {
        'classId': classId,
        'className': className,
        'startTime': classStartTime.toIso8601String(),
      },
    );
  }

  // Cancel reminders for a class
  Future<void> cancelClassReminders(String classId) async {
    if (kIsWeb) return; // nothing was zoned-scheduled on web
    final reminderMinutes = [30, 20, 15, 10, 5, 0];
    for (final minutes in reminderMinutes) {
      final id = '${classId}_$minutes'.hashCode;
      await _localNotifications.cancel(id);
    }
  }

  // Send notification to teacher
  Future<void> notifyTeacher({
    required String teacherId,
    required String title,
    required String body,
    required NotificationType type,
    Map<String, dynamic>? data,
  }) async {
    try {
      await _firestore.collection('notifications').add({
        'userId': teacherId,
        'title': title,
        'body': body,
        'type': type.toString(),
        'data': data ?? {},
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
      });

      // Only pop a live OS notification when it's actually for the person
      // currently using this device/tab — otherwise every teacher's phone
      // would buzz for every other teacher's events.
      if (_auth.currentUser?.uid == teacherId) {
        await _sendLocalNotification(
          title: title,
          body: body,
          payload: {
            'type': type.toString(),
            ...?data,
          },
        );
      }
    } catch (e) {
      print('Error notifying teacher: $e');
    }
  }

  // Send notification to admin
  Future<void> notifyAdmins({
    required String title,
    required String body,
    required String action,
    Map<String, dynamic>? data,
  }) async {
    try {
      final admins = await _firestore.collection('admins').get();

      for (final admin in admins.docs) {
        await _firestore.collection('notifications').add({
          'userId': admin.id,
          'title': title,
          'body': body,
          'type': 'adminNotification',
          'action': action,
          'data': data ?? {},
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
        });
      }

      if (admins.docs.any((d) => d.id == _auth.currentUser?.uid)) {
        await _sendLocalNotification(
          title: title,
          body: body,
          payload: {'type': 'adminNotification', 'action': action, ...?data},
        );
      }
    } catch (e) {
      print('Error notifying admins: $e');
    }
  }

  /// Generic "anything relevant happened" notifier used by services that
  /// don't fit neatly into notifyTeacher/notifyAdmins (e.g. broadcasting a
  /// permanent vs temporary timetable change with an explicit subtype).
  Future<void> notifyTimetableChange({
    required String teacherId,
    required String className,
    required String day,
    required int unit,
    required bool isPermanent,
    String? subject,
  }) async {
    final typeLabel = isPermanent ? 'Permanent Change' : 'Temporary Change';
    await notifyTeacher(
      teacherId: teacherId,
      title: 'Timetable $typeLabel',
      body:
          '${subject != null && subject.isNotEmpty ? '$subject · ' : ''}$className on $day (unit $unit) — $typeLabel.',
      type: isPermanent
          ? NotificationType.timetableChangePermanent
          : NotificationType.timetableChangeTemporary,
      data: {
        'className': className,
        'day': day,
        'unit': unit,
        'permanent': isPermanent,
      },
    );
  }

  // Notification for fixture claim
  Future<void> notifyFixtureEvent({
    required String fixtureId,
    required String className,
    required String eventType, // 'claimed', 'expired', 'assigned'
    required String teacherName,
  }) async {
    final title = _getTitleForFixtureEvent(eventType);
    final body = '$className - $teacherName';

    await notifyAdmins(
      title: title,
      body: body,
      action: 'fixture_$eventType',
      data: {
        'fixtureId': fixtureId,
        'eventType': eventType,
      },
    );
  }

  // Watch notifications for current user
  Stream<List<Map<String, dynamic>>> watchNotifications() {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return Stream.value([]);

    // Single equality filter only (no orderBy) so this works without a
    // manually-created Firestore composite index; sorted client-side.
    return _firestore
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .limit(100)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) => {...doc.data(), 'id': doc.id}).toList();
      list.sort((a, b) {
        final ta = a['timestamp'];
        final tb = b['timestamp'];
        final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da);
      });
      return list.take(50).toList();
    });
  }

  /// Admin-only: every notification in the system, not just the admin's
  /// own. Regular teachers only ever see [watchNotifications] (their own).
  Stream<List<Map<String, dynamic>>> watchAllNotifications() {
    return _firestore
        .collection('notifications')
        .limit(200)
        .snapshots()
        .map((snapshot) {
      final list = snapshot.docs.map((doc) => {...doc.data(), 'id': doc.id}).toList();
      list.sort((a, b) {
        final ta = a['timestamp'];
        final tb = b['timestamp'];
        final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da);
      });
      return list.take(100).toList();
    });
  }



  // Mark notification as read
  Future<void> markNotificationAsRead(String notificationId) async {
    try {
      await _firestore
          .collection('notifications')
          .doc(notificationId)
          .update({'read': true});
    } catch (e) {
      print('Error marking notification as read: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Periodic reminder sweep — driven by actual Time Profile period times,
  // not hardcoded unit numbers. Call this roughly once a minute (the main
  // navigation shell does this) for the signed-in teacher. Dedupes via a
  // `reminder_log` Firestore doc so a reminder is never sent twice even if
  // the sweep runs from multiple devices/tabs for the same person.
  // ---------------------------------------------------------------------
  Future<void> runReminderSweepForTeacher(String teacherId) async {
    try {
      final now = DateTime.now();
      final dayNames = [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
      ];
      final today = dayNames[now.weekday - 1];
      final dateKey =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      // Single equality filter (`teacherId`) + client-side day/date
      // filtering — matches the safe pattern already used elsewhere in
      // this app. A two-field where() chain here would need a
      // manually-created composite index in every school's Firebase
      // project; this never does.
      final weeklySnap = await _firestore
          .collection('weekly_timetables')
          .where('teacherId', isEqualTo: teacherId)
          .get();

      // Exceptions are queried by BOTH originalTeacherId (so a slot that
      // just got vacated by this teacher's own leave correctly suppresses
      // the reminder instead of still firing for a class they're not
      // attending) and teacherId (so a slot this teacher is now covering
      // via a fixture/exchange correctly gets a reminder too).
      final exceptionsOwnSnap = await _firestore
          .collection('timetable_exceptions')
          .where('originalTeacherId', isEqualTo: teacherId)
          .get();
      final exceptionsCoveringSnap = await _firestore
          .collection('timetable_exceptions')
          .where('teacherId', isEqualTo: teacherId)
          .get();

      final byUnit = <int, Map<String, dynamic>>{};
      for (final d in weeklySnap.docs) {
        final data = d.data();
        if (data['day']?.toString() != today) continue;
        final unit = (data['unit'] as num?)?.toInt() ?? 0;
        if (unit > 0) byUnit[unit] = data;
      }
      // Own slots that were vacated by leave/exchange today — remove the
      // reminder entirely (teacherId blank means "not actually teaching").
      for (final d in exceptionsOwnSnap.docs) {
        final data = d.data();
        if (data['date']?.toString() != dateKey) continue;
        final unit = (data['unit'] as num?)?.toInt() ?? 0;
        if (unit <= 0) continue;
        final effectiveTeacher = data['teacherId']?.toString() ?? '';
        if (effectiveTeacher == teacherId) {
          byUnit[unit] = data; // still them (e.g. admin override kept them)
        } else {
          byUnit.remove(unit); // vacated or handed to someone else
        }
      }
      // Slots this teacher is now covering for someone else.
      for (final d in exceptionsCoveringSnap.docs) {
        final data = d.data();
        if (data['date']?.toString() != dateKey) continue;
        final unit = (data['unit'] as num?)?.toInt() ?? 0;
        if (unit > 0) byUnit[unit] = data;
      }

      for (final entry in byUnit.entries) {
        final data = entry.value;
        final startTime = data['startTime']?.toString() ?? '';
        final className = data['className']?.toString() ?? 'Class';
        if (startTime.isEmpty) continue;

        final start = _todayAt(startTime, now);
        if (start == null) continue;

        for (final offset in reminderOffsetsMinutes) {
          final triggerAt = start.subtract(Duration(minutes: offset));
          // Fire once the trigger time has passed but only within a 90s
          // grace window so a sweep that runs every ~60s never misses it
          // and never fires it twice.
          final secondsSinceTrigger = now.difference(triggerAt).inSeconds;
          if (secondsSinceTrigger < 0 || secondsSinceTrigger > 90) continue;

          final dedupeKey =
              '${teacherId}_${dateKey}_${entry.key}_$offset';
          final already = await _firestore
              .collection('reminder_log')
              .doc(dedupeKey)
              .get();
          if (already.exists) continue;

          await _firestore.collection('reminder_log').doc(dedupeKey).set({
            'teacherId': teacherId,
            'sentAt': FieldValue.serverTimestamp(),
          });

          await notifyTeacher(
            teacherId: teacherId,
            title: 'Class in $offset minutes',
            body: '$className starts at $startTime.',
            type: NotificationType.classReminder,
            data: {'unit': entry.key, 'startTime': startTime},
          );
        }
      }

      await _sweepBreakDutyReminders(teacherId, today, dateKey, now);
    } catch (_) {
      // Background housekeeping — never let it surface to the user.
    }
  }

  Future<void> _sweepBreakDutyReminders(
    String teacherId,
    String today,
    String dateKey,
    DateTime now,
  ) async {
    final dutySnap = await _firestore
        .collection('break_duties')
        .where('teacherIds', arrayContains: teacherId)
        .get();

    for (final doc in dutySnap.docs) {
      final data = doc.data();
      final days = data['days'] is List
          ? (data['days'] as List).map((e) => e.toString()).toList()
          : <String>[];
      if (!days.contains(today)) continue;

      final startTime = data['startTime']?.toString() ?? '';
      final name = data['name']?.toString() ?? 'Break duty';
      final start = _todayAt(startTime, now);
      if (start == null) continue;

      for (final offset in reminderOffsetsMinutes) {
        final triggerAt = start.subtract(Duration(minutes: offset));
        final secondsSinceTrigger = now.difference(triggerAt).inSeconds;
        if (secondsSinceTrigger < 0 || secondsSinceTrigger > 90) continue;

        final dedupeKey = '${teacherId}_${dateKey}_duty_${doc.id}_$offset';
        final already =
            await _firestore.collection('reminder_log').doc(dedupeKey).get();
        if (already.exists) continue;

        await _firestore.collection('reminder_log').doc(dedupeKey).set({
          'teacherId': teacherId,
          'sentAt': FieldValue.serverTimestamp(),
        });

        await notifyTeacher(
          teacherId: teacherId,
          title: 'Break duty in $offset minutes',
          body: '$name starts at $startTime.',
          type: NotificationType.breakDuty,
          data: {'breakDutyId': doc.id},
        );
      }
    }
  }

  DateTime? _todayAt(String hhmm, DateTime now) {
    final trimmed = hhmm.trim();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$').firstMatch(trimmed);
    if (match == null) return null;
    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final ampm = match.group(3);
    if (ampm != null) {
      final isPM = ampm.toUpperCase() == 'PM';
      if (hour == 12) {
        hour = isPM ? 12 : 0;
      } else {
        hour = isPM ? hour + 12 : hour;
      }
    }
    return DateTime(now.year, now.month, now.day, hour, minute);
  }

  // Private helper methods
  Future<void> _scheduleLocalNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required Map<String, String> payload,
  }) async {
    if (kIsWeb) return; // web relies on the periodic sweep instead
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _localNotifications.zonedSchedule(
          id,
          title,
          body,
          tz.TZDateTime.from(scheduledTime, tz.local),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'class_reminders',
              'Class Reminders',
              channelDescription: 'Reminders for upcoming classes',
              importance: Importance.max,
              priority: Priority.high,
              playSound: true,
              enableVibration: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentSound: true,
              presentBadge: true,
            ),
          ),
          androidAllowWhileIdle: true,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload.entries.map((e) => '${e.key}:${e.value}').join('|'),
        );
      } catch (_) {}
    }
  }

  Future<void> _sendLocalNotification({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) async {
    if (kIsWeb) {
      showWebNotification(title: title, body: body);
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        await _localNotifications.show(
          DateTime.now().hashCode,
          title,
          body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'general_notifications',
              'General Notifications',
              importance: Importance.max,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentSound: true,
            ),
          ),
          payload: payload.entries.map((e) => '${e.key}:${e.value}').join('|'),
        );
      } catch (_) {}
    }
    // Desktop (Windows/macOS/Linux) without a configured local-notification
    // channel still gets the in-app notification center entry written above
    // by the caller — that's the guaranteed-to-work fallback everywhere.
  }

  void _onNotificationTapped(NotificationResponse response) {
    print('Notification tapped: ${response.payload}');
  }

  void _handleForegroundMessage(RemoteMessage message) {
    print('Foreground message: ${message.data}');
    _sendLocalNotification(
      title: message.notification?.title ?? 'Notification',
      body: message.notification?.body ?? '',
      payload: message.data,
    );
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    print('Message opened app: ${message.data}');
  }

  static Future<void> _handleBackgroundMessage(RemoteMessage message) async {
    print('Background message: ${message.data}');
  }

  String _getTitleForFixtureEvent(String eventType) {
    switch (eventType) {
      case 'claimed':
        return 'Fixture Claimed';
      case 'expired':
        return 'Fixture Expired';
      case 'assigned':
        return 'Fixture Assigned';
      default:
        return 'Fixture Update';
    }
  }

  Future<void> _logNotificationEvent({
    required String action,
    required Map<String, dynamic> details,
  }) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      await _firestore.collection('logs').add({
        'timestamp': FieldValue.serverTimestamp(),
        'userId': userId,
        'action': action,
        'details': details,
        'type': 'notification',
      });
    } catch (e) {
      print('Error logging notification event: $e');
    }
  }
}
