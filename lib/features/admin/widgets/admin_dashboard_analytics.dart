import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/glass_card.dart';

class AdminDashboardAnalytics extends StatelessWidget {
  const AdminDashboardAnalytics({super.key});

  Future<int> _countTeachers() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'teacher')
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> _countPendingLeaves() async {
    final snap = await FirebaseFirestore.instance
        .collection('leave_requests')
        .where('status', isEqualTo: 'pending')
        .count()
        .get();
    return snap.count ?? 0;
  }

  String _dayName(DateTime dt) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[dt.weekday - 1];
  }

  Future<int> _countTodayClasses() async {
    final day = _dayName(DateTime.now());
    // Count weekly slots as "today's classes" measure.
    final snap = await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .where('day', isEqualTo: day)
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> _countFixtureRequests() async {
    // Treat non-expired fixtures as requests.
    final snap = await FirebaseFirestore.instance
        .collection('fixtures')
        .where('status', isNotEqualTo: 'expired')
        .count()
        .get();
    return snap.count ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final cardPadding = AppTheme.pagePadding(context);

    return Padding(
      padding: cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dashboard Analytics',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 160,
            child: GridView.count(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.5,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _MetricCard(
                  title: 'Total Teachers',
                  future: _countTeachers(),
                  icon: Icons.people,
                  accent: Colors.blue,
                ),
                _MetricCard(
                  title: 'Pending Leave Requests',
                  future: _countPendingLeaves(),
                  icon: Icons.event_busy,
                  accent: Colors.orangeAccent,
                ),
                _MetricCard(
                  title: "Today's Classes",
                  future: _countTodayClasses(),
                  icon: Icons.schedule,
                  accent: Colors.greenAccent,
                ),
                _MetricCard(
                  title: 'Fixture Requests',
                  future: _countFixtureRequests(),
                  icon: Icons.swap_horiz,
                  accent: Colors.purpleAccent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final Future<int> future;
  final IconData icon;
  final Color accent;

  const _MetricCard({
    required this.title,
    required this.future,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: accent),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: future,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const SizedBox(
                    height: 22,
                    child: LinearProgressIndicator(minHeight: 8),
                  );
                }
                return Text(
                  '${snapshot.data}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

