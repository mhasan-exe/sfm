import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/services/admin_config_service.dart';
import '../../../core/services/timetable_preset_service.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../core/widgets/app_background.dart';
import '../../../models/timetable_preset_model.dart';
import 'admin_presets_page.dart';

/// Compact, section-based Settings page. Replaces the old always-expanded
/// giant-form layout with collapsible ExpansionTiles so the whole page
/// fits comfortably on mobile and doesn't require scrolling past a wall of
/// fields just to flip one switch.
class AdminConfigPage extends StatefulWidget {
  const AdminConfigPage({super.key});

  @override
  State<AdminConfigPage> createState() => _AdminConfigPageState();
}

class _AdminConfigPageState extends State<AdminConfigPage> {
  final configService = AdminConfigService();
  bool _loading = true;

  // Schedule controllers
  final genTimeController = TextEditingController();
  final genDayController = TextEditingController();
  final resetTimeController = TextEditingController();
  final resetDayController = TextEditingController();

  // Scheduled-run mode: regenerate fresh, or load a saved preset instead.
  String _generationMode = 'generate';
  String? _selectedPresetId;

  // Settings
  bool allowFixtureMarketplace = true;
  bool allowTeacherLeaves = true;
  bool requireLeaveApproval = true;
  bool allowQuotaOverride = true;
  bool breakDutyRemindersEnabled = true;
  int maxUnitsPerTeacher = 24;
  String unifiedCutoffTime = '12:45';
  int rejectionCooldownHours = 24;
  int fixtureClaimWindowHours = 1;
  int fixtureAutoAssignMinutes = 5;
  Set<int> reminderOffsets = {30, 15};

  static const _dayOptions = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final genSchedule = await configService.getTimetableGenerationSchedule();
      final resetSchedule = await configService.getWorkloadResetSchedule();
      final settings = await configService.getSystemSettings();

