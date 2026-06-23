import 'package:flutter/material.dart';

import '../../../core/services/break_duty_service.dart';
import '../../../core/services/user_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/break_duty_model.dart';
import '../../../models/user_model.dart';

const _kAllDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Roster for recess/lunch/corridor supervision duties — separate from the
/// class timetable, since these are about covering common areas rather
/// than teaching a class.
class AdminBreakDutyPage extends StatefulWidget {
  const AdminBreakDutyPage({super.key});

  @override
  State<AdminBreakDutyPage> createState() => _AdminBreakDutyPageState();
}

class _AdminBreakDutyPageState extends State<AdminBreakDutyPage> {
  final _service = BreakDutyService();

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Break Duties')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openEditor(null),
          icon: const Icon(Icons.add),
          label: const Text('New duty'),
        ),
        body: SafeArea(
          child: StreamBuilder<List<BreakDutyModel>>(
            stream: _service.watchAll(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final duties = snapshot.data!;
              if (duties.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No break duties yet. Add one to roster teachers for recess/lunch supervision.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                itemCount: duties.length,
                itemBuilder: (context, i) => _dutyCard(duties[i]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _dutyCard(BreakDutyModel duty) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.orangeAccent.withValues(alpha: 0.18),
                  ),
                  child: const Icon(Icons.free_breakfast_outlined, color: Colors.orangeAccent, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(duty.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                        '${duty.startTime} - ${duty.endTime}  ·  ${duty.days.join(', ')}',
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.65)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  onPressed: () => _openEditor(duty),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 19, color: Colors.redAccent),
                  onPressed: () => _confirmDelete(duty),
                ),
              ],
            ),
            if (duty.location.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('📍 ${duty.location}', style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: duty.teacherNames.isEmpty
                  ? [
                      Chip(
                        label: const Text('Unassigned', style: TextStyle(fontSize: 11)),
                        backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                      ),
                    ]
                  : duty.teacherNames
                      .map((n) => Chip(
                            label: Text(n, style: const TextStyle(fontSize: 11)),
                            backgroundColor: Colors.white.withValues(alpha: 0.08),
                          ))
                      .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BreakDutyModel duty) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete break duty?'),
        content: Text('Remove "${duty.name}" from the roster? Assigned teachers will be notified.'),
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
    if (confirm == true) {
      await _service.deleteDuty(duty.id);
    }
  }

  Future<void> _openEditor(BreakDutyModel? existing) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => _BreakDutyEditor(existing: existing)),
    );
  }
}

class _BreakDutyEditor extends StatefulWidget {
  final BreakDutyModel? existing;
  const _BreakDutyEditor({this.existing});

  @override
  State<_BreakDutyEditor> createState() => _BreakDutyEditorState();
}

class _BreakDutyEditorState extends State<_BreakDutyEditor> {
  final _service = BreakDutyService();
  late TextEditingController _nameController;
  late TextEditingController _locationController;
  late TextEditingController _notesController;
  late Set<String> _selectedDays;
  late Set<String> _selectedTeacherIds;
  TimeOfDay _start = const TimeOfDay(hour: 10, minute: 30);
  TimeOfDay _end = const TimeOfDay(hour: 10, minute: 50);
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.name ?? '');
    _locationController = TextEditingController(text: e?.location ?? '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    _selectedDays = (e?.days ?? const []).toSet();
    _selectedTeacherIds = (e?.teacherIds ?? const []).toSet();
    if (e != null) {
      final s = _parse(e.startTime);
      final en = _parse(e.endTime);
      if (s != null) _start = s;
      if (en != null) _end = en;
    }
  }

  TimeOfDay? _parse(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save(List<UserModel> teachers) async {
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give this duty a name')));
      return;
    }
    if (_selectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick at least one day')));
      return;
    }

    setState(() => _saving = true);
    final teacherNames = teachers
        .where((t) => _selectedTeacherIds.contains(t.uid))
        .map((t) => t.name)
        .toList();

    final duty = BreakDutyModel(
      id: widget.existing?.id ?? '',
      name: _nameController.text.trim(),
      days: _kAllDays.where((d) => _selectedDays.contains(d)).toList(),
      startTime: _fmt(_start),
      endTime: _fmt(_end),
      teacherIds: _selectedTeacherIds.toList(),
      teacherNames: teacherNames,
      location: _locationController.text.trim(),
      notes: _notesController.text.trim(),
    );

    try {
      if (widget.existing != null) {
        await _service.updateDuty(duty);
      } else {
        await _service.createDuty(duty);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(widget.existing != null ? 'Edit break duty' : 'New break duty')),
        body: SafeArea(
          child: StreamBuilder<List<UserModel>>(
            stream: UserService().watchTeachers(),
            builder: (context, snapshot) {
              final teachers = snapshot.data ?? const <UserModel>[];
              return ListView(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                children: [
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(labelText: 'Duty name', hintText: 'e.g. Playground Supervision'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _locationController,
                          decoration: const InputDecoration(labelText: 'Location (optional)', hintText: 'e.g. Main Playground'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Time', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final picked = await showTimePicker(context: context, initialTime: _start);
                                  if (!mounted) return;
                                  if (picked != null) setState(() => _start = picked);
                                },
                                child: Text('Start: ${_start.format(context)}'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () async {
                                  final picked = await showTimePicker(context: context, initialTime: _end);
                                  if (!mounted) return;
                                  if (picked != null) setState(() => _end = picked);
                                },
                                child: Text('End: ${_end.format(context)}'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Repeats on', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: _kAllDays.map((d) {
                            final selected = _selectedDays.contains(d);
                            return FilterChip(
                              label: Text(d.substring(0, 3)),
                              selected: selected,
                              onSelected: (sel) => setState(() {
                                if (sel) {
                                  _selectedDays.add(d);
                                } else {
                                  _selectedDays.remove(d);
                                }
                              }),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Assigned teachers', style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        if (teachers.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text('Loading teachers…'),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: teachers.map((t) {
                              final selected = _selectedTeacherIds.contains(t.uid);
                              return FilterChip(
                                label: Text(t.name.isEmpty ? t.email : t.name),
                                selected: selected,
                                onSelected: (sel) => setState(() {
                                  if (sel) {
                                    _selectedTeacherIds.add(t.uid);
                                  } else {
                                    _selectedTeacherIds.remove(t.uid);
                                  }
                                }),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: TextField(
                      controller: _notesController,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Notes (optional)'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : () => _save(teachers),
                      icon: _saving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: Text(_saving ? 'Saving…' : 'Save duty'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
