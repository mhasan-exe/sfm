import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/services/audit_log_service.dart';

/// Embedded as a tab inside AdminScreen (not used standalone) — no Scaffold
/// or AppBar here, that would have nested awkwardly inside the admin shell.
class AdminLogsPage extends StatelessWidget {
  const AdminLogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auditLogService = AuditLogService();

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 600;

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: auditLogService.watchAuditLogs(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load audit logs: ${snapshot.error}',
                    style: const TextStyle(color: Colors.redAccent),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final logs = snapshot.data ?? [];
            if (logs.isEmpty) {
              return const Center(child: Text('No audit logs yet.'));
            }

            return ListView.separated(
              padding: EdgeInsets.all(narrow ? 10 : 14),
              itemCount: logs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final log = logs[index];
                final action = log['action']?.toString() ?? 'unknown_action';
                final adminId = log['adminId']?.toString() ?? '';
                final performedBy = log['performedBy']?.toString() ?? '';
                final timestamp = log['timestamp'] as Timestamp?;

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.white.withValues(alpha: 0.06),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          if (adminId.isNotEmpty)
                            Chip(label: Text('adminId: $adminId')),
                          if (performedBy.isNotEmpty)
                            Chip(label: Text('performedBy: $performedBy')),
                          if (timestamp != null)
                            Chip(
                              label: Text(
                                'at: ${timestamp.toDate().toLocal()}'.split('.').first,
                              ),
                            ),
                        ],
                      ),
                      if (log['details'] != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          log['details'].toString(),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}
