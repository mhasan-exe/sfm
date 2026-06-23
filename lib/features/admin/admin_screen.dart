import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';


import '../../core/services/admin_service.dart';
import '../../core/services/timetable_service.dart';
import '../../core/utils/timetable_constants.dart';
import 'pages/admin_fixture_management_page.dart';

import '../../core/widgets/glass_card.dart';
import '../../core/widgets/responsive_wrapper.dart';
import '../../core/widgets/app_background.dart';
import '../../core/theme/app_theme.dart';




import '../../models/time_profile_model.dart';
import 'pages/admin_leave_management_page.dart';
import 'pages/admin_timetable_page.dart';
import 'pages/admin_logs_page.dart';
import 'pages/admin_announcements_page.dart';
import 'pages/admin_break_duty_page.dart';
import 'pages/admin_config_page.dart';
import 'pages/admin_presets_page.dart';
import 'pages/admin_time_profile_page.dart';
// Bento UI helpers (future migration of remaining widgets)

import 'widgets/admin_dashboard_analytics.dart';




class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  // iPhone-style spacing defaults for compact cards/dropdowns.

  final profileNameController = TextEditingController();

  final classNameController = TextEditingController();

  final unitsController = TextEditingController();

  final adminEmailController = TextEditingController();

  final adminUidController = TextEditingController();

  final List<TimePeriod> periods = [];

  final timetableService = TimetableService();

  final adminService = AdminService();

  int selectedSidebar = 0;
  String? selectedTimeProfileId;

  // =========================
  // CREATE PROFILE
  // =========================

  Future<void> createProfile() async {
    if (profileNameController.text.trim().isEmpty) {
      return;
    }

    if (periods.isEmpty) {
      return;
    }

    await timetableService.createTimeProfile(
      name: profileNameController.text,
      periods: periods,
    );

    profileNameController.clear();

    periods.clear();

    setState(() {});

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Profile Created'),
      ),
    );
  }

  // =========================
  // CREATE CLASS
  // =========================

  Future<void> createClass() async {
    if (classNameController.text.trim().isEmpty) {
      return;
    }

    if (unitsController.text.trim().isEmpty) {
      return;
    }

    if (selectedTimeProfileId == null || selectedTimeProfileId!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a time profile before creating a class.'),
        ),
      );
      return;
    }

    await timetableService.createClass(
      className: classNameController.text,
      timeProfileId: selectedTimeProfileId!,
      unitsPerDay: int.parse(unitsController.text),
    );

    classNameController.clear();
    unitsController.clear();
    selectedTimeProfileId = null;

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Class Created'),
      ),
    );
  }

  // =========================
  // ADMIN ACCESS
  // =========================

  Future<void> addAdminPermission() async {
    final email = adminEmailController.text.trim();
    final uid = adminUidController.text.trim();

    if (email.isEmpty || uid.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter both admin email and uid.'),
        ),
      );
      return;
    }

    await adminService.createAdmin(
      email: email,
      uid: uid,
    );

    adminEmailController.clear();
    adminUidController.clear();

    if (!mounted) return;

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Admin permission added.'),
      ),
    );
  }

  Future<void> removeAdminPermission(String docId) async {
    await adminService.deleteAdmin(docId);
    if (!mounted) return;
    setState(() {});
  }

  // =========================
  // ADD PERIOD
  // =========================

  void addPeriodDialog() {
    final startController = TextEditingController();

    final endController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text(
            'Add Period',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: startController,
                decoration: const InputDecoration(
                  labelText: 'Start Time',
                  hintText: '08:00 AM',
                ),
              ),
              const SizedBox(
                height: 16,
              ),
              TextField(
                controller: endController,
                decoration: const InputDecoration(
                  labelText: 'End Time',
                  hintText: '08:40 AM',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text(
                'Cancel',
              ),
            ),
            ElevatedButton(
              onPressed: () {
                periods.add(
                  TimePeriod(
                    periodNumber: periods.length + 1,
                    startTime: startController.text,
                    endTime: endController.text,
                  ),
                );

                setState(() {});

                Navigator.pop(context);
              },
              child: const Text(
                'Add',
              ),
            ),
          ],
        );
      },
    );
  }

  // =========================
  // BUILD
  // =========================

  @override
  void initState() {
    super.initState();
    _verifyAdmin();
  }

  Future<void> _verifyAdmin() async {
    final isAdmin = await adminService.isAdmin();
    if (!isAdmin && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ResponsiveWrapper(
      mobile: mobileLayout(),
      desktop: desktopLayout(),
    );
  }


  // =========================
  // MOBILE
  // =========================

  Widget mobileLayout() {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Admin Panel'),
        ),
        drawer: Drawer(
          backgroundColor: Colors.transparent,
          child: SafeArea(
            child: buildSidebar(),
          ),
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: SafeArea(
            child: ListView(
              key: ValueKey(selectedSidebar),
              padding: AppTheme.pagePadding(context),
              children: [
                buildAdminBody(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // =========================
  // DESKTOP
  // =========================

  Widget desktopLayout() {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Row(
            key: ValueKey(selectedSidebar),
            children: [
              buildSidebar(),
              Expanded(
                child: SafeArea(
                  child: ListView(
                    padding: AppTheme.pagePadding(context),
                    children: [
                      buildAdminBody(),
                    ],
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  // =========================
  // BODY
  // =========================

  String? _selectedTimetableClassId;

  Widget buildAdminTimetablePicker() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('classes').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.active) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          _selectedTimetableClassId = null;
          return const GlassCard(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No classes found. Create a class first.',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          );
        }

        final availableIds = docs.map((d) => d.id).toSet();
        if (_selectedTimetableClassId == null || !_selectedTimetableClassId!.isNotEmpty) {
          _selectedTimetableClassId = docs.first.id;
        } else if (!availableIds.contains(_selectedTimetableClassId)) {
          _selectedTimetableClassId = docs.first.id;
        }

        return GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select a class to manage timetable',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedTimetableClassId,
                  items: docs.map((d) {
                    final data = d.data();
                    final name = (data['className'] as String?) ?? d.id;
                    return DropdownMenuItem(
                      value: d.id,
                      child: Text(name),
                    );
                  }).toList(),
                  onChanged: (classId) {
                    if (classId == null || classId.isEmpty) return;
                    setState(() => _selectedTimetableClassId = classId);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AdminTimetablePage(classId: classId),
                      ),
                    );
                  },
                  decoration: const InputDecoration(
                    labelText: 'Class',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AdminTimeProfilePage()),
                    );
                  },
                  icon: const Icon(Icons.schedule_outlined, size: 18),
                  label: const Text('Manage Time Profiles (view · create · edit · delete)'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget buildAdminBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final topGap = constraints.maxWidth < 600 ? 12.0 : 20.0;

        switch (selectedSidebar) {
          case 1:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(
                  title: 'Classes',
                  subtitle: 'Create and manage class details in one place.',
                ),
                SizedBox(height: topGap),
                buildCreateClassCard(),
                SizedBox(height: topGap),
                buildExistingClassesCard(),
              ],
            );
          case 2:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(
                  title: 'Timetables',
                  subtitle: 'Build and manage school schedules for each class.',
                ),
                SizedBox(height: topGap),
                buildAdminTimetablePicker(),
              ],
            );



          case 3:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(
                  title: 'Fixtures',
                  subtitle: 'Track upcoming fixtures, events, and schedules.',
                ),
                SizedBox(height: topGap),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: const AdminFixtureManagementPage(),
                ),
              ],
            );
          case 4:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(
                  title: 'Leaves',
                  subtitle: 'Manage leaves and absence approvals in one place.',
                ),
                SizedBox(height: topGap),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: const AdminLeaveManagementPage(),
                ),
              ],
            );

          case 5:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(
                  title: 'Logs',
                  subtitle: 'History of timetable/admin actions.',
                ),
                SizedBox(height: topGap),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.8,
                  child: const AdminLogsPage(),
                ),
              ],
            );
          default:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buildHeader(),
                SizedBox(height: topGap - 6),
                const AdminDashboardAnalytics(),
                SizedBox(height: topGap),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isNarrow = constraints.maxWidth < 820;
                    if (isNarrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          buildTimeProfileCard(),
                          const SizedBox(height: 16),
                          buildCreateClassCard(),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: buildTimeProfileCard()),
                        const SizedBox(width: 24),
                        Expanded(child: buildCreateClassCard()),
                      ],
                    );
                  },
                ),
                SizedBox(height: topGap),
                buildAdminAccessCard(),
              ],
            );
        }
      },
    );
  }


  Widget buildPlaceholderCard(String title, String subtitle) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(subtitle),
            const SizedBox(height: 12),
            const Text(
              'This section is under construction, but the navigation is now responsive and working correctly.',
            ),
          ],
        ),
      ),
    );
  }

  // =========================
  // SIDEBAR
  // =========================

  Widget buildSidebar() {
    final items = [
      'Dashboard',
      'Classes',
      'Timetables',
      'Fixtures',
      'Leaves',
      'Logs',
      'Break Duties',
      'Announcements',
      'Presets',
      'Settings',
    ];

    final icons = [
      Icons.dashboard,
      Icons.school,
      Icons.table_chart,
      Icons.swap_horiz,
      Icons.event_busy,
      Icons.history,
      Icons.shield_outlined,
      Icons.campaign_outlined,
      Icons.save_outlined,
      Icons.settings_outlined,
    ];

    return Container(
      width: 260,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF171A22),
        border: Border(
          right: BorderSide(
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Text(
            'AKESP Admin',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 40),
          // Scrollable so adding more sidebar entries over time never
          // overflows the available height (drawer on mobile, fixed-width
          // column on desktop — both have a bounded height already).
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(
                    items.length,
                    (index) {
                      final selected = selectedSidebar == index;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            Navigator.maybePop(context);
                            if (index == 6) {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const AdminBreakDutyPage()),
                              );
                              return;
                            }
                            if (index == 7) {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const AdminAnnouncementsPage()),
                              );
                              return;
                            }
                            if (index == 8) {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const AdminPresetsPage()),
                              );
                              return;
                            }
                            if (index == 9) {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => const AdminConfigPage()),
                              );
                              return;
                            }
                            setState(() {
                              selectedSidebar = index;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFF4F8CFF)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              children: [
                                Icon(icons[index]),
                                const SizedBox(width: 14),
                                Text(items[index]),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // HEADER
  // =========================

  Widget buildHeader({
    String title = 'Admin Dashboard',
    String subtitle = 'Realtime timetable coordination system',
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(
              alpha: 0.15,
            ),
            borderRadius: BorderRadius.circular(
              18,
            ),
          ),
          child: const Row(
            children: [
              Icon(Icons.bolt),
              SizedBox(width: 8),
              Text('Realtime Sync'),
            ],
          ),
        )
      ],
    ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.1);
  }

  // =========================
  // PROFILE CARD
  // =========================

  Widget buildTimeProfileCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_outlined, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Time Profiles',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Define your school day — periods and breaks, each with proper start/end times — then assign a profile to each class. Quick-generate builds a whole day from a start time, period length and break list.',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminTimeProfilePage()),
                );
              },
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open Time Profile Manager'),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms).slideX(begin: -0.1);
  }

  // =========================
  // CLASS CARD
  // =========================

  Widget buildAdminAccessCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Admin Access',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: adminEmailController,
            decoration: const InputDecoration(
              labelText: 'Admin Email',
              hintText: 'user@example.com',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: adminUidController,
            decoration: const InputDecoration(
              labelText: 'Admin UID',
              hintText: 'Firebase user uid',
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: addAdminPermission,
              child: const Text('Grant Admin Access'),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Current admins',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          StreamBuilder(
            stream: adminService.watchAdmins(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.active) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No admin entries found.'),
                );
              }

              final docs = snapshot.data!.docs;
              return Column(
                children: docs.map((doc) {
                  final data = doc.data();
                  final email = data['email'] as String? ?? 'Unknown email';
                  final uid = data['uid'] as String? ?? doc.id;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D1322),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(email),
                                const SizedBox(height: 6),
                                Text(
                                  'UID: $uid',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => removeAdminPermission(doc.id),
                            icon: const Icon(Icons.delete),
                            color: Colors.redAccent,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms).slideX(begin: 0.1);
  }

  Widget buildCreateClassCard() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Create Class',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: classNameController,
            decoration: const InputDecoration(
              labelText: 'Class Name',
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: unitsController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Units Per Day',
            ),
          ),
          const SizedBox(height: 20),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('time_profiles')
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox(
                  height: 56,
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final profiles = snapshot.data!.docs;
              if (profiles.isEmpty) {
                return const Text(
                  'Create a time profile first.',
                  style: TextStyle(color: Colors.white70),
                );
              }

              return DropdownButtonFormField<String>(
                initialValue: selectedTimeProfileId,
                decoration: const InputDecoration(
                  labelText: 'Time Profile',
                ),
                items: profiles.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  return DropdownMenuItem(
                    value: doc.id,
                    child: Text(data['name'] ?? 'Unnamed Profile'),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    selectedTimeProfileId = value;
                  });
                },
              );
            },
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: createClass,
              child: const Text(
                'Create Class',
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 500.ms).slideX(begin: 0.1);
  }

  // =========================
  // EXISTING CLASSES (fetch + edit + delete)
  // =========================

  Widget buildExistingClassesCard() {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Existing Classes',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance.collection('time_profiles').snapshots(),
              builder: (context, profileSnap) {
                final profileNameById = <String, String>{};
                for (final d in profileSnap.data?.docs ?? const []) {
                  profileNameById[d.id] = (d.data()['name'] as String?) ?? 'Unnamed profile';
                }

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance.collection('classes').snapshots(),
                  builder: (context, classSnap) {
                    if (!classSnap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final docs = classSnap.data!.docs;
                    if (docs.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          'No classes created yet.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }

                    return Column(
                      children: docs.map((doc) {
                        final data = doc.data();
                        final className = (data['className'] as String?) ?? 'Unnamed class';
                        final timeProfileId = (data['timeProfileId'] as String?) ?? '';
                        final profileName = profileNameById[timeProfileId] ?? 'Unknown profile';
                        final unitsPerDay = (data['unitsPerDay'] as num?)?.toInt() ?? 0;
                        final classTeacherName = (data['classTeacherName'] as String?) ?? '';
                        final rawDays = data['workingDays'];
                        final workingDays = rawDays is List
                            ? rawDays.map((e) => e.toString()).toList()
                            : kWorkingDays;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                              borderRadius: BorderRadius.circular(14),
                              color: Colors.white.withValues(alpha: 0.03),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        className,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Edit class',
                                      icon: const Icon(Icons.edit, size: 20),
                                      onPressed: () => _showEditClassDialog(
                                        classId: doc.id,
                                        currentClassName: className,
                                        currentTimeProfileId: timeProfileId,
                                        currentUnitsPerDay: unitsPerDay,
                                        currentWorkingDays: workingDays,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete class',
                                      icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                                      onPressed: () => _confirmDeleteClass(doc.id, className),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    Chip(label: Text('$unitsPerDay units/day')),
                                    Chip(label: Text('Profile: $profileName')),
                                    if (classTeacherName.isNotEmpty)
                                      Chip(
                                        avatar: const Icon(Icons.star, size: 14, color: Colors.amber),
                                        label: Text('Class teacher: $classTeacherName'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  "Working days: ${workingDays.join(', ')}",
                                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 500.ms).slideX(begin: 0.1);
  }

  Future<void> _confirmDeleteClass(String classId, String className) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete class?'),
            content: Text(
              'This permanently deletes "$className" and all of its weekly/daily timetable slots. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    await timetableService.deleteClass(classId);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$className" deleted.')),
    );
  }

  Future<void> _showEditClassDialog({
    required String classId,
    required String currentClassName,
    required String currentTimeProfileId,
    required int currentUnitsPerDay,
    required List<String> currentWorkingDays,
  }) async {
    final nameController = TextEditingController(text: currentClassName);
    final unitsController = TextEditingController(text: currentUnitsPerDay.toString());
    String? profileId = currentTimeProfileId.isEmpty ? null : currentTimeProfileId;
    final selectedDays = {...currentWorkingDays};

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Class'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Class Name'),
                    ),
                    const SizedBox(height: 16),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance.collection('time_profiles').snapshots(),
                      builder: (context, snap) {
                        final profiles = snap.data?.docs ?? const [];
                        if (profiles.isEmpty) {
                          return const Text(
                            'No time profiles available.',
                            style: TextStyle(color: Colors.redAccent),
                          );
                        }
                        return DropdownButtonFormField<String>(
                          initialValue: profileId,
                          decoration: const InputDecoration(labelText: 'Time Profile'),
                          items: profiles.map((d) {
                            final name = (d.data()['name'] as String?) ?? 'Unnamed';
                            return DropdownMenuItem(value: d.id, child: Text(name));
                          }).toList(),
                          onChanged: (v) => setDialogState(() => profileId = v),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: unitsController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Units Per Day'),
                    ),
                    const SizedBox(height: 16),
                    const Text('Working Days', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: kAllDayNames.take(6).map((day) {
                        final selected = selectedDays.contains(day);
                        return FilterChip(
                          label: Text(day),
                          selected: selected,
                          onSelected: (v) => setDialogState(() {
                            if (v) {
                              selectedDays.add(day);
                            } else {
                              selectedDays.remove(day);
                            }
                          }),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty ||
                        unitsController.text.trim().isEmpty ||
                        profileId == null ||
                        selectedDays.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Fill in all fields and pick at least one working day.')),
                      );
                      return;
                    }

                    await timetableService.updateClassDetails(
                      classId: classId,
                      className: nameController.text.trim(),
                      timeProfileId: profileId!,
                      unitsPerDay: int.tryParse(unitsController.text.trim()) ?? currentUnitsPerDay,
                      workingDays: selectedDays.toList(),
                    );

                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();

                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Class updated.')),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
