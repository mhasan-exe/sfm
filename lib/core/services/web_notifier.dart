// Conditionally exports the real browser-Notification-API implementation
// when compiling for web (dart.library.html is only available there) and
// a harmless no-op everywhere else (Android/iOS/desktop), so this file is
// safe to import unconditionally from notification_service.dart.
export 'web_notifier_stub.dart' if (dart.library.html) 'web_notifier_web.dart';