      if (genSchedule != null) {
        genTimeController.text = genSchedule['generationTime'] ?? '';
        genDayController.text = genSchedule['generationDay'] ?? '';
        _generationMode = genSchedule['mode']?.toString() ?? 'generate';
        _selectedPresetId = genSchedule['presetId']?.toString();
      }
      if (resetSchedule != null) {
        resetTimeController.text = resetSchedule['resetTime'] ?? '';
        resetDayController.text = resetSchedule['resetDay'] ?? '';
      }
      if (settings != null) {
        allowFixtureMarketplace = settings['allowFixtureMarketplace'] ?? true;
        allowTeacherLeaves = settings['allowTeacherLeaveRequests'] ?? true;
        requireLeaveApproval = settings['requireApprovalForLeaves'] ?? true;
        allowQuotaOverride = settings['allowQuotaOverride'] ?? true;
        breakDutyRemindersEnabled = settings['breakDutyRemindersEnabled'] ?? true;
        maxUnitsPerTeacher = (settings['maxUnitsPerTeacher'] as num?)?.toInt() ?? 24;
        unifiedCutoffTime = settings['unifiedCutoffTime'] ??
            settings['sameDayLeaveCutoffTime'] ??
            '12:45';
        rejectionCooldownHours =
            (settings['rejectionCooldownHours'] as num?)?.toInt() ?? 24;
        fixtureClaimWindowHours =
            (settings['fixtureClaimWindowHours'] as num?)?.toInt() ?? 1;
        fixtureAutoAssignMinutes =
            (settings['fixtureAutoAssignMinutes'] as num?)?.toInt() ?? 5;
        final rawOffsets = settings['reminderOffsetsMinutes'];
        if (rawOffsets is List && rawOffsets.isNotEmpty) {
          reminderOffsets = rawOffsets.map((e) => (e as num).toInt()).toSet();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading settings: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickCutoffTime() async {
    final parts = unifiedCutoffTime.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 12,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 45,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() {
        unifiedCutoffTime =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Future<void> _saveTimetableGenSchedule() async {
    if (genTimeController.text.isEmpty || genDayController.text.isEmpty) {
      _toast('Please fill all fields');
      return;
    }
    if (_generationMode == 'preset' && (_selectedPresetId == null || _selectedPresetId!.isEmpty)) {
      _toast('Pick a preset to load, or switch back to "Generate fresh"');
      return;
    }
    try {
      await configService.setTimetableGenerationSchedule(
        generationTime: genTimeController.text.trim(),
        generationDay: genDayController.text.trim(),
        mode: _generationMode,
        presetId: _generationMode == 'preset' ? _selectedPresetId : null,
      );
      _toast('Timetable generation schedule saved');
    } catch (e) {
      _toast('Error: $e');
    }
  }

  Future<void> _saveWorkloadResetSchedule() async {
    if (resetTimeController.text.isEmpty || resetDayController.text.isEmpty) {
      _toast('Please fill all fields');
      return;
    }
    try {
      await configService.setWorkloadResetSchedule(
        resetTime: resetTimeController.text.trim(),
        resetDay: resetDayController.text.trim(),
      );
      _toast('Workload reset schedule saved');
    } catch (e) {
      _toast('Error: $e');
    }
  }

  Future<void> _saveSystemSettings() async {
    try {
      final offsets = reminderOffsets.toList()..sort((a, b) => b.compareTo(a));
      await configService.updateSystemSettings(
        allowFixtureMarketplace: allowFixtureMarketplace,
        allowTeacherLeaveRequests: allowTeacherLeaves,
        requireApprovalForLeaves: requireLeaveApproval,
        maxUnitsPerTeacher: maxUnitsPerTeacher,
        unifiedCutoffTime: unifiedCutoffTime,
        rejectionCooldownHours: rejectionCooldownHours,
        fixtureClaimWindowHours: fixtureClaimWindowHours,
        fixtureAutoAssignMinutes: fixtureAutoAssignMinutes,
        breakDutyRemindersEnabled: breakDutyRemindersEnabled,
        reminderOffsetsMinutes: offsets,
        allowQuotaOverride: allowQuotaOverride,
      );
      _toast('Settings saved — applies to leave, fixtures & exchanges instantly');
    } catch (e) {
      _toast('Error: $e');
    }
  }

  Future<void> _manualTriggerGeneration() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run Timetable Automation'),
        content: Text(
          _generationMode == 'preset'
              ? 'This loads the saved preset into the live timetable (auto-backing up the current one first). Make sure you\'ve clicked Save above so the latest preset choice is used. Continue?'
              : 'This will regenerate the weekly timetable for every class using each class\'s configured teachers and quotas. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final user = FirebaseAuth.instance.currentUser;
      final adminId = user?.uid ?? 'unknown_admin';
      final summary = await configService.triggerTimetableGeneration(
        triggeredBy: adminId,
        triggeredByName: user?.displayName ?? user?.email,
      );
      _toast(
        'Generated ${summary.classesGenerated} class(es)'
        '${summary.classesSkipped > 0 ? ', ${summary.classesSkipped} skipped' : ''}'
        '${summary.warnings.isNotEmpty ? ' — ${summary.warnings.length} warning(s)' : ''}.',
      );
    } catch (e) {
      _toast('Error: $e');
    }
  }

  Future<void> _manualTriggerReset() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Workload Counters'),
        content: const Text('This zeroes every teacher\'s default/fixture unit counts. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final adminId = FirebaseAuth.instance.currentUser?.uid ?? 'unknown_admin';
      await configService.triggerWorkloadReset(triggeredBy: adminId);
      _toast('Workload counters reset');
    } catch (e) {
      _toast('Error: $e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    genTimeController.dispose();
    genDayController.dispose();
    resetTimeController.dispose();
    resetDayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Settings')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    _section(
                      icon: Icons.timer_outlined,
                      title: 'Cutoffs & anti-spam',
                      subtitle: 'Unified cutoff · $unifiedCutoffTime  ·  cooldown ${rejectionCooldownHours}h',
                      initiallyExpanded: true,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Unified cutoff time'),
                          subtitle: const Text(
                              'Same-day leave requests, fixture claims, fixture exchanges and slot exchanges all lock after this time.'),
                          trailing: OutlinedButton(
                            onPressed: _pickCutoffTime,
                            child: Text(unifiedCutoffTime),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Rejection cooldown'),
                          subtitle: const Text('How long a teacher must wait after a rejected leave request before resubmitting.'),
                          trailing: _stepper(
                            value: rejectionCooldownHours,
                            suffix: 'h',
                            min: 1,
                            max: 168,
                            onChanged: (v) => setState(() => rejectionCooldownHours = v),
                          ),
                        ),
                      ],
                    ),
                    _section(
                      icon: Icons.sports_soccer_outlined,
                      title: 'Fixtures & cover',
                      subtitle: 'Claim window ${fixtureClaimWindowHours}h · auto-assign ${fixtureAutoAssignMinutes}m before start',
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow fixture marketplace'),
                          subtitle: const Text('Teachers can browse & claim open cover slots.'),
                          trailing: Switch(
                            value: allowFixtureMarketplace,
                            onChanged: (v) => setState(() => allowFixtureMarketplace = v),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Claim window'),
                          subtitle: const Text('How long before a unit starts that it escalates to "needs manual assignment".'),
                          trailing: _stepper(
                            value: fixtureClaimWindowHours,
                            suffix: 'h',
                            min: 1,
                            max: 12,
                            onChanged: (v) => setState(() => fixtureClaimWindowHours = v),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Auto-assign before start'),
                          subtitle: const Text('If still unclaimed this close to the unit starting, the best available teacher is auto-assigned.'),
                          trailing: _stepper(
                            value: fixtureAutoAssignMinutes,
                            suffix: 'm',
                            min: 1,
                            max: 60,
                            onChanged: (v) => setState(() => fixtureAutoAssignMinutes = v),
                          ),
                        ),
                      ],
                    ),
                    _section(
                      icon: Icons.event_busy_outlined,
                      title: 'Leave requests',
                      subtitle: requireLeaveApproval ? 'Approval required' : 'Auto-approved',
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow teacher leave requests'),
                          trailing: Switch(
                            value: allowTeacherLeaves,
                            onChanged: (v) => setState(() => allowTeacherLeaves = v),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Require admin approval'),
                          trailing: Switch(
                            value: requireLeaveApproval,
                            onChanged: (v) => setState(() => requireLeaveApproval = v),
                          ),
                        ),
                      ],
                    ),
                    _section(
                      icon: Icons.rule_outlined,
                      title: 'Workload quota',
                      subtitle: 'Cap $maxUnitsPerTeacher units/week · override ${allowQuotaOverride ? "allowed" : "blocked"}',
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Max units per teacher / week'),
                          subtitle: const Text('Hit anywhere (timetable drag, fixture claim/assign, exchange) and the action is actively blocked, not just warned about.'),
                          trailing: _stepper(
                            value: maxUnitsPerTeacher,
                            suffix: '',
                            min: 1,
                            max: 40,
                            onChanged: (v) => setState(() => maxUnitsPerTeacher = v),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow admin override'),
                          subtitle: const Text('Lets admins confirm "assign anyway" past quota from the timetable editor.'),
                          trailing: Switch(
                            value: allowQuotaOverride,
                            onChanged: (v) => setState(() => allowQuotaOverride = v),
                          ),
                        ),
                      ],
                    ),
                    _section(
                      icon: Icons.notifications_active_outlined,
                      title: 'Reminders',
                      subtitle: 'Notify ${reminderOffsets.toList().reversed.join(" & ")} min before each unit',
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [10, 15, 20, 30].map((m) {
                            final selected = reminderOffsets.contains(m);
                            return FilterChip(
                              label: Text('$m min'),
                              selected: selected,
                              onSelected: (sel) => setState(() {
                                if (sel) {
                                  reminderOffsets.add(m);
                                } else if (reminderOffsets.length > 1) {
                                  reminderOffsets.remove(m);
                                }
                              }),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Break duty reminders'),
                          subtitle: const Text('Also remind teachers ahead of their break/recess duties.'),
                          trailing: Switch(
                            value: breakDutyRemindersEnabled,
                            onChanged: (v) => setState(() => breakDutyRemindersEnabled = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saveSystemSettings,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save all settings'),
                      ),
                    ),
                    _section(
                      icon: Icons.schedule_outlined,
                      title: 'Automation schedules',
                      subtitle: 'Timetable generation & workload reset timing',
                      children: [
                        _miniLabel('Timetable generation'),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: genTimeController,
                                decoration: const InputDecoration(labelText: 'Time (HH:mm)', isDense: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: genDayController.text.isNotEmpty &&
                                        _dayOptions.contains(genDayController.text)
                                    ? genDayController.text
                                    : null,
                                decoration: const InputDecoration(labelText: 'Day', isDense: true),
                                items: _dayOptions
                                    .map((d) => DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: (v) => genDayController.text = v ?? '',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ChoiceChip(
                                label: const Text('Generate fresh'),
                                selected: _generationMode == 'generate',
                                onSelected: (_) => setState(() => _generationMode = 'generate'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ChoiceChip(
                                label: const Text('Load preset'),
                                selected: _generationMode == 'preset',
                                onSelected: (_) => setState(() => _generationMode = 'preset'),
                              ),
                            ),
                          ],
                        ),
                        if (_generationMode == 'preset') ...[
                          const SizedBox(height: 8),
                          StreamBuilder<List<TimetablePresetModel>>(
                            stream: TimetablePresetService().watchPresets(),
                            builder: (context, presetSnap) {
                              final presets = presetSnap.data ?? const [];
                              if (presets.isEmpty) {
                                return Text(
                                  'No saved presets yet — save the current timetable as a preset first.',
                                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6)),
                                );
                              }
                              final validId = presets.any((p) => p.id == _selectedPresetId)
                                  ? _selectedPresetId
                                  : null;
                              return DropdownButtonFormField<String>(
                                initialValue: validId,
                                decoration: const InputDecoration(labelText: 'Preset to load', isDense: true),
                                items: presets
                                    .map((p) => DropdownMenuItem(
                                          value: p.id,
                                          child: Text(
                                            '${p.name} (${p.slotCount} slots)',
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ))
                                    .toList(),
                                onChanged: (v) => setState(() => _selectedPresetId = v),
                              );
                            },
                          ),
                        ],
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => const AdminPresetsPage()),
                            ),
                            icon: const Icon(Icons.save_outlined, size: 16),
                            label: const Text('Manage presets', style: TextStyle(fontSize: 12.5)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _saveTimetableGenSchedule,
                                icon: const Icon(Icons.save, size: 18),
                                label: const Text('Save'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _manualTriggerGeneration,
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('Run now'),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 24),
                        _miniLabel('Workload reset'),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: resetTimeController,
                                decoration: const InputDecoration(labelText: 'Time (HH:mm)', isDense: true),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: resetDayController.text.isNotEmpty &&
                                        _dayOptions.contains(resetDayController.text)
                                    ? resetDayController.text
                                    : null,
                                decoration: const InputDecoration(labelText: 'Day', isDense: true),
                                items: _dayOptions
                                    .map((d) => DropdownMenuItem(value: d, child: Text(d, overflow: TextOverflow.ellipsis)))
                                    .toList(),
                                onChanged: (v) => resetDayController.text = v ?? '',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _saveWorkloadResetSchedule,
                                icon: const Icon(Icons.save, size: 18),
                                label: const Text('Save'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                                onPressed: _manualTriggerReset,
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('Run now'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    _section(
                      icon: Icons.history_outlined,
                      title: 'Recent admin actions',
                      subtitle: 'Audit log preview',
                      children: [
                        StreamBuilder<List<Map<String, dynamic>>>(
                          stream: configService.watchAuditLogs(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            final logs = snapshot.data!.take(8).toList();
                            if (logs.isEmpty) {
                              return const Text('No actions logged yet.');
                            }
                            return Column(
                              children: logs
                                  .map((log) => Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 4),
                                        child: Text(
                                          '${(log['action'] ?? '').toString().replaceAll('_', ' ')}',
                                          style: const TextStyle(fontSize: 12.5),
                                        ),
                                      ))
                                  .toList(),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _miniLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4),
        ),
      );

  Widget _stepper({
    required int value,
    required String suffix,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        SizedBox(
          width: 44,
          child: Text(
            '$value$suffix',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline, size: 20),
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            leading: Icon(icon, size: 22),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
            subtitle: Text(subtitle, style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: 0.6))),
            children: children,
          ),
        ),
      ),
    );
  }
}
