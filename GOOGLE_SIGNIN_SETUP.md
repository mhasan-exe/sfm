# Google Sign In Setup & APK Build Guide

## Prerequisites
- Flutter project with Firebase configured
- Google Cloud Console project created
- Android app registered in Firebase Console
- iOS app registered (if building for iOS)

## STEP 1: Web Configuration (for localhost testing)

### Option A: Using Firebase Hosting Localhost
No additional setup needed - Firebase handles localhost automatically.

### Option B: Using Custom Domain
1. Add your domain to "Authorized JavaScript origins" in Google Cloud Console
2. Go to Google Cloud Console → APIs & Services → Credentials
3. Edit OAuth 2.0 Client ID (Web)
4. Add to "Authorized JavaScript origins":
   ```
   https://yourdomain.com
   http://localhost:3000
   http://127.0.0.1:3000
   ```

## STEP 2: Android Configuration (for APK - MOST IMPORTANT!)

### Generating SHA-1 Fingerprint

Windows Command Prompt (run as administrator):
```bash
cd %JAVA_HOME%\bin
keytool -list -v -keystore "%USERPROFILE%\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
```

Or using Flutter directly:
```bash
flutter keytool --list -v
```

### Getting Release SHA-1 for Production APK

For production APK, generate keystore:
```bash
keytool -genkey -v -keystore your-release-key.keystore -keyalg RSA -keysize 2048 -validity 10000 -alias your-key-alias
```

Then get SHA-1:
```bash
keytool -list -v -keystore your-release-key.keystore -alias your-key-alias -storepass your-password -keypass your-password
```

### Register SHA-1 in Firebase Console

1. Go to Firebase Console → Project Settings
2. Go to "Your apps" → Android app
3. Add SHA certificate fingerprints:
   - Debug SHA-1 (for testing)
   - Release SHA-1 (for production APK)
4. Download updated `google-services.json`
5. Place in `android/app/`

### Android Build Configuration

#### android/app/build.gradle.kts
```kotlin
android {
    compileSdk = 35

    defaultConfig {
        applicationId = "com.akesp.sfm"
        minSdk = 21
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        // Add multiDexEnabled for large apps
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            storeFile = file("your-release-key.keystore")
            storePassword = "your-store-password"
            keyAlias = "your-key-alias"
            keyPassword = "your-key-password"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

#### android/app/AndroidManifest.xml
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.akesp.sfm">

    <!-- Required permissions for Google Sign In -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.GET_ACCOUNTS" />

    <application>
        <!-- Google Sign In Provider -->
        <activity
            android:name=".MainActivity"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
            <!-- Handle Google Sign In redirect -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="com.akesp.sfm" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

## STEP 3: Building Release APK

### Generate APK (unsigned)
```bash
flutter build apk --release
```

### Generate APK (signed with your keystore)
```bash
flutter build apk --release --split-per-abi
```

This generates APK files in `build/app/outputs/apk/release/`

### Verify APK Signature
```bash
jarsigner -verify -verbose build/app/outputs/apk/release/app-release.apk
```

## STEP 4: Verifying Google Sign In Configuration

### Check Client ID Configuration
Edit `lib/core/services/auth_service.dart` - ensure web config is correct:

```dart
final provider = GoogleAuthProvider();
provider.setCustomParameters({
  'prompt': 'select_account', // or 'login' for force new login
  'hd': 'akesp.net', // Optional: restrict to specific domain
});
```

### Test on Different Platforms

#### Web (Chrome)
```bash
flutter run -d chrome
```

#### Android (Device/Emulator)
```bash
flutter run
```

#### iOS (if applicable)
```bash
flutter run -d ios
```

## STEP 5: Troubleshooting

### Issue: "PlatformException: CONFIGURATION_PROBLEM"
**Solution**: Ensure SHA-1 fingerprint is registered in Firebase Console

### Issue: "Web client ID not registered"
**Solution**: 
1. Go to Google Cloud Console → APIs & Services → OAuth 2.0 Client IDs
2. Verify web client credentials exist
3. Download web client configuration if needed

### Issue: "Only AKESP accounts allowed" error on APK
**Solution**: Verify email domain in `auth_service.dart`:
```dart
if (!email.endsWith('@akesp.net')) { // Changed from @students.akesp.net
  await signOut();
  throw Exception('Only AKESP accounts are allowed.');
}
```

### Issue: "Invalid redirect_uri" on mobile
**Solution**: This is normal during OAuth flow, Google handles it internally

### Issue: Pop-up appears on desktop
**Solution**: This is expected behavior for security. Users can disable pop-up blocker if needed.

## STEP 6: Firebase Console Verification

1. Go to Firebase Console
2. Select Your Project
3. Go to Authentication → Sign-in method
4. Ensure "Google" is enabled
5. Check "Authorized domains":
   - Should include localhost for development
   - Should include your production domain
6. Download latest `google-services.json` after making changes

## STEP 7: Authorized Domains Configuration

In Firebase Console → Authentication → Settings → Authorized domains:
- Add `localhost`
- Add `127.0.0.1`
- Add `your-firebase-project.firebaseapp.com`
- Add any custom domains

## Quick Start Commands

### Full Setup for APK Release
```bash
# Get dependencies
flutter pub get

# Run analysis
flutter analyze

# Build APK
flutter build apk --release

# Build for multiple architectures
flutter build apk --release --split-per-abi

# Install on device
adb install -r build/app/outputs/apk/release/app-release.apk

# Test Google Sign In
flutter run -d chrome  # Test web
flutter run            # Test mobile
```

## Email Configuration

Update email domain restriction in:
- `lib/features/auth/auth_gate.dart` - seed admin email check
- `lib/core/services/auth_service.dart` - email domain validation

Current: `@students.akesp.net` or `@akesp.net`
Update to your actual domain.

## Next Steps After Setup

1. Test Google Sign In on Chrome: `flutter run -d chrome`
2. Build APK: `flutter build apk --release`
3. Install on Android device
4. Test complete workflow
5. If issues persist, check:
   - Firebase Console logs
   - Android Studio logcat
   - Browser console (web)

## Production Checklist

- [ ] SHA-1 fingerprints registered in Firebase
- [ ] Release keystore configured in build.gradle
- [ ] Email domain updated for production
- [ ] Authorized domains added to Firebase
- [ ] Testing on physical devices completed
- [ ] APK signed with release keystore
- [ ] App Bundle generated for Google Play
