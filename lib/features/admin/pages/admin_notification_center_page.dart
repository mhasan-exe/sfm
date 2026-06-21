import 'package:flutter/material.dart';

import '../../../core/services/notification_service.dart';
import '../../../core/services/admin_service.dart';

/// Shared notification center for everyone. Admins see every notification
/// in the system (their own + every teacher's); regular teachers only ever
/// see their own — enforced both here (which stream we pick) and at the
/// Firestore rules layer (so it's not just a client-side restriction).
class AdminNotificationCenterPage extends StatefulWidget {
  const AdminNotificationCenterPage({super.key});

  @override
  State<AdminNotificationCenterPage> createState() =>
      _AdminNotificationCenterPageState();
}

class _AdminNotificationCenterPageState
    extends State<AdminNotificationCenterPage> {
  final _notificationService = NotificationService();
  late final Future<bool> _isAdminFuture;

  @override
  void initState() {
    super.initState();
    _notificationService.initialize();
    _isAdminFuture = AdminService().isAdmin();
  }

  Future<void> _markAsRead(Map<String, dynamic> doc) async {
    final id = doc['id'] as String?;
    if (id == null || id.isEmpty) return;
    await _notificationService.markNotificationAsRead(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<bool>(
        future: _isAdminFuture,
        builder: (context, adminSnap) {
          final isAdmin = adminSnap.data ?? false;

          return StreamBuilder<List<Map<String, dynamic>>>(
            stream: isAdmin
                ? _notificationService.watchAllNotifications()
                : _notificationService.watchNotifications(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Failed to load notifications: ${snapshot.error}',
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              if (snapshot.connectionState != ConnectionState.active &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final notifications = snapshot.data ?? [];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      isAdmin ? 'All notifications (admin view)' : 'Your notifications',
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: notifications.isEmpty
                        ? const Center(child: Text('No notifications yet'))
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: notifications.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final n = notifications[index];

                              final title = n['title']?.toString() ?? 'Notification';
                              final body = n['body']?.toString() ?? '';
                              final read = (n['read'] as bool?) ?? false;
                              final recipientId = n['userId']?.toString();

                              return Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  color: Colors.white.withValues(alpha: 0.06),
                                  border: Border.all(
                                    color: read
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.blue.withValues(alpha: 0.35),
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    title,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: read ? Colors.white70 : Colors.white,
                                    ),
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (body.isNotEmpty) Text(body),
                                      if (isAdmin && recipientId != null && recipientId.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(
                                            'To: ${recipientId.length > 8 ? recipientId.substring(0, 8) : recipientId}…',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white38,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  trailing: read
                                      ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                                      : const Icon(Icons.circle, size: 10, color: Colors.blueAccent),
                                  onTap: () async {
                                    if (!read) {
                                      await _markAsRead(n);
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
