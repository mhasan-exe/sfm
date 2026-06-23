import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../../../core/services/user_service.dart';
import '../../../core/services/fixture_service.dart';
import '../../../core/services/admin_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/app_background.dart';


class AdminAbsenceManagementPage extends StatefulWidget {
  const AdminAbsenceManagementPage({super.key});

  @override
  State<AdminAbsenceManagementPage> createState() =>
      _AdminAbsenceManagementPageState();
}

class _AdminAbsenceManagementPageState
    extends State<AdminAbsenceManagementPage> {
  final userService = UserService();
  final fixtureService = FixtureService();
  final adminService = AdminService();


  
  DateTime selectedDate = DateTime.now();
  String? selectedTeacherId;
  final reasonController = TextEditingController();

  Future<void> _markAbsent() async {
    if (selectedTeacherId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a teacher')),
      );
      return;
    }

    if (reasonController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter absence reason')),
      );
      return;
    }

    try {
      await userService.markTeacherAbsent(
        uid: selectedTeacherId!,
        date: selectedDate,
        reason: reasonController.text.trim(),
      );

      // Find and mark fixtures as absent for this teacher on this date
      final fixturesSnapshot = await FirebaseFirestore.instance
          .collection('fixtures')
          .where('assignedTeacherId', isEqualTo: selectedTeacherId)
          .get();

      for (final doc in fixturesSnapshot.docs) {
        final fixture = doc.data();
        // Check if fixture is on the selected date (simplified - just check day name)
        final dayName = selectedDate.weekday == 7
            ? 'Sunday'
            : [
                'Monday',
                'Tuesday',
                'Wednesday',
                'Thursday',
                'Friday',
                'Saturday'
              ][selectedDate.weekday - 1];

        if (fixture['day'] == dayName) {
          await fixtureService.markTeacherAbsent(
            fixtureId: doc.id,
            teacherId: selectedTeacherId!,
            reason: reasonController.text.trim(),
          );
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Teacher marked as absent')),
      );

      // Reset form
      setState(() {
        selectedTeacherId = null;
        reasonController.clear();
        selectedDate = DateTime.now();
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

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
  void dispose() {
    reasonController.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Mark Teacher Absent'),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: SingleChildScrollView(
          padding: AppTheme.pagePadding(context),
          child: Column(
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Mark Teacher Absent',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Select Date',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate:
                                DateTime.now()
                                    .subtract(const Duration(days: 30)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 30)),
                          );

                          if (!mounted) return;
                          if (picked != null) {
                            setState(() => selectedDate = picked);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.grey.withValues(
                                alpha: 0.3,
                              ),
                            ),
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.calendar_today),
                              const SizedBox(width: 12),
                              Text(
                                DateFormat('MMM dd, yyyy')
                                    .format(selectedDate),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Select Teacher',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      FutureBuilder<List<Map<String, dynamic>>>(
                        future: userService.getTeachersByWorkload(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const CircularProgressIndicator();
                          }

                          final teachers = snapshot.data ?? [];

                          if (teachers.isEmpty) {
                            return const Text(
                              'No teachers found',
                            );
                          }

                          final teacherItems = <DropdownMenuItem<String>>[
                            for (final teacher in teachers)
                              if (teacher['uid'] != null)
                                DropdownMenuItem<String>(
                                  value: teacher['uid'].toString(),
                                  child: Text(
                                    '${teacher['name']} (${teacher['totalUnits']}/${teacher['maxUnits'] ?? 24})',
                                  ),
                                ),
                          ];

                          return DropdownButton<String>(
                            isExpanded: true,
                            value: selectedTeacherId,
                            hint: const Text('Choose a teacher'),
                            items: teacherItems,
                            onChanged: (value) =>
                                setState(() => selectedTeacherId = value),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'Reason for Absence',
                        style: TextStyle(
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: reasonController,
                        decoration: InputDecoration(
                          labelText: 'Absence Reason',
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          hintText:
                              'e.g., Medical leave, Emergency, etc.',
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _markAbsent,
                          icon: const Icon(
                              Icons.person_off),
                          label: const Text(
                              'Mark as Absent'),
                          style: ElevatedButton
                              .styleFrom(
                            padding:
                                const EdgeInsets
                                    .symmetric(
                              vertical: 16,
                            ),
                            backgroundColor:
                                Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Recent Absences
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Recent Absences',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore
                            .instance
                            .collection('absences')
                            .orderBy('date',
                                descending: true)
                            .limit(20)
                            .snapshots(),
                        builder:
                            (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child:
                                  CircularProgressIndicator(),
                            );
                          }

                          final absences =
                              snapshot.data!.docs;

                          if (absences.isEmpty) {
                            return const Text(
                              'No absences recorded',
                            );
                          }

                          return ListView.separated(
                            shrinkWrap: true,
                            physics:
                                const NeverScrollableScrollPhysics(),
                            itemCount:
                                absences.length,
                            separatorBuilder:
                                (_, __) =>
                                    const SizedBox(
                                      height: 8,
                                    ),
                            itemBuilder: (context,
                                index) {
                              final absence =
                                  absences[index]
                                      .data()
                                  as Map<String,
                                      dynamic>;
                              final date =
                                  (absence['date']
                                          as Timestamp)
                                      .toDate();

                              return Container(
                                padding:
                                    const EdgeInsets
                                        .all(12),
                                decoration:
                                    BoxDecoration(
                                  border: Border.all(
                                    color: Colors.grey
                                        .withValues(
                                      alpha: 0.3,
                                    ),
                                  ),
                                  borderRadius:
                                      BorderRadius
                                          .circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment
                                          .start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment
                                              .spaceBetween,
                                      children: [
                                        Text(
                                          absence[
                                                  'reason'] ??
                                              'No reason',
                                          style:
                                              const TextStyle(
                                            fontWeight:
                                                FontWeight
                                                    .bold,
                                          ),
                                        ),
                                        Text(
                                          DateFormat(
                                                  'MMM dd')
                                              .format(
                                                  date),
                                          style:
                                              const TextStyle(
                                            fontSize: 12,
                                            color: Colors
                                                .grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
