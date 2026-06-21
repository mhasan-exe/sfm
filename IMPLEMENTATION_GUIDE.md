# AKESP Timetable System - Complete Implementation Guide

## 🚀 What's New in This Update

### ✅ COMPLETED FEATURES

#### 1. **Comprehensive Notification System**
- Local notifications for class reminders (30, 20, 15, 10, 5 minutes before + at class time)
- Firebase Cloud Messaging (FCM) for admin notifications
- Real-time notification stream in Firebase
- Fixture marketplace event notifications (claimed, expired, assigned)
- Leave approval/rejection notifications

**Location**: `lib/core/services/notification_service.dart`

#### 2. **Complete Logging & Audit Trail System**
- All actions logged with timestamps
- Admin-level action tracking
- Leave, fixture, timetable changes fully audited
- Real-time audit log viewing for admins
- Activity summaries by user and action type
- Critical level flagging for sensitive operations

**Location**: `lib/core/services/logging_service.dart`

#### 3. **Intelligent Caching System**
- Offline-first architecture with SharedPreferences
- Cached: time profiles, classes, timetables, teachers, fixtures, leaves
- Cache invalidation and manual refresh
- Fallback to cached data when offline

**Location**: `lib/core/services/cache_service.dart`

#### 4. **Teacher Timetable Viewing Screen**
- Live view of assigned classes (pulls from temporary_timetable after exchanges)
- Today's classes highlighted with countdown to start
- Weekly schedule view grouped by day
- Real-time unit workload tracking
- Skeleton loading while fetching
- Smooth animations on all elements

**Location**: `lib/features/timetable/teacher_timetable_screen.dart`

#### 5. **Fully Functional Fixture Marketplace**
- Real-time available fixtures display
- Claim/release functionality with instant feedback
- 1-hour expiry countdown display
- "Expiring Soon" visual alerts (< 10 minutes)
- My Claims tab showing currently claimed fixtures
- History tab showing past claims
- Tab-based interface with smooth transitions
- Admin notifications when fixtures are claimed

**Location**: `lib/features/fixtures/fixture_marketplace_screen.dart`

#### 6. **Live Animation & Skeleton Loading**
- All screens use flutter_animate for smooth transitions
- Skeleton UI loading states (skeletonizer package)
- Staggered animations for lists
- Glass morphism card effects
- Responsive design for mobile and desktop

#### 7. **Google Sign In Complete Setup Guide**
- Android SHA-1 fingerprint generation instructions
- Release APK keystore configuration
- Firebase Console configuration steps
- Web client ID setup for localhost and production
- Troubleshooting guide for common errors
- Mobile and web specific instructions

**Location**: `GOOGLE_SIGNIN_SETUP.md`

### 📁 NEW FILES CREATED

```
lib/core/services/
  ├── notification_service.dart (NEW - Notifications + reminders)
  ├── logging_service.dart (NEW - Audit trail)
  └── cache_service.dart (NEW - Offline caching)

lib/features/
  ├── timetable/
  │   └── teacher_timetable_screen.dart (NEW - Teacher schedule view)
  └── fixtures/
      └── fixture_marketplace_screen.dart (COMPLETELY REWRITTEN)

GOOGLE_SIGNIN_SETUP.md (NEW - Complete setup guide)
```

### 🔄 UPDATED FILES

```
pubspec.yaml
  - Added: flutter_local_notifications, shared_preferences, connectivity_plus, timezone

lib/main.dart
  - Initialize NotificationService and CacheService on startup

lib/features/navigation/main_navigation_screen.dart
  - Added Schedule tab with TeacherTimetableScreen
  - Reordered navigation items
```

## 🛠️ How to Use

### 1. **Initialize Services** ✅ (Already Done)
```dart
// In main.dart - automatically called
await CacheService().initialize();
await NotificationService().initialize();
```

### 2. **Setup Google Sign In** (MUST DO BEFORE APK)

#### For Web Testing (localhost)
```bash
flutter run -d chrome
# No additional setup needed - Firebase handles localhost
```

#### For Android APK
1. Get your debug SHA-1:
   ```bash
   keytool -list -v -keystore "%USERPROFILE%\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
   ```

2. Go to Firebase Console → Project Settings → Your Apps → Android
3. Add SHA-1 fingerprint
4. Download new `google-services.json`
5. Place in `android/app/google-services.json`

See `GOOGLE_SIGNIN_SETUP.md` for complete APK release instructions.

### 3. **Enable Notifications**

#### Android Setup
Add to `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

#### iOS Setup
Add to `ios/Runner/Info.plist`:
```xml
<key>UIUserInterfaceStyle</key>
<string>Dark</string>
```

### 4. **Test All Features**

#### A. Teacher Schedule Viewing
1. Login as teacher
2. Go to "Schedule" tab
3. See today's classes with countdown
4. See weekly schedule grouped by day
5. See workload stats (default units, fixture units, total)

#### B. Fixture Marketplace
1. Go to "Fixtures" tab
2. Available fixtures show with expiry countdown
3. Click "Claim Now" to claim
4. Go to "My Claims" to see claimed fixtures
5. Click "Release Claim" to release
6. Go to "History" to see past actions

#### C. Notifications & Logging
1. Check Firebase → Logs collection for all actions
2. Check Firebase → Audit Trail for complete history
3. Check Firebase → Notifications for user notifications

### 5. **Offline Support**

When offline:
- App shows cached data
- All recent timetable/fixture data available
- User is notified of offline status
- When back online, data auto-syncs

## 📊 Firebase Collections Needed

### New Collections (Auto-created)
```
notifications/
  - userId (string)
  - title (string)
  - body (string)
  - type (string)
  - data (map)
  - timestamp (timestamp)
  - read (boolean)

