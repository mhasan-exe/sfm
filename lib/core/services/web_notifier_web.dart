// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// Fires a native browser/desktop notification (the little OS-level popup)
/// using the standard web Notification API. Only does anything if the
/// browser supports it and the user has already granted permission.
void showWebNotification({required String title, required String body}) {
  try {
    if (!html.Notification.supported) return;
    if (html.Notification.permission == 'granted') {
      html.Notification(title, body: body);
    }
  } catch (_) {
    // Never let a notification failure break the calling flow.
  }
}

Future<void> requestWebNotificationPermission() async {
  try {
    if (!html.Notification.supported) return;
    if (html.Notification.permission == 'default') {
      await html.Notification.requestPermission();
    }
  } catch (_) {}
}

bool get isWebNotificationSupported {
  try {
    return html.Notification.supported;
  } catch (_) {
    return false;
  }
}
