import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/widgets/glass_card.dart';
import '../../core/widgets/hover_lift.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/fixture_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/logging_service.dart';
import '../../models/fixture_model.dart';

class FixtureMarketplaceScreen extends StatefulWidget {
  const FixtureMarketplaceScreen({super.key});

  @override
  State<FixtureMarketplaceScreen> createState() =>
      _FixtureMarketplaceScreenState();
}

class _FixtureMarketplaceScreenState extends State<FixtureMarketplaceScreen>
    with SingleTickerProviderStateMixin {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _fixtureService = FixtureService();
  final _notificationService = NotificationService();
  final _loggingService = LoggingService();

  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = _auth.currentUser?.uid;
    final userEmail = _auth.currentUser?.email ?? 'Unknown';

    if (userId == null) {
      return Center(
        child: Text(
          'Not authenticated',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }

    return ListView(
      padding: AppTheme.pagePadding(context),
      children: [
        // Header
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fixture Marketplace',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text('Claim available fixture units in real-time'),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.circle, size: 8, color: Colors.green),
                      SizedBox(width: 8),
                      Text('Live'),
                    ],
                  ),
                ),
              ],
            ),
          )
              .animate()
              .fadeIn(duration: 300.ms)
              .slideY(begin: -10, end: 0),
        ),

        const SizedBox(height: 20),

        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Available'),
            Tab(text: 'My Claims'),
            Tab(text: 'History'),
          ],
          labelColor: Colors.blue,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.blue,
        ),

        const SizedBox(height: 20),

        SizedBox(
          height: 600,
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildAvailableFixtures(userId, userEmail),
              _buildMyClaimedFixtures(userId),
              _buildFixtureHistory(userId),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvailableFixtures(String userId, String userEmail) {
    return StreamBuilder<QuerySnapshot>(
      // No .orderBy() chained with .where() — avoids needing a Firestore
      // composite index. Sorted client-side instead.
      stream: _firestore
          .collection('fixtures')
          .where('status', isEqualTo: 'available')
          .where('isExpired', isEqualTo: false)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildSkeletonList();
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load fixtures: ${snapshot.error}',
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Center(
            child: Text(
              'No available fixtures',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        var fixtures = [...snapshot.data!.docs];
        fixtures.sort((a, b) {
          final ea = a['expiresAt'];
          final eb = b['expiresAt'];
          final da = ea is Timestamp ? ea.toDate() : DateTime.now();
          final db = eb is Timestamp ? eb.toDate() : DateTime.now();
          return da.compareTo(db);
        });

        return FutureBuilder<Set<String>>(
          future: _fixtureService.getApprovedLeaveDatesForTeacher(userId),
          builder: (context, leaveSnap) {
            final excludedDates = leaveSnap.data ?? <String>{};
            final visible = fixtures.where((d) {
              final date = (d.data() as Map<String, dynamic>)['date'] as String? ?? '';
              return date.isEmpty || !excludedDates.contains(date);
            }).toList();

            if (visible.isEmpty) {
              return Center(
                child: Text(
                  excludedDates.isNotEmpty
                      ? 'No available fixtures (some are hidden while you\'re on leave)'
                      : 'No available fixtures',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              );
            }

            return ListView(
              children: [
                for (int i = 0; i < visible.length; i++)
                  _buildFixtureCard(
                    visible[i],
                    userId,
                    userEmail,
                    onClaim: () => _claimFixture(visible[i], userId),
                    delay: i * 50,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildMyClaimedFixtures(String userId) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('fixtures')
          .where('claimedBy', isEqualTo: userId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildSkeletonList();
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load claimed fixtures: ${snapshot.error}',
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final fixtures = (snapshot.data?.docs ?? [])
            .where((d) => (d.data() as Map<String, dynamic>)['status'] != 'expired')
            .toList();

        if (fixtures.isEmpty) {
          return Center(
            child: Text(
              'You haven\'t claimed any fixtures',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return ListView(
          children: [
            for (int i = 0; i < fixtures.length; i++)
              _buildClaimedFixtureCard(
                fixtures[i],
                userId,
                onRelease: () => _releaseFixture(fixtures[i], userId),
                delay: i * 50,
              ),
          ],
        );
      },
    );
  }

  Widget _buildFixtureHistory(String userId) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('fixture_requests')
          .where('teacherId', isEqualTo: userId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildSkeletonList();
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load history: ${snapshot.error}',
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final logs = [...(snapshot.data?.docs ?? [])];
        logs.sort((a, b) {
          final ta = (a.data() as Map<String, dynamic>)['createdAt'];
          final tb = (b.data() as Map<String, dynamic>)['createdAt'];
          final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
          final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
          return db.compareTo(da);
        });
        final limited = logs.take(20).toList();

        if (limited.isEmpty) {
          return Center(
            child: Text(
              'No history',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        return ListView(
          children: [
            for (int i = 0; i < limited.length; i++)
              _buildHistoryCard(limited[i], delay: i * 50),
          ],
        );
      },
    );
  }

  Widget _buildFixtureCard(
    DocumentSnapshot fixture,
    String userId,
    String userEmail, {
    required VoidCallback onClaim,
    required int delay,
  }) {
    final data = fixture.data() as Map;
    final className = data['className'] as String? ?? 'Unknown Class';
    final unit = data['unit']?.toString() ?? 'Unit';
    final day = data['day'] as String? ?? '';
    final startTime = data['startTime'] as String? ?? '';
    final endTime = data['endTime'] as String? ?? '';
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();

    final timeUntilExpiry = expiresAt?.difference(DateTime.now()).inMinutes ??
        0;
    final isExpiringSoon = timeUntilExpiry < 10;

    return HoverLift(
      child: GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      className,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$day - Unit $unit',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: isExpiringSoon
                        ? Colors.red.withValues(alpha: 0.2)
                        : Colors.blue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${timeUntilExpiry}m left',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isExpiringSoon ? Colors.red : Colors.blue,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '$startTime - $endTime',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
            FutureBuilder<List<dynamic>>(
              future: Future.wait([
                _fixtureService.getRecommendedTeachers(
                  FixtureModel.fromMap(fixture.id, Map<String, dynamic>.from(data)),
                  limit: 5,
                ),
                _fixtureService.isTeacherFreeForFixture(
                  FixtureModel.fromMap(fixture.id, Map<String, dynamic>.from(data)),
                  userId,
                ),
              ]),
              builder: (context, combinedSnap) {
                final recommended =
                    (combinedSnap.data?[0] as List<Map<String, dynamic>>?) ?? const [];
                // Default to "free" (button enabled) while the check is
                // still loading rather than incorrectly blocking it — the
                // server-side check in claimFixture is the real guard.
                final isFree = combinedSnap.data == null
                    ? true
                    : (combinedSnap.data![1] as bool);
                final isRecommendedForMe =
                    recommended.any((r) => r['teacherId'] == userId);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isFree)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.event_busy, size: 14, color: Colors.redAccent),
                              SizedBox(width: 6),
                              Text(
                                'You\'re busy at this time',
                                style: TextStyle(fontSize: 11.5, color: Colors.redAccent, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (isRecommendedForMe)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_awesome, size: 14, color: Colors.greenAccent),
                              SizedBox(width: 6),
                              Text(
                                'Recommended for you',
                                style: TextStyle(fontSize: 11.5, color: Colors.greenAccent, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isFree ? onClaim : null,
                        icon: Icon(isFree ? Icons.check_circle : Icons.block),
                        label: Text(isFree ? 'Claim Now' : 'Not Available'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isFree ? Colors.blue : Colors.grey,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      )
          .animate(delay: Duration(milliseconds: delay))
          .fadeIn(duration: 300.ms)
          .slideY(begin: 10, end: 0),
      ),
    );
  }

  Widget _buildClaimedFixtureCard(
    DocumentSnapshot fixture,
    String userId, {
    required VoidCallback onRelease,
    required int delay,
  }) {
    final data = fixture.data() as Map;
    final className = data['className'] as String? ?? 'Unknown';
    final unit = data['unit']?.toString() ?? '';
    final startTime = data['startTime'] as String? ?? '';
    final endTime = data['endTime'] as String? ?? '';

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      className,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'Unit $unit',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Claimed ✓',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.green,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '$startTime - $endTime',
              style: const TextStyle(
                fontSize: 13,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onRelease,
                icon: const Icon(Icons.close),
                label: const Text('Release Claim'),
              ),
            ),
          ],
        ),
      )
          .animate(delay: Duration(milliseconds: delay))
          .fadeIn(duration: 300.ms),
    );
  }

  Widget _buildHistoryCard(DocumentSnapshot log, {required int delay}) {
    final data = log.data() as Map;
    final timestamp = (data['createdAt'] as Timestamp?)?.toDate();
    final action = (data['action'] as String? ?? '').replaceAll('_', ' ');
    final label = action.isEmpty
        ? 'Activity'
        : action[0].toUpperCase() + action.substring(1);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.grey.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  DateFormat('MMM d, HH:mm').format(
                    timestamp ?? DateTime.now(),
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.blue,
              ),
            ),
          ),
        ],
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms);
  }

  Widget _buildSkeletonList() {
    return ListView(
      children: [
        for (int i = 0; i < 3; i++)
          Container(
            height: 120,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(12),
            ),
          ),
      ],
    );
  }


Future<void> _claimFixture(DocumentSnapshot fixture, String userId) async {
    final data = fixture.data() as Map;
    final fixtureId = fixture.id;
    final className = data['className'] as String;
    final teacherName = _auth.currentUser?.email?.split('@')[0] ?? 'Teacher';


    try {
      await _fixtureService.claimFixture(
        fixtureId: fixtureId,
        teacherId: userId,
        teacherName: teacherName,
      );


      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fixture claimed successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }

await _loggingService.logFixtureEvent(
        fixtureId: fixtureId,
        eventType: 'claimed',
        className: className,
        teacherName: teacherName,
        details: const {
          'source': 'marketplace',
        },
      );

      await _notificationService.notifyAdmins(
        title: 'Fixture Claimed',
        body: '$className - $teacherName',
        action: 'fixture_claimed',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _releaseFixture(DocumentSnapshot fixture, String userId) async {
    final fixtureId = fixture.id;
    final data = fixture.data() as Map;
    final className = data['className'] as String;

    try {
      await _fixtureService.releaseFixture(
        fixtureId: fixtureId,
        teacherId: userId,
      );


      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fixture released'),
            backgroundColor: Colors.orange,
          ),
        );
      }

await _loggingService.logFixtureEvent(
        fixtureId: fixtureId,
        eventType: 'released',
        className: className,
        teacherName: _auth.currentUser?.email?.split('@')[0] ?? 'Teacher',
        details: const {},
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

