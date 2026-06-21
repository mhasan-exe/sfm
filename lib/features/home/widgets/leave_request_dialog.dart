import 'package:flutter/material.dart';

import '../../../core/services/leave_service.dart';

class LeaveRequestDialog extends StatefulWidget {
  const LeaveRequestDialog({
    super.key,
    required this.teacherId,
    required this.teacherName,
  });

  final String teacherId;
  final String teacherName;

  @override
  State<LeaveRequestDialog> createState() => _LeaveRequestDialogState();
}

class _LeaveRequestDialogState extends State<LeaveRequestDialog> {
  // Default to tomorrow, not today: the backend blocks same-day leave
  // requests unless an admin has explicitly configured a cutoff time in
  // System Settings (most fresh installs haven't), so defaulting to today
  // silently fails on first use. Tomorrow is the safe, always-valid default;
  // the admin can still explicitly pick today via the date picker.
  DateTime _startDate = DateTime.now().add(const Duration(days: 1));
  DateTime _endDate = DateTime.now().add(const Duration(days: 1));

  final _reasonController = TextEditingController(text: 'Personal Leave');

  // If the backend later supports duration fields, we can map this.
  // For now, we infer days from start/end.
  int get _days => _endDate.difference(_startDate).inDays + 1;

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _startDate = picked;
      if (_endDate.isBefore(_startDate)) {
        _endDate = _startDate;
      }
    });
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _endDate = picked;
      if (_endDate.isBefore(_startDate)) {
        _startDate = _endDate;
      }
    });
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reason is required')),
      );
      return;
    }

    // Prevent duplicate/overlapping approved leaves.
    final hasOverlap = await LeaveService().hasApprovedLeaveOverlap(
      teacherId: widget.teacherId,
      startDate: _startDate,
      endDate: _endDate,
    );

    if (hasOverlap) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You already have an approved leave for this period.'),
        ),
      );
      return;
    }

    await LeaveService().submitLeave(
      teacherId: widget.teacherId,
      teacherName: widget.teacherName,
      startDate: _startDate,
      endDate: _endDate,
      reason: reason,
    );
  }


  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = screenWidth < 480 ? screenWidth * 0.88 : 420.0;

    return AlertDialog(
      title: const Text('Submit Leave'),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickStartDate,
                      icon: const Icon(Icons.date_range),
                      label: Text(
                        'Start: ${_startDate.toLocal().toString().split(' ').first}',
                        textAlign: TextAlign.left,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickEndDate,
                      icon: const Icon(Icons.date_range),
                      label: Text(
                        'End: ${_endDate.toLocal().toString().split(' ').first}',
                        textAlign: TextAlign.left,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Duration'),
                  Chip(label: Text('$_days day${_days == 1 ? '' : 's'}')),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  border: OutlineInputBorder(),
                  hintText: 'Enter reason for leave',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              // Attachment UI: intentionally postponed unless storage integration exists.
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Attachment UI is postponed (no storage integration configured).',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: () async {
            try {
              await _submit();
              if (!context.mounted) return;
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Leave request submitted')),
              );
            } catch (e) {
              final msg = e.toString().toLowerCase();
              final friendly = msg.contains('same-day')
                  ? 'Same-day leave isn\'t available right now (your admin hasn\'t set a cutoff time for it). Please pick a future date instead.'
                  : 'Failed: $e';
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(friendly)),
              );
            }
          },
          icon: const Icon(Icons.send),
          label: const Text('Submit'),
        ),
      ],
    );
  }
}

