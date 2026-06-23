import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/services/announcement_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/announcement_model.dart';

/// Admin broadcast center: push a message or a scheduled event to every
/// teacher. Each shows as a blocking "acknowledge" prompt on their device;
/// events additionally get periodic reminders until the event time passes.
class AdminAnnouncementsPage extends StatefulWidget {
  const AdminAnnouncementsPage({super.key});

  @override
  State<AdminAnnouncementsPage> createState() => _AdminAnnouncementsPageState();
}

class _AdminAnnouncementsPageState extends State<AdminAnnouncementsPage> {
  final _service = AnnouncementService();

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Announcements & Events')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openComposer(context),
          icon: const Icon(Icons.campaign_outlined),
          label: const Text('New broadcast'),
        ),
        body: SafeArea(
          child: StreamBuilder<List<AnnouncementModel>>(
            stream: _service.watchAllAnnouncements(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.data!;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No announcements yet. Push a message or schedule an event — every teacher gets a blocking prompt until they acknowledge it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                itemCount: items.length,
                itemBuilder: (context, i) => _card(items[i]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _card(AnnouncementModel a) {
    final isEvent = a.isEvent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isEvent ? Icons.event_outlined : Icons.campaign_outlined,
                  color: isEvent ? Colors.amberAccent : Colors.blueAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                if (!a.active)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Ended', style: TextStyle(fontSize: 10.5)),
                  )
                else if (isEvent && a.eventHasPassed)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Past', style: TextStyle(fontSize: 10.5, color: Colors.greenAccent)),
                  ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'end') _endNow(a);
                    if (v == 'delete') _confirmDelete(a);
                  },
                  itemBuilder: (context) => [
                    if (a.active) const PopupMenuItem(value: 'end', child: Text('End now')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(a.message, style: const TextStyle(fontSize: 13)),
            if (isEvent && a.eventAt != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule, size: 13, color: Colors.amberAccent),
                    const SizedBox(width: 6),
                    Text(
                      DateFormat('EEE, MMM d · h:mm a').format(a.eventAt!),
                      style: const TextStyle(fontSize: 11.5, color: Colors.amberAccent, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: _service.getAcknowledgementCount(a.id),
              builder: (context, ackSnap) {
                final count = ackSnap.data ?? 0;
                return Text(
                  '$count acknowledged · pushed ${DateFormat('MMM d, h:mm a').format(a.createdAt)}',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.55)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _endNow(AnnouncementModel a) async {
    await _service.endAnnouncement(a.id);
  }

  Future<void> _confirmDelete(AnnouncementModel a) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete announcement?'),
        content: Text('Remove "${a.title}" entirely, including acknowledgement records.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) await _service.deleteAnnouncement(a.id);
  }

  Future<void> _openComposer(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const _AnnouncementComposer()),
    );
  }
}

class _AnnouncementComposer extends StatefulWidget {
  const _AnnouncementComposer();

  @override
  State<_AnnouncementComposer> createState() => _AnnouncementComposerState();
}

class _AnnouncementComposerState extends State<_AnnouncementComposer> {
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();
  bool _isEvent = false;
  DateTime? _eventDate;
  TimeOfDay? _eventTime;
  bool _sending = false;

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _eventDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _eventTime ?? TimeOfDay.now(),
    );
    if (!mounted) return;
    if (picked != null) setState(() => _eventTime = picked);
  }

  Future<void> _send() async {
    final title = _titleController.text.trim();
    final message = _messageController.text.trim();
    if (title.isEmpty || message.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title and message are required')),
      );
      return;
    }

    DateTime? eventAt;
    if (_isEvent) {
      if (_eventDate == null || _eventTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a date and time for the event')),
        );
        return;
      }
      eventAt = DateTime(
        _eventDate!.year,
        _eventDate!.month,
        _eventDate!.day,
        _eventTime!.hour,
        _eventTime!.minute,
      );
    }

    setState(() => _sending = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      await AnnouncementService().createAnnouncement(
        title: title,
        message: message,
        createdBy: user?.uid ?? 'admin',
        createdByName: user?.displayName ?? user?.email ?? 'Admin',
        eventAt: eventAt,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('New broadcast')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. Staff Meeting'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _messageController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Message',
                        hintText: 'What do teachers need to know?',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _isEvent,
                      onChanged: (v) => setState(() => _isEvent = v),
                      title: const Text('This is a scheduled event'),
                      subtitle: const Text('e.g. a meeting — teachers get periodic reminders until it happens.'),
                    ),
                    if (_isEvent) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickDate,
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: Text(_eventDate == null
                                  ? 'Pick date'
                                  : DateFormat('MMM d, yyyy').format(_eventDate!)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _pickTime,
                              icon: const Icon(Icons.schedule, size: 16),
                              label: Text(_eventTime == null ? 'Pick time' : _eventTime!.format(context)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_outlined),
                  label: Text(_sending ? 'Sending…' : 'Push to all teachers'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
