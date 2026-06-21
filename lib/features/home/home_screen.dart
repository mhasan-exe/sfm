import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_animate/flutter_animate.dart';


import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import 'widgets/home_status_card.dart';
import 'widgets/leave_request_dialog.dart';
import 'widgets/my_leave_requests_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppTheme.pagePadding(context),
      children: [
StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('announcements')
              .where('priority', isEqualTo: 'high')
              .orderBy('timestamp', descending: true)
              .limit(1)
              .snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? [];
            if (docs.isEmpty) return const SizedBox.shrink();

            final announcement = docs.first.data();
            final title = announcement['title']?.toString().trim();
            if (title == null || title.isEmpty) return const SizedBox.shrink();

            return GlassCard(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            )
                .animate()
                .fadeIn()
                .slideY(begin: 0.05);
          },
        ),

const SizedBox(height: 14),

        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FutureBuilder<String?>(
                future: Future.value(FirebaseAuth.instance.currentUser?.uid),
                builder: (context, snapshot) {
                  final teacherId = snapshot.data;

                  if (snapshot.connectionState != ConnectionState.done) {
                    return const SizedBox(
                      height: 60,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  if (teacherId == null || teacherId.isEmpty) {
                    return const Text('Not authenticated');
                  }

                  return HomeStatusCard(teacherId: teacherId);
                },
              ),
            ],
          ),
        )
            .animate()
            .fadeIn()
            .slideY(begin: 0.1),

        const SizedBox(height: 20),


        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) {
                      final firebaseUser = FirebaseAuth.instance.currentUser;
                      if (firebaseUser == null) {
                        return const AlertDialog(
                          title: Text('Submit Leave'),
                          content: Text('Not authenticated'),
                        );
                      }

                      return LeaveRequestDialog(
                        teacherId: firebaseUser.uid,
                        teacherName: firebaseUser.displayName ??
                            firebaseUser.email ??
                            'Teacher',
                      );
                    },
                  );
                },
                icon: const Icon(Icons.event_busy),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Leave'),
                ),
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Exchange'),
                      content: const Text(
                        'Slot exchanges are temporarily under development while we polish the experience. Check back soon!',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.swap_horiz),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Exchange'),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        TextButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MyLeaveRequestsScreen()),
            );
          },
          icon: const Icon(Icons.history, size: 18),
          label: const Text('View My Leave Requests'),
        ),
      ],
    );
  }
}

