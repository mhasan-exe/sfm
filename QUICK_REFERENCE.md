# 📌 QUICK REFERENCE CARD

## What Changed?

### 3 New Core Services
1. **NotificationService** - Reminders + alerts
2. **LoggingService** - Complete audit trail
3. **CacheService** - Offline-first caching

### 2 New Features  
1. **Teacher Schedule Screen** - View assignments
2. **Improved Fixture Marketplace** - Tab-based, functional

### 4 New Documentation Files
1. QUICK_START.md
2. IMPLEMENTATION_GUIDE.md
3. GOOGLE_SIGNIN_SETUP.md
4. FINAL_SUMMARY.md (plus this file)

---

## One-Command Quick Start

```bash
# 1. Install packages
flutter pub get

# 2. Run on Chrome
flutter run -d chrome

# 3. Login with Google
# 4. Click "Schedule" tab to see your classes
# 5. Click "Fixtures" tab to claim units
# 6. Check Firebase → audit_trail to see logged actions
```

---

## Key Files Location

| Feature | File |
|---------|------|
| **Notifications** | `lib/core/services/notification_service.dart` |
| **Audit Trail** | `lib/core/services/logging_service.dart` |
| **Caching** | `lib/core/services/cache_service.dart` |
| **Schedule View** | `lib/features/timetable/teacher_timetable_screen.dart` |
| **Marketplace** | `lib/features/fixtures/fixture_marketplace_screen.dart` |

---

## 5-Minute Test Workflow

1. **Login Screen**
   - Click "Continue with Google"
   - Use @akesp.net email
   - See home dashboard

2. **Schedule Tab**
   - Shows today's classes with countdown
   - See weekly schedule below
   - See workload stats (units)

3. **Fixtures Tab**
   - Shows available fixtures to claim
   - Click "Claim Now"
   - See "My Claims" tab
   - See history

4. **Check Logging**
   - Firebase Console
   - Firestore → Collections → audit_trail
   - See all actions logged with timestamps

5. **Check Caching**
   - Turn off internet
   - App still works (shows cached data)
   - Turn on internet
   - Auto-syncs

---

## Common Tasks

### View Notifications
```
Firebase Console → Firestore → notifications collection
Filter by userId to see teacher's notifications
```

### View Audit Trail
```
Firebase Console → Firestore → audit_trail collection
See all actions: teacher_assigned, fixture_claimed, leave_approved, etc.
```

### Clear Cache
```dart
// In code:
await CacheService().clearAllCache();

// Then:
// Kill and restart app
// Fetches fresh data from Firestore
```

### Schedule Reminders for a Class
```dart
// In admin or trigger function:
await NotificationService().scheduleClassReminders(
  classId: 'cls_001',
  className: 'Class 10-A',
  classStartTime: DateTime.now().add(Duration(hours: 2)),
  unitName: 'Math - Unit 3'
);
```

---

## Notification Types

| Type | Who Gets It | When |
|------|-----------|------|
| Class Reminder | Teacher | 30, 20, 15, 10, 5 min before + at start |
| Fixture Claimed | Admin | When teacher claims fixture |
| Fixture Expired | Admin | When fixture expires unclaimed |
| Leave Approved | Teacher | When leave request approved |
| Leave Rejected | Teacher | When leave request rejected |

---

## Audit Log Levels

| Level | Color | Examples |
|-------|-------|----------|
| **info** | Blue | teacher_assigned, fixture_claimed |
| **warning** | Orange | absence_marked, leave_rejected |
| **critical** | Red | config_changed, admin permissions updated |

---

## Firebase Collections Reference

### notifications/
```json
{
  "userId": "teacher_123",
  "title": "Class in 15 minutes",
  "body": "Class 10-A - Unit 3",
  "type": "classReminder",
  "timestamp": 1717225442000,
  "read": false
}
```

### audit_trail/
```json
{
  "userId": "teacher_123",
  "userEmail": "ahmed@akesp.net",
  "action": "fixture_claimed",
  "description": "Class 10-A - Ahmed claimed fixture",
  "level": "info",
  "timestamp": 1717225442000,
  "details": {
    "fixtureId": "fix_123",
    "className": "Class 10-A"
  }
}
```

### logs/
Same structure as audit_trail (maintains real-time log copy)

---

## Environment Variables/Config

