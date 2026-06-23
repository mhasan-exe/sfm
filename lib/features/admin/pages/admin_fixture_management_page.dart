import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/services/admin_config_service.dart';
import '../../../core/services/fixture_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/fixture_model.dart';

class AdminFixtureManagementPage extends StatefulWidget {
  const AdminFixtureManagementPage({super.key});

  @override
  State<AdminFixtureManagementPage> createState() =>
      _AdminFixtureManagementPageState();
}

class _AdminFixtureManagementPageState extends State<AdminFixtureManagementPage> {
  final FixtureService fixtureService = FixtureService();
  int _selectedTab = 0;
  Timer? _escalationTimer;

  @override
  void initState() {
    super.initState();
    // Run once immediately, then keep checking every minute so unclaimed
    // fixtures get escalated to admin as soon as their claim window closes
    // — not just when someone happens to open this page.
    _runEscalationCheck();
    _escalationTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _runEscalationCheck(),
    );
  }

  @override
  void dispose() {
    _escalationTimer?.cancel();
    super.dispose();
  }

  Future<void> _runEscalationCheck() async {
    try {
      await fixtureService.expireFixtures();
      await fixtureService.autoAssignNearStartFixtures();
      await fixtureService.escalateUnclaimedFixtures();
    } catch (_) {
      // Silent: this is a background housekeeping check, not a user action.
    }
  }

  int _teacherUnits(Map<String, dynamic> teacher) {
    final defaultUnits = (teacher['defaultUnits'] as num?)?.toInt() ?? 0;
    final fixtureUnits = (teacher['fixtureUnits'] as num?)?.toInt() ?? 0;
    return defaultUnits + fixtureUnits;
  }

  Future<void> _assignFixture(Map<String, dynamic> fixture) async {
    final teachersSnapshot = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'teacher')
        .get();

    if (!mounted) return;

    final maxUnits = await AdminConfigService().getMaxUnitsPerTeacher();
    final fixtureModel = FixtureModel.fromMap(
      fixture['id'].toString(),
      Map<String, dynamic>.from(fixture),
    );
    final recommended = await fixtureService.getRecommendedTeachers(fixtureModel, limit: 5);
    final recommendedIds = recommended.map((r) => r['teacherId'] as String).toSet();

    if (!mounted) return;

    final teachers = [...teachersSnapshot.docs];
    // Recommended teachers float to the top so the admin sees the best fit
    // first instead of an alphabetical/unsorted dump.
    teachers.sort((a, b) {
      final aRec = recommendedIds.contains(a.id);
      final bRec = recommendedIds.contains(b.id);
      if (aRec == bRec) return 0;
      return aRec ? -1 : 1;
    });
    String? selectedTeacherId;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Assign Fixture'),
          content: SizedBox(
            width: 440,
            child: StatefulBuilder(
            builder: (context, setDialogState) {
              final teacherWidgets = teachers.map<Widget>((doc) {
                final teacher = doc.data();
                final units = _teacherUnits(teacher);
                final isDisabled = units >= maxUnits;
                final isRecommended = recommendedIds.contains(doc.id);

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: doc.id,
                    groupValue: selectedTeacherId,
                    onChanged: isDisabled
                        ? null
                        : (value) {
                            setDialogState(() {
                              selectedTeacherId = value;
                            });
                          },
                    title: Row(
                      children: [
                        Flexible(child: Text(teacher['name']?.toString() ?? 'Unknown')),
                        if (isRecommended) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.auto_awesome, size: 14, color: Colors.greenAccent),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      isRecommended ? '$units/$maxUnits units · Recommended' : '$units/$maxUnits units',
                    ),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                );
              }).toList();

              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select a teacher to assign:',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    ...teacherWidgets,
                  ],
                ),
              );
            },
          ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedTeacherId == null
                  ? null
                  : () async {
                      try {
                        final selectedTeacher = teachers.firstWhere(
                          (t) => t.id == selectedTeacherId,
                        );
                        final teacherData = selectedTeacher.data();

                        await fixtureService.assignFixture(
                          fixtureId: fixture['id'].toString(),
                          teacherId: selectedTeacherId!,
                          teacherName:
                              teacherData['name']?.toString() ?? 'Unknown',
                        );

                        if (!mounted) return;
                        Navigator.of(dialogContext).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Fixture assigned successfully'),
                          ),
                        );
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e')),
                        );
                      }
                    },
              child: const Text('Assign'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFixtureCard(Map<String, dynamic> fixture, String status) {
    final className = fixture['className']?.toString() ?? 'Unknown Class';
    final day = fixture['day']?.toString() ?? 'Unknown';
    final unit = fixture['unit']?.toString() ?? '--';
    final startTime = fixture['startTime']?.toString() ?? '--:--';
    final endTime = fixture['endTime']?.toString() ?? '--:--';
    final claimedByName = fixture['claimedByName']?.toString();
    final assignedTeacherName = fixture['assignedTeacherName']?.toString();

    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(width: 12),
                Chip(
                  label: Text(
                    status,
                    style: const TextStyle(color: Colors.white),
                  ),
                  backgroundColor: _getStatusColor(status),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.calendar_today, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$day - Unit $unit',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.access_time, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$startTime - $endTime',
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
            if (claimedByName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.person, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Claimed by: $claimedByName',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ],
            if (assignedTeacherName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Assigned to: $assignedTeacherName',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  if (fixture['autoAssigned'] == true)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.purpleAccent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Auto-assigned',
                        style: TextStyle(fontSize: 10.5, color: Colors.purpleAccent),
                      ),
                    ),
                ],
              ),
            ],
            if (status == 'available' || status == 'claimed') ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => _assignFixture(fixture),
                  icon: const Icon(Icons.person_add),
                  label: const Text('Assign Teacher'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'available':
        return Colors.blue;
      case 'claimed':
        return Colors.orange;
      case 'assigned':
        return Colors.green;
      case 'expired':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Fixture Management'),
          elevation: 0,
          backgroundColor: Colors.transparent,
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await fixtureService
                          .expireFixtures()
                          .timeout(const Duration(seconds: 8));

                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Expired fixtures updated')),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Expiry'),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                return Container(
                  margin: EdgeInsets.symmetric(
                    horizontal: narrow ? 12 : 16,
                    vertical: narrow ? 10 : 14,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: narrow
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            alignment: WrapAlignment.center,
                            children: [
                              _buildTab('Available', 0, compact: true),
                              _buildTab('Claimed', 1, compact: true),
                              _buildTab('Assigned', 2, compact: true),
                              _buildTab('Expired', 3, compact: true),
                              _buildNeedsAssignmentTab(4, compact: true),
                            ],
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              _buildTab('Available', 0),
                              _buildTab('Claimed', 1),
                              _buildTab('Assigned', 2),
                              _buildTab('Expired', 3),
                              _buildNeedsAssignmentTab(4),
                            ],
                          ),
                        ),
                );
              },
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: AppTheme.pagePadding(context),
                child: _buildTabContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildNeedsAssignmentTab(int index, {bool compact = false}) {
    return StreamBuilder<List<FixtureModel>>(
      stream: fixtureService.watchFixturesNeedingManualAssignment(),
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        final selected = _selectedTab == index;
        final label = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Needs Assignment'),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ],
          ],
        );

        final tab = GestureDetector(
          onTap: () => setState(() => _selectedTab = index),
          child: Container(
            padding: compact
                ? const EdgeInsets.symmetric(vertical: 10, horizontal: 12)
                : const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? Colors.red.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: compact ? BorderRadius.circular(10) : null,
              border: compact
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: selected ? Colors.red : Colors.transparent,
                        width: 3,
                      ),
                    ),
            ),
            child: DefaultTextStyle(
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: selected ? Colors.red : Colors.grey,
              ),
              child: label,
            ),
          ),
        );

        return compact ? tab : Expanded(child: tab);
      },
    );
  }

  Widget _buildTab(String label, int index, {bool compact = false}) {
    final selected = _selectedTab == index;

    final tab = GestureDetector(
      onTap: () => setState(() => _selectedTab = index),
      child: Container(
        padding: compact
            ? const EdgeInsets.symmetric(vertical: 10, horizontal: 12)
            : const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.blue.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: compact ? BorderRadius.circular(10) : null,
          border: compact
              ? null
              : Border(
                  bottom: BorderSide(
                    color: selected ? Colors.blue : Colors.transparent,
                    width: 3,
                  ),
                ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: compact ? 12 : 12,
            color: selected ? Colors.blue : Colors.grey,
          ),
        ),
      ),
    );

    return compact ? tab : Expanded(child: tab);
  }


  Widget _buildNeedsAssignmentContent() {
    return StreamBuilder<List<FixtureModel>>(
      stream: fixtureService.watchFixturesNeedingManualAssignment(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final fixtures = snapshot.data!;

        if (fixtures.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nothing needs manual assignment right now. Unclaimed '
                'fixtures land here automatically once their 1-hour claim '
                'window closes.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return Column(
          children: fixtures.map((f) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildFixtureCard(f.toMap()..['id'] = f.id, 'available'),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildTabContent() {
    if (_selectedTab == 4) {
      return _buildNeedsAssignmentContent();
    }

    final String status;
    switch (_selectedTab) {
      case 0:
        status = 'available';
        break;
      case 1:
        status = 'claimed';
        break;
      case 2:
        status = 'assigned';
        break;
      case 3:
        status = 'expired';
        break;
      default:
        status = 'available';
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('fixtures')
          .where('status', isEqualTo: status)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final fixtures = snapshot.data!.docs;

        if (fixtures.isEmpty) {
          return Center(
            child: Text('No $status fixtures'),
          );
        }

        return Column(
          children: fixtures.map((doc) {
            final fixture = <String, dynamic>{
              ...doc.data() as Map<String, dynamic>,
              'id': doc.id,
            };

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildFixtureCard(fixture, status),
            );
          }).toList(),
        );
      },
    );
  }
}
