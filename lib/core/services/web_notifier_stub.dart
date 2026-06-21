/// No-op on Android/iOS/desktop — actual desktop/mobile push goes through
/// FCM + flutter_local_notifications instead. This file exists only so
/// [notification_service.dart] has a single, platform-safe API surface.
void showWebNotification({required String title, required String body}) {}

Future<void> requestWebNotificationPermission() async {}

bool get isWebNotificationSupported => false;