### Email Domain
**Files:** `auth_gate.dart`, `auth_service.dart`
**Current:** `@students.akesp.net`
**To Change:** Search for "students.akesp.net" and replace

### Notification Timings
**File:** `notification_service.dart` line ~79
**Current:** 30, 20, 15, 10, 5 minutes
**To Change:** Edit the reminders array

### Fixture Expiry Window
**File:** `fixture_service.dart`
**Current:** 1 hour before class
**To Change:** Find `_calculateExpireTime()` method

---

## Troubleshooting 60-Second Fixes

| Problem | Fix |
|---------|-----|
| App won't start | Run `flutter clean` then `flutter pub get` |
| Console errors | Check `lib/main.dart` - imports correct? |
| No schedule shown | Check if you have weekly_timetable entries in Firebase |
| Fixtures tab empty | Check if fixtures collection has documents |
| Notifications don't work | Run app online first to subscribe to topics |
| Logout doesn't work | Check auth_service.dart signOut() method |

---

## Testing Checklist

- [ ] App loads on Chrome
- [ ] Can login with Google
- [ ] Schedule tab shows classes
- [ ] Fixtures tab loads
- [ ] Can claim fixture (button works)
- [ ] Firebase audit_trail has entries
- [ ] Can view notifications in Firebase
- [ ] No red errors in console

---

## Before Deploying APK

- [ ] Read GOOGLE_SIGNIN_SETUP.md completely
- [ ] Get SHA-1 fingerprint
- [ ] Add SHA-1 to Firebase
- [ ] Download new google-services.json
- [ ] Update android/app/build.gradle
- [ ] Test on device
- [ ] Build release APK
- [ ] Sign APK with keystore

---

## API/Method Reference

### Notification
```dart
NotificationService().scheduleClassReminders(...)
NotificationService().notifyTeacher(...)
NotificationService().notifyAdmins(...)
NotificationService().watchNotifications()
```

### Logging
```dart
LoggingService().logAction(...)
LoggingService().logTeacherAssignment(...)
LoggingService().logLeaveSubmission(...)
LoggingService().logFixtureEvent(...)
LoggingService().getAuditLogs(...)
LoggingService().watchAuditLogs()
```

### Caching
```dart
CacheService().set/get(key, value)
CacheService().cacheTimetable(classId, slots)
CacheService().getTimetable(classId)
CacheService().clearAllCache()
```

---

## Performance Tips

1. **Reduce Network Calls**
   - Cache loaded automatically
   - Falls back to cache when offline
   - Syncs in background

2. **Improve Load Times**
   - Skeleton UI shows immediately
   - Smooth animations hide loading
   - Progressive data loading

3. **Save Battery**
   - Notifications batch together
   - Caching reduces screen-on time
   - Offline mode doesn't drain battery

---

## Security Notes

✅ All actions logged to audit_trail
✅ Email domain restriction at login
✅ Teachers see only their data
✅ Admins need auth for all operations
✅ Server-side timestamps
✅ No sensitive data in logs

---

## Support Resources

| Need | Resource |
|------|----------|
| Setup instructions | QUICK_START.md |
| Feature details | IMPLEMENTATION_GUIDE.md |
| APK build guide | GOOGLE_SIGNIN_SETUP.md |
| Architecture overview | FINAL_SUMMARY.md |
| This reference | THIS FILE |

---

## Status Dashboard

| Component | Status | Tested | Docs |
|-----------|--------|--------|------|
| Notifications | ✅ Complete | ⚠️ Logic | ✅ |
| Logging | ✅ Complete | ✅ Verified | ✅ |
| Caching | ✅ Complete | ⚠️ Logic | ✅ |
| Schedule View | ✅ Complete | ✅ Visual | ✅ |
| Marketplace | ✅ Complete | ✅ Visual | ✅ |
| Google Sign-In | ✅ Complete | ⚠️ APK pending | ✅ |
| Admin Pages | ✅ Created | ⚠️ Needs work | ✅ |

---

## Quick Links

- 📚 Full Docs: `IMPLEMENTATION_GUIDE.md`
- 🚀 Get Started: `QUICK_START.md`
- 🔐 Sign-In Guide: `GOOGLE_SIGNIN_SETUP.md`
- 📊 Complete Info: `FINAL_SUMMARY.md`

---

**Last Updated:** June 1, 2026
**Status:** Ready for Testing ✅
**Questions?** Check the docs above!
