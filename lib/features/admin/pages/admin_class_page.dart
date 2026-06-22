import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/services/admin_service.dart';
import '../../../core/services/timetable_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';


class AdminClassPage extends StatefulWidget {
  const AdminClassPage({super.key});

  @override
  State<AdminClassPage> createState() => _AdminClassPageState();
}

class _AdminClassPageState extends State<AdminClassPage> {
  final timetableService = TimetableService();
  final adminService = AdminService();

  final classNameController = TextEditingController();
  final unitsController = TextEditingController();

  String? selectedProfileId;
  TimeProfileData? selectedProfile;

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
    classNameController.dispose();
    unitsController.dispose();
    super.dispose();
  }

  Future<void> _createClass() async {
    if (classNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter class name')),
      );
      return;
    }

    if (unitsController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter units per day')),
      );
      return;
    }

    if (selectedProfileId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a time profile')),
      );
      return;
    }

    try {
      final units = int.parse(unitsController.text);

      if (selectedProfile != null &&
          units > selectedProfile!.periods.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Units per day cannot exceed ${selectedProfile!.periods.length} available periods',
            ),
          ),
        );
        return;
      }

      await timetableService.createClass(
        className: classNameController.text.trim(),
        timeProfileId: selectedProfileId!,
        unitsPerDay: units,
      );

      classNameController.clear();
      unitsController.clear();
      selectedProfileId = null;
      selectedProfile = null;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Class created successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Manage Classes'),
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: SingleChildScrollView(
          padding: AppTheme.pagePadding(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Create New Class',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: classNameController,
                        decoration: InputDecoration(
                          labelText: 'Class Name',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hintText: 'e.g., 10-A',
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Select Time Profile',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('time_profiles')
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const CircularProgressIndicator();
                          }

                          final profiles = snapshot.data!.docs;

                          if (profiles.isEmpty) {
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.red.withValues(alpha: 0.3),
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'No time profiles found. Create one first.',
                                style: TextStyle(color: Colors.red),
                              ),
                            );
                          }

                          return DropdownButton<String>(
                            isExpanded: true,
                            value: selectedProfileId,
                            hint: const Text('Choose a time profile'),
                            items: profiles.map((profile) {
                              final data =
                                  profile.data() as Map<String, dynamic>;
                              return DropdownMenuItem<String>(
                                value: profile.id,
                                child: Text(data['name'] ?? 'Unknown'),
                                onTap: () {
                                  final periods =
                                      List.from(data['periods'] ?? []);
                                  setState(() {
                                    selectedProfile = TimeProfileData(
                                      id: profile.id,
                                      name: data['name'] ?? '',
                                      periods: periods,
                                    );
                                  });
                                },
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() => selectedProfileId = value);
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: unitsController,
                        decoration: InputDecoration(
                          labelText: 'Units Per Day',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hintText: '6',
                          helperText: selectedProfile != null
                              ? 'Max: ${selectedProfile!.periods.length} periods'
                              : '',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _createClass,
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            backgroundColor: Colors.blue,
                          ),
                          child: const Text('Create Class'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Existing Classes',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('classes')
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }

                          final classes = snapshot.data!.docs;

                          if (classes.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Text('No classes created yet'),
                            );
                          }

                          return ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: classes.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final classDoc = classes[index];
                              final data =
                                  classDoc.data() as Map<String, dynamic>;

                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.grey.withValues(alpha: 0.3),
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          data['className'] ?? 'Unknown',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        Chip(
                                          label: Text(
                                            '${data['unitsPerDay']} units/day',
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Profile: ${data['timeProfileId']}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
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

class TimeProfileData {
  final String id;
  final String name;
  final List<dynamic> periods;

  TimeProfileData({
    required this.id,
    required this.name,
    required this.periods,
  });
}

