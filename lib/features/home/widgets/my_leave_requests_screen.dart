import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import '../../../core/services/leave_service.dart';
import '../../../core/widgets/glass_card.dart';

/// Shows the signed-in teacher's own leave requests with live status.
///
/// This view never previously existed: teachers could submit a leave
/// request via [LeaveRequestDialog] but had no way to check whether it was
/// approved, rejected, or still pending. LeaveService.watchTeacherLeaves()
/// was fully built but never called from anywhere in the app.
class MyLeaveRequestsScreen extends StatelessWidget {
  const MyLeaveRequestsScreen({super.key});

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return Colors.greenAccent;
      case 'rejected':
        return Colors.redAccent;
      case 'cancelled':
        return Colors.grey;
      default:
        return Colors.amber;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'approved':
        return Icons.check_circle;
      case 'rejected':
        return Icons.cancel;
      case 'cancelled':
        return Icons.block;
      default:
        return Icons.hourglass_top;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('My Leave Requests')),
      body: uid == null
          ? const Center(child: Text('Not authenticated'))
          : StreamBuilder<List<Map<String, dynamic>>>(
              stream: LeaveService().watchTeacherLeaves(uid),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Failed to load your leave requests: ${snapshot.error}',
                        style: const TextStyle(color: Colors.redAccent),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final requests = snapshot.data!;

                if (requests.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'You haven\'t submitted any leave requests yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    final r = requests[index];
                    final status = (r['status'] as String?) ?? 'pending';
                    final start = (r['startDate'] as Timestamp?)?.toDate();
                    final end = (r['endDate'] as Timestamp?)?.toDate();
                    final reason = (r['reason'] as String?) ?? '';
                    final rejectionReason = (r['rejectionReason'] as String?) ?? '';
                    final fmt = DateFormat('MMM d, yyyy');
                    final dateLabel = start == null
                        ? '—'
                        : (end != null && end.difference(start).inDays > 0
                            ? '${fmt.format(start)} – ${fmt.format(end)}'
                            : fmt.format(start));

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(_statusIcon(status), color: _statusColor(status), size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    status[0].toUpperCase() + status.substring(1),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: _statusColor(status),
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(dateLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                              if (reason.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(reason, style: const TextStyle(color: Colors.white70)),
                              ],
                              if (status == 'rejected' && rejectionReason.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Reason: $rejectionReason',
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
