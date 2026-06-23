import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../admin/admin_screen.dart';
import '../admin/pages/admin_notification_center_page.dart';
import '../../core/services/admin_service.dart';
import '../../core/services/announcement_service.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/fixture_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/widgets/app_background.dart';
import '../fixtures/fixture_marketplace_screen.dart';
import '../home/widgets/announcement_prompt_overlay.dart';
import '../home/home_screen.dart';
import '../profiles/profiles_screen.dart';
import '../timetable/teacher_timetable_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int currentIndex = 0;
  late final Future<bool> _adminFuture;
  Timer? _housekeepingTimer;

  @override
  void initState() {
    super.initState();
    _adminFuture = AdminService().isAdmin();
    _initBackgroundServices();
  }

  /// Runs once on app start and then every minute for as long as the app
  /// is open: requests notification permission (mobile/web/PC), and keeps
  /// fixtures + reminders moving even if nobody happens to have the
  /// Fixtures or Admin tab open. This is the single source of "anything
  /// relevant" background housekeeping for the whole app.
  Future<void> _initBackgroundServices() async {
    try {
      await NotificationService().initialize();
    } catch (_) {}

    _runHousekeeping();
    _housekeepingTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _runHousekeeping(),
    );
  }

  Future<void> _runHousekeeping() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    try {
      await FixtureService().expireFixtures();
      await FixtureService().autoAssignNearStartFixtures();
      await FixtureService().escalateUnclaimedFixtures();
    } catch (_) {}

    if (uid != null) {
      try {
        await NotificationService().runReminderSweepForTeacher(uid);
      } catch (_) {}
      try {
        await AnnouncementService().runEventReminderSweep(uid);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _housekeepingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _adminFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return AppBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: const Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final isAdmin = snapshot.data ?? false;

        final pages = [
          const HomeScreen(),
          const TeacherTimetableScreen(),
          const ProfilesScreen(),
          const FixtureMarketplaceScreen(),
          const AdminNotificationCenterPage(),
          if (isAdmin) const AdminScreen(),
        ];

        final destinations = <NavigationDestination>[
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: 'Schedule',
          ),
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Profiles',
          ),
          NavigationDestination(
            icon: _AvailableFixturesBadgeIcon(selected: false),
            selectedIcon: _AvailableFixturesBadgeIcon(selected: true),
            label: 'Fixtures',
          ),
          NavigationDestination(
            icon: _UnreadNotificationsBadgeIcon(selected: false),
            selectedIcon: _UnreadNotificationsBadgeIcon(selected: true),
            label: 'Notifications',
          ),
          if (isAdmin)
            const NavigationDestination(
              icon: Icon(Icons.admin_panel_settings_outlined),
              selectedIcon: Icon(Icons.admin_panel_settings),
              label: 'Admin',
            ),
          ];

        // Keep selection valid when admin status changes.
        final effectiveIndex = currentIndex.clamp(0, pages.length - 1);

        return PopScope(
          canPop: effectiveIndex == 0,
          onPopInvoked: (didPop) {
            if (!didPop) {
              setState(() => currentIndex = 0);
            }
          },
          child: AppBackground(
            child: Stack(
            children: [
              Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
              title: const Text('AKESP Timetable System'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PopupMenuButton<String>(
                    tooltip: 'Account',
                    onSelected: (value) async {
                      if (value == 'sign_out') {
                        final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Sign out?'),
                                content: const Text('You\'ll need to sign in again to continue.'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(ctx).pop(true),
                                    child: const Text('Sign Out'),
                                  ),
                                ],
                              ),
                            ) ??
                            false;

                        if (confirmed) {
                          await AuthService().signOut();
                          // AuthGate listens to authStateChanges() and will
                          // automatically swap back to the login screen.
                        }
                      }
                    },
                    itemBuilder: (context) {
                      final user = FirebaseAuth.instance.currentUser;
                      return [
                        PopupMenuItem<String>(
                          enabled: false,
                          child: Text(
                            user?.email ?? user?.displayName ?? 'Signed in',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem<String>(
                          value: 'sign_out',
                          child: Row(
                            children: [
                              Icon(Icons.logout, size: 18),
                              SizedBox(width: 8),
                              Text('Sign Out'),
                            ],
                          ),
                        ),
                      ];
                    },
                    child: const CircleAvatar(
                      backgroundColor: Colors.blue,
                      child: Icon(Icons.person, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
            body: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: pages[effectiveIndex],
            ),
                bottomNavigationBar: NavigationBar(
                  selectedIndex: effectiveIndex,
                  destinations: destinations,
                  onDestinationSelected: (index) {
                    setState(() => currentIndex = index);
                  },
                ),
              ),
              const AnnouncementPromptOverlay(),
            ],
            ),
          ),
        );
      },
    );
  }
}

/// Bottom-nav "Fixtures" icon with a live count of open (unclaimed) cover
/// slots — so a teacher notices there's something to claim without having
/// to open the tab first.
class _AvailableFixturesBadgeIcon extends StatelessWidget {
  final bool selected;
  const _AvailableFixturesBadgeIcon({required this.selected});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('fixtures')
          .where('status', isEqualTo: 'available')
          .snapshots(),
      builder: (context, snapshot) {
        final count = snapshot.data?.docs.length ?? 0;
        final icon = Icon(selected ? Icons.swap_horiz : Icons.swap_horiz_outlined);
        if (count == 0) return icon;
        return Badge(
          label: Text('$count'),
          child: icon,
        );
      },
    );
  }
}

/// Bottom-nav "Notifications" icon with a live unread count for the
/// signed-in user.
class _UnreadNotificationsBadgeIcon extends StatelessWidget {
  final bool selected;
  const _UnreadNotificationsBadgeIcon({required this.selected});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: NotificationService().watchNotifications(),
      builder: (context, snapshot) {
        final count = (snapshot.data ?? const [])
            .where((n) => n['read'] != true)
            .length;
        final icon = Icon(selected ? Icons.notifications : Icons.notifications_none_outlined);
        if (count == 0) return icon;
        return Badge(
          label: Text(count > 9 ? '9+' : '$count'),
          child: icon,
        );
      },
    );
  }
}

