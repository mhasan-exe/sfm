import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/services/announcement_service.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/announcement_model.dart';

/// Sits on top of every tab (mounted once at the app shell level) and
/// blocks interaction with a centered card whenever the signed-in teacher
/// has an admin announcement/event they haven't acknowledged yet. Moves to
/// the next one automatically once the current one is acknowledged.
class AnnouncementPromptOverlay extends StatelessWidget {
  const AnnouncementPromptOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<List<AnnouncementModel>>(
      stream: AnnouncementService().watchUnacknowledgedForUser(uid),
      builder: (context, snapshot) {
        final pending = snapshot.data ?? const [];
        if (pending.isEmpty) return const SizedBox.shrink();

        final announcement = pending.first;
        return _PromptCard(announcement: announcement, uid: uid);
      },
    );
  }
}

class _PromptCard extends StatefulWidget {
  final AnnouncementModel announcement;
  final String uid;
  const _PromptCard({required this.announcement, required this.uid});

  @override
  State<_PromptCard> createState() => _PromptCardState();
}

class _PromptCardState extends State<_PromptCard> {
  bool _acking = false;

  Future<void> _acknowledge() async {
    setState(() => _acking = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      await AnnouncementService().acknowledge(
        widget.announcement.id,
        widget.uid,
        user?.displayName ?? user?.email ?? 'Teacher',
      );
    } catch (_) {
      if (mounted) setState(() => _acking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.announcement;
    final isEvent = a.isEvent;

    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (isEvent ? Colors.amberAccent : Colors.blueAccent)
                                .withValues(alpha: 0.18),
                          ),
                          child: Icon(
                            isEvent ? Icons.event_outlined : Icons.campaign_outlined,
                            color: isEvent ? Colors.amberAccent : Colors.blueAccent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            a.title,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                    if (isEvent && a.eventAt != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.amberAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule, size: 14, color: Colors.amberAccent),
                            const SizedBox(width: 6),
                            Text(
                              DateFormat('EEE, MMM d · h:mm a').format(a.eventAt!),
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.amberAccent),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Text(a.message, style: const TextStyle(fontSize: 14, height: 1.4)),
                    const SizedBox(height: 6),
                    Text(
                      '— ${a.createdByName}',
                      style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.55)),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _acking ? null : _acknowledge,
                        icon: _acking
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check),
                        label: Text(_acking ? 'Acknowledging…' : 'Acknowledge'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
