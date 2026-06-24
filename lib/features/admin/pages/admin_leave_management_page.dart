import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

import '../../../core/services/leave_service.dart';
import '../../../core/services/timetable_service.dart';

/// Admin leave requests — rebuilt deliberately simple after the previous
/// tabbed version kept breaking. One unfiltered stream of the whole
/// collection (no where/orderBy combo, so there's no Firestore index to
/// forget and no query-shape ambiguity for security rules to trip over),
/// sorted and grouped client-side. Each card shows the request and, if
/// still pending, an Approve / Reject pair.
class AdminLeaveManagementPage extends StatefulWidget {
  const AdminLeaveManagementPage({super.key});

  @override
  State<AdminLeaveManagementPage> createState() => _AdminLeaveManagementPageState();
}

class _AdminLeaveManagementPageState extends State<AdminLeaveManagementPage> {
  final _leaveService = LeaveService();
  final _dateFmt = DateFormat('MMM d, yyyy');
  final Set<String> _busyIds = {};

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF4ADE80);
      case 'rejected':
        return const Color(0xFFF87171);
      default:
        return const Color(0xFFFBBF24);
    }
  }

  String _dateLabel(Timestamp? start, Timestamp? end) {
    if (start == null) return 'No date';
    final s = start.toDate();
    final e = end?.toDate() ?? s;
    if (e.difference(s).inDays <= 0) return _dateFmt.format(s);
    return '${_dateFmt.format(s)} – ${_dateFmt.format(e)}';
  }

  Future<void> _approve(String id) async {
    setState(() => _busyIds.add(id));
    try {
      await _leaveService.approveLeave(
        leaveRequestId: id,
        adminId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown_admin',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not approve: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _resync(String id, String teacherId, String teacherName) async {
    setState(() => _busyIds.add(id));
    try {
      final vacated = await TimetableService().resyncTeacherLeaveExceptions(teacherId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(vacated.isEmpty
                ? 'Resynced — $teacherName has no current/upcoming approved leave overlapping their weekly schedule.'
                : 'Resynced — ${vacated.length} class unit(s) vacated for $teacherName.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Resync failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _reject(String id) async {
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161616),
        title: const Text('Reject leave request', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: reasonController,
          autofocus: true,
          maxLines: 3,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Reason (optional)',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF87171)),
            onPressed: () => Navigator.of(ctx).pop(reasonController.text.trim()),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (reason == null) return; // cancelled
    if (!mounted) return;

    setState(() => _busyIds.add(id));
    try {
      await _leaveService.rejectLeave(
        leaveRequestId: id,
        adminId: FirebaseAuth.instance.currentUser?.uid ?? 'unknown_admin',
        reason: reason,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reject: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0B0B0B),
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        // Deliberately no .where()/.orderBy() — a single unfiltered listen
        // on the whole collection needs zero Firestore composite indexes
        // and is unambiguous for security rules to evaluate.
        stream: FirebaseFirestore.instance.collection('leave_requests').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load leave requests:\n${snapshot.error}',
                  style: const TextStyle(color: Color(0xFFF87171)),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }

          final docs = [...snapshot.data!.docs];
          docs.sort((a, b) {
            final ta = a.data()['createdAt'];
            final tb = b.data()['createdAt'];
            final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
            final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
            return db.compareTo(da); // newest first
          });

          if (docs.isEmpty) {
            return const Center(
              child: Text(
                'No leave requests yet.',
                style: TextStyle(color: Colors.white60, fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data();
              final id = doc.id;
              final status = (data['status'] as String?) ?? 'pending';
              final teacherName = (data['teacherName'] as String?) ?? 'Unknown teacher';
              final reason = (data['reason'] as String?) ?? '';
              final rejectionReason = (data['rejectionReason'] as String?) ?? '';
              final dateLabel = _dateLabel(
                data['startDate'] as Timestamp?,
                data['endDate'] as Timestamp?,
              );
              final isBusy = _busyIds.contains(id);
              final color = _statusColor(status);

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF161616),
                  borderRadius: BorderRadius.circular(14),
                  border: Border(left: BorderSide(color: color, width: 4)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  teacherName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  dateLabel,
                                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              status[0].toUpperCase() + status.substring(1),
                              style: TextStyle(
                                color: color,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (reason.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(reason, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      ],
                      if (status == 'rejected' && rejectionReason.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Reason for rejection: $rejectionReason',
                          style: const TextStyle(color: Color(0xFFF87171), fontSize: 13),
                        ),
                      ],
                      if (status == 'approved') ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: isBusy
                                ? null
                                : () => _resync(
                                      id,
                                      (data['teacherId'] as String?) ?? '',
                                      teacherName,
                                    ),
                            icon: const Icon(Icons.sync, size: 16),
                            label: const Text('Resync schedule'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            ),
                          ),
                        ),
                      ],
                      if (status == 'pending') ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: isBusy ? null : () => _reject(id),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFF87171),
                                  side: const BorderSide(color: Color(0xFFF87171)),
                                ),
                                child: const Text('Reject'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: isBusy ? null : () => _approve(id),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF4ADE80),
                                  foregroundColor: Colors.black,
                                ),
                                child: isBusy
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Text('Approve'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
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