logs/
  - userId (string)
  - action (string)
  - description (string)
  - timestamp (timestamp)
  - details (map)
  - level (string: info|warning|critical)

audit_trail/ (copy of logs for compliance)
  - (same structure as logs)
```

### Existing Collections Updated
```
temporary_timetable/
  - used for real-time teacher assignments

weekly_timetables/
  - used for schedule viewing

fixtures/
  - updated with notification triggers

users/
  - tracks workload (defaultUnits, fixtureUnits, totalUnits)
```

## 🎨 UI/UX Improvements

✅ Skeleton loading on all data-fetching screens
✅ Smooth fade-in and slide animations
✅ Glass morphism cards for modern look
✅ Color-coded status indicators
✅ Live countdown timers
✅ Responsive layout for mobile/desktop
✅ Error handling with SnackBar feedback
✅ Loading indicators for async operations
✅ Tab-based navigation for Marketplace

## 🚀 Running the App

### Web (Chrome)
```bash
cd c:\Users\muham\Desktop\SFM\sfm
flutter run -d chrome
```

### Android (Device/Emulator)
```bash
# First time
flutter pub get

# Run
flutter run

# Release APK
flutter build apk --release
```

### iOS (Mac only)
```bash
flutter run -d ios
```

## ⚙️ Configuration

### Change Email Domain
Edit these files to change from `@akesp.net`:
- `lib/features/auth/auth_gate.dart` - seed admin check
- `lib/core/services/auth_service.dart` - email validation

### Change Notification Timings
Edit `lib/core/services/notification_service.dart`:
```dart
final reminders = [
  (minutes: 30, title: 'Class in 30 minutes'),
  (minutes: 20, title: 'Class in 20 minutes'),
  // ... adjust as needed
];
```

### Change Fixture Expiry Window
Edit `lib/core/services/fixture_service.dart`:
```dart
// Search for "1 hour before" and adjust calculation
// Currently set to 1 hour before class start
```

## 📱 Tested On

- ✅ Chrome (Web)
- ⚠️ Android (needs APK build with SHA-1)
- ⚠️ iOS (needs provisioning)

## 🐛 Known Issues & Solutions

### Issue: "Configuration Problem" on Android APK
**Solution**: Ensure SHA-1 fingerprint is registered in Firebase Console

### Issue: Pop-up appears when signing in on desktop
**Solution**: Normal security behavior - users can disable pop-up blocker if needed

### Issue: Notifications not appearing
**Solution**: 
- Check Firebase Cloud Messaging is enabled
- Check `AndroidManifest.xml` has correct permissions
- On Android 13+, check notification permission is granted

### Issue: Offline mode shows no data
**Solution**: This is expected - app caches data as you use it. After first full sync online, offline mode will show cached data.

## 📋 Checklist Before Production

- [ ] SHA-1 fingerprints registered (debug and release)
- [ ] Release keystore configured
- [ ] Email domain updated to your organization
- [ ] Firebase collections created (auto-creates on first use)
- [ ] Google Cloud Console OAuth configured
- [ ] Authorized domains added to Firebase
- [ ] APK tested on real device
- [ ] Notifications tested and working
- [ ] Offline mode tested with caching
- [ ] All user workflows tested end-to-end

## 📞 Quick Support

### Check these files first
1. Notifications not working → `lib/core/services/notification_service.dart`
2. Logging not working → `lib/core/services/logging_service.dart`
3. Sign In issues → `GOOGLE_SIGNIN_SETUP.md`
4. Cache issues → `lib/core/services/cache_service.dart`
5. UI not updating → Check if Stream vs Future is correct

### Enable Debug Logging
Add to `lib/main.dart`:
```dart
if (kDebugMode) {
  FirebaseFirestore.instance.settings = Settings(
    persistenceEnabled: true,
  );
}
```

## 🎯 Next Steps

1. **Run the app**: `flutter run -d chrome`
2. **Test teacher schedule**: Go to Schedule tab
3. **Test fixture claiming**: Go to Fixtures tab
4. **Check logging**: View Firebase Logs collection
5. **Test notifications**: Create test events and check
6. **Build APK**: Follow GOOGLE_SIGNIN_SETUP.md
7. **Test on device**: Install APK and verify all features

## 📚 Architecture Overview

```
App Structure:
├── lib/
│   ├── core/
│   │   ├── services/ (Business logic)
│   │   │   ├── auth_service.dart
│   │   │   ├── timetable_service.dart
│   │   │   ├── fixture_service.dart
│   │   │   ├── leave_service.dart
│   │   │   ├── user_service.dart
│   │   │   ├── admin_config_service.dart
│   │   │   ├── notification_service.dart (NEW)
│   │   │   ├── logging_service.dart (NEW)
│   │   │   └── cache_service.dart (NEW)
│   │   ├── widgets/ (Reusable UI components)
│   │   ├── theme/
│   │   └── utils/
│   ├── models/ (Data classes)
│   ├── features/ (Feature screens)
│   │   ├── auth/
│   │   ├── home/
│   │   ├── timetable/ (NEW)
│   │   ├── fixtures/ (UPDATED)
│   │   ├── profiles/
│   │   ├── admin/
│   │   └── navigation/
│   └── main.dart
```

## 🔐 Security Notes

- All sensitive operations logged to audit_trail
- Teachers can only see their own assignments
- Admins need authentication for all operations
- Email domain restriction enforced at login
- All timestamps server-generated for accuracy

---

**Version**: 1.0.0+1
**Last Updated**: June 1, 2026
**Status**: Ready for Testing ✅
