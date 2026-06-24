// ignore_for_file: use_build_context_synchronously

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import '../../../core/services/admin_config_service.dart';
import '../../../core/services/admin_service.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/services/clash_handling_mode.dart';
import '../../../core/services/timetable_service.dart';
import '../../../core/utils/timetable_generator.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/class_model.dart';
import '../../../models/time_profile_model.dart';
import '../../../models/timetable_slot_model.dart';
import '../../../core/services/leave_service.dart';

/// Process-wide cache of every teacher's busy (day, start, end) blocks
/// across all classes, plus the school's max-units-per-teacher cap.
/// Refreshed whenever the timetable editor opens or an assignment changes,
/// and read synchronously by the roster/grid/teacher-picker so dragging a
/// teacher visibly greys out busy destinations and busy teachers without
/// each cell needing its own Firestore round-trip.
class TeacherBusyCache {
  TeacherBusyCache._();
  static final TeacherBusyCache instance = TeacherBusyCache._();

  final ValueNotifier<Map<String, List<BusyBlock>>> notifier =
      ValueNotifier<Map<String, List<BusyBlock>>>({});
  int maxUnits = 24;

  Future<void> refresh() async {
    try {
      notifier.value = await TimetableService().buildAllTeacherBusyBlocks();
    } catch (_) {}
    try {
      maxUnits = await AdminConfigService().getMaxUnitsPerTeacher();
    } catch (_) {}
  }

  bool isBusy(String teacherId, String day, String start, String end) {
    if (teacherId.isEmpty || day.isEmpty || start.isEmpty || end.isEmpty) {
      return false;
    }
    return TimetableService()
        .isTeacherBusyAt(notifier.value, teacherId, day, start, end);
  }

  int totalUnits(String teacherId) => notifier.value[teacherId]?.length ?? 0;

  bool isAtOrOverCapacity(String teacherId) => totalUnits(teacherId) >= maxUnits;
}




class AdminTimetablePage extends StatefulWidget {
  final String classId;

  const AdminTimetablePage({super.key, required this.classId});

  @override
  State<AdminTimetablePage> createState() => _AdminTimetablePageState();
}

class _AdminTimetablePageState extends State<AdminTimetablePage> {
  final _timetable = TimetableService();
  final _adminService = AdminService();
  final _audit = AuditLogService();

  // kept from original file (not used in current UI logic)
  final _leaveService = LeaveService();


  bool _showDaily = false;
  DateTime _selectedDate = DateTime.now();

  bool _showQuotaConfigure = false;
  bool _savingQuotas = false;
  String _teacherSearch = '';

  final List<ClassTeacherAssignment> _quotaTeachers = [];

  @override
  void initState() {
    super.initState();
    _verifyAdmin();
    _loadCurrentQuotas();
    TeacherBusyCache.instance.refresh();
  }

  Future<void> _verifyAdmin() async {
    final ok = await _adminService.isAdmin();
    if (!ok && mounted) Navigator.of(context).pop();
  }

  Future<void> _loadCurrentQuotas() async {
    final cls = await _timetable.getClass(widget.classId);
    if (!mounted) return;
    _quotaTeachers
      ..clear()
      ..addAll(cls?.teachers ?? const []);
    setState(() {});
  }

  Future<GenerationOutcome> _generateWeekly() async {
    await _timetable.ensureWeeklyScaffold(widget.classId);
    final outcome = await _timetable.generateAndApplyClassTimetable(
      classId: widget.classId,
    );

    await _audit.log(
      action: 'generate_weekly_timetable',
      details: {'classId': widget.classId},
    );

    return outcome;
  }

  Future<void> _onGeneratePressed(BuildContext context) async {
    try {
      final outcome = await _generateWeekly();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            'Generated ${outcome.assigned}/${outcome.total} slots.'
            '${outcome.warnings.isNotEmpty ? ' ${outcome.warnings.length} warning(s) — see audit log.' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Generate failed: $e')),
      );
    }
  }

  Future<void> _onRefreshViewPressed(BuildContext context) async {
    // Exceptions are written the moment a leave is approved, an exchange is
    // confirmed, or a fixture is covered — there is no "materialize daily"
    // step to run any more (the old `daily_timetables` collection this used
    // to build is gone). This button now just nudges a rebuild, which is
    // occasionally useful right after another admin's change.
    if (mounted) setState(() {});
  }

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  void _setClassTeacher(int index, bool value) {
    if (index < 0 || index >= _quotaTeachers.length) return;

    setState(() {
      if (!value) {
        _quotaTeachers[index] =
            _quotaTeachers[index].copyWith(isClassTeacher: false);
        return;
      }

      for (var i = 0; i < _quotaTeachers.length; i++) {
        _quotaTeachers[i] =
            _quotaTeachers[i].copyWith(isClassTeacher: i == index);
      }
    });
  }

  Future<void> _saveQuotasAndSync() async {
    if (_quotaTeachers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one teacher quota.')),
      );
      return;
    }

    final classTeachers = _quotaTeachers.where((t) => t.isClassTeacher).toList();
    if (classTeachers.length > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only one class teacher is allowed.')),
      );
      return;
    }

    setState(() => _savingQuotas = true);
    try {
      await _timetable.ensureWeeklyScaffold(widget.classId);

      await _timetable.setClassTeacherConfig(
        classId: widget.classId,
        teachers: _quotaTeachers,
      );

      await _audit.log(
        action: 'save_teacher_quotas',
        details: {
          'classId': widget.classId,
          'teacherCount': _quotaTeachers.length,
        },
      );

      final outcome = await _timetable.generateAndApplyClassTimetable(
        classId: widget.classId,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            'Quotas saved. Generated ${outcome.assigned}/${outcome.total} slots.'
            '${outcome.warnings.isNotEmpty ? ' ${outcome.warnings.length} warning(s).' : ''}',
          ),
        ),
      );

      setState(() => _showQuotaConfigure = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save quotas: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingQuotas = false);
    }
  }

  Widget _buildModeChip() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ChoiceChip(
          label: const Text('Weekly'),
          selected: !_showDaily,
          onSelected: (_) => setState(() => _showDaily = false),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('Daily'),
          selected: _showDaily,
          onSelected: (_) => setState(() => _showDaily = true),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Admin Timetable (Weekly + Daily)'),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            final topPad = narrow ? 12.0 : 16.0;
            final sidePad = narrow ? 12.0 : 16.0;

            return SingleChildScrollView(
              child: Column(
                children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(sidePad, topPad, sidePad, 8),
                  child: narrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Class: ${widget.classId}',
                              style: Theme.of(context).textTheme.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: _buildModeChip(),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Class: ${widget.classId}',
                                style: Theme.of(context).textTheme.titleLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _buildModeChip(),
                          ],
                        ),
                ),

                if (_showDaily)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Daily view for ${DateFormat('EEE, MMM dd').format(_selectedDate)}',
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: () async {
                                final now = DateTime.now();
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _selectedDate,
                                  firstDate: now.subtract(const Duration(days: 365)),
                                  lastDate: now.add(const Duration(days: 365)),
                                );
                                if (picked == null) return;
                                if (!mounted) return;
                                setState(() => _selectedDate = picked);
                                await _materializeDailyForSelectedDate();
                                if (!mounted) return;
                                setState(() {});
                              },
                              icon: const Icon(Icons.calendar_month),
                              label: const Text('Pick date'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(
                        'Permanent changes are always saved to Weekly. Daily shows the effective schedule for the picked date — leave, exchanges and fixture cover layered on top, computed live.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: narrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () => _onGeneratePressed(context),
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text('Generate Weekly'),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => setState(
                                      () => _showQuotaConfigure = !_showQuotaConfigure,
                                    ),
                                    icon: const Icon(Icons.tune),
                                    label: const Text('Quotas'),
                                  ),
                                ),
                                if (_showDaily) const SizedBox(width: 8),
                                if (_showDaily)
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _onRefreshViewPressed(context),
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('Refresh'),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _onGeneratePressed(context),
                                icon: const Icon(Icons.auto_fix_high),
                                label: const Text('Generate Weekly'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              tooltip: 'Configure teacher quotas for this class',
                              onPressed: () => setState(
                                () => _showQuotaConfigure = !_showQuotaConfigure,
                              ),
                              icon: const Icon(Icons.tune),
                            ),
                            if (_showDaily) const SizedBox(width: 4),
                            if (_showDaily)
                              ElevatedButton.icon(
                                onPressed: () => _onRefreshViewPressed(context),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Refresh'),
                              ),
                          ],
                        ),
                ),

                if (_showQuotaConfigure)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Configure teacher quotas',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Set units/week per teacher and optionally choose exactly 1 class teacher.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Colors.white70),
                            ),
                            if (_savingQuotas) const SizedBox(height: 12),
                            if (_savingQuotas) const LinearProgressIndicator(),
                            const SizedBox(height: 14),

                            TextField(
                              decoration: InputDecoration(
                                labelText: 'Search teachers',
                                prefixIcon: const Icon(Icons.search),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onChanged: (v) =>
                                  setState(() => _teacherSearch = v.trim()),
                            ),
                            const SizedBox(height: 12),

                            SizedBox(
                              height: 220,
                              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                                stream: FirebaseFirestore.instance
                                    .collection('users')
                                    .where('role', isEqualTo: 'teacher')
                                    .snapshots(),
                                builder: (context, snap) {
                                  if (!snap.hasData) {
                                    return const Center(child: CircularProgressIndicator());
                                  }

                                  final docs = snap.data!.docs;
                                  final filtered = docs.where((d) {
                                    if (_teacherSearch.isEmpty) return true;
                                    final name = (d.data()['name'] as String?) ?? '';
                                    return name
                                        .toLowerCase()
                                        .contains(_teacherSearch.toLowerCase());
                                  }).toList();

                                  if (filtered.isEmpty) {
                                    return const Center(child: Text('No teachers found'));
                                  }

                                  return ListView.builder(
                                    itemCount: filtered.length,
                                    itemBuilder: (ctx, i) {
                                      final doc = filtered[i];
                                      final data = doc.data();
                                      final teacherId = doc.id;
                                      final teacherName = (data['name'] as String?) ?? 'Unknown';

                                      final alreadyAdded =
                                          _quotaTeachers.any((t) => t.teacherId == teacherId);

                                      return ListTile(
                                        title: Text(teacherName),
                                        trailing: alreadyAdded
                                            ? const Chip(label: Text('Added'))
                                            : IconButton(
                                                tooltip: 'Add quota',
                                                icon: const Icon(Icons.add_circle_outline),
                                                onPressed: () {
                                                  setState(() {
                                                    _quotaTeachers.add(
                                                      ClassTeacherAssignment(
                                                        teacherId: teacherId,
                                                        teacherName: teacherName,
                                                        unitsWeek: 0,
                                                        isClassTeacher: _quotaTeachers.isEmpty,
                                                      ),
                                                    );
                                                  });
                                                },
                                              ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),

                            const SizedBox(height: 14),

                            const Text(
                              'Quota list',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),

                            if (_quotaTeachers.isEmpty)
                              const Text(
                                'Add teachers above to start configuring quotas.',
                                style: TextStyle(color: Colors.white70),
                              )
                            else
                              Column(
                                children: List.generate(
                                  _quotaTeachers.length,
                                  (index) {
                                    final t = _quotaTeachers[index];
                                    return Card(
                                      key: ValueKey('quota_${t.teacherId}'),
                                      color: const Color(0xFF0D1322),
                                      margin: const EdgeInsets.only(bottom: 10),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    t.teacherName,
                                                    style: const TextStyle(
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip: 'Remove teacher quota',
                                                  icon: const Icon(
                                                    Icons.delete_outline,
                                                    color: Colors.redAccent,
                                                  ),
                                                  onPressed: () => setState(
                                                    () => _quotaTeachers.removeAt(index),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 10),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: TextFormField(
                                                    key: ValueKey('unitsWeek_${t.teacherId}'),
                                                    decoration: const InputDecoration(
                                                      labelText: 'Units per week',
                                                      border: OutlineInputBorder(),
                                                    ),
                                                    keyboardType: TextInputType.number,
                                                    initialValue: t.unitsWeek.toString(),
                                                    onChanged: (v) {
                                                      final parsed = int.tryParse(v.trim()) ?? 0;
                                                      setState(() {
                                                        _quotaTeachers[index] =
                                                            t.copyWith(unitsWeek: parsed);
                                                      });
                                                    },
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    const Text('Class teacher'),
                                                    Checkbox(
                                                      value: t.isClassTeacher,
                                                      onChanged: (checked) => _setClassTeacher(
                                                        index,
                                                        checked ?? false,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

                            const SizedBox(height: 16),

                            Row(
                              children: [
                                Expanded(
                                  child: TextButton(
                                    onPressed: () async {
                                      await _loadCurrentQuotas();
                                      if (!mounted) return;
                                      setState(() => _showQuotaConfigure = false);
                                    },
                                    child: const Text('Cancel'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _savingQuotas ? null : _saveQuotasAndSync,
                                    icon: const Icon(Icons.save),
                                    label: Text(
                                      _savingQuotas ? 'Saving...' : 'Save & Sync',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                if (_quotaTeachers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: _DraggableTeacherRoster(teachers: _quotaTeachers),
                  ),

                const Divider(height: 1),

                Animate(
                  child: _TimetableGridView(
                    classId: widget.classId,
                    showDaily: _showDaily,
                    selectedDateKey: _dateKey,
                  ),
                ).fadeIn(duration: 250.ms).slideY(begin: 0.05, end: 0),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Horizontal strip of draggable teacher chips. Drag one onto any grid cell
/// (empty or occupied) to assign them — this is the missing "drag" half of
/// drag-and-drop; the grid cells were already valid [DragTarget]s.
class _DraggableTeacherRoster extends StatelessWidget {
  final List<ClassTeacherAssignment> teachers;

  const _DraggableTeacherRoster({required this.teachers});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, List<BusyBlock>>>(
      valueListenable: TeacherBusyCache.instance.notifier,
      builder: (context, busyMap, _) {
        return GlassCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Drag a teacher onto a slot to assign · greyed = at/over weekly capacity',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white60),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: teachers.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final t = teachers[index];
                      final totalUnits = busyMap[t.teacherId]?.length ?? 0;
                      final atCapacity = totalUnits >= TeacherBusyCache.instance.maxUnits;

                      final chip = Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: atCapacity
                              ? Colors.white.withValues(alpha: 0.04)
                              : (t.isClassTeacher
                                  ? Colors.amber.withValues(alpha: 0.18)
                                  : Colors.blue.withValues(alpha: 0.14)),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: atCapacity
                                ? Colors.white.withValues(alpha: 0.1)
                                : (t.isClassTeacher
                                    ? Colors.amber.withValues(alpha: 0.5)
                                    : Colors.white.withValues(alpha: 0.18)),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (t.isClassTeacher && !atCapacity) ...[
                              const Icon(Icons.star, size: 14, color: Colors.amber),
                              const SizedBox(width: 6),
                            ],
                            if (atCapacity) ...[
                              const Icon(Icons.block, size: 13, color: Colors.redAccent),
                              const SizedBox(width: 6),
                            ],
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  t.teacherName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: atCapacity ? Colors.white38 : Colors.white,
                                  ),
                                ),
                                Text(
                                  atCapacity
                                      ? '$totalUnits/${TeacherBusyCache.instance.maxUnits} · full'
                                      : '${t.unitsWeek} units/wk · $totalUnits busy',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: atCapacity ? Colors.redAccent.withValues(alpha: 0.8) : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );

                      // Still draggable even at capacity — admins may
                      // explicitly want to override (confirmation dialog
                      // appears on drop), but the greyed look makes the
                      // risk obvious before they commit to the gesture.
                      return Opacity(
                        opacity: atCapacity ? 0.55 : 1.0,
                        child: Draggable<String>(
                          data: t.teacherId,
                          feedback: Material(
                            color: Colors.transparent,
                            child: Opacity(opacity: 0.85, child: chip),
                          ),
                          childWhenDragging: Opacity(opacity: 0.35, child: chip),
                          child: chip,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TimetableGridView extends StatelessWidget {
  final String classId;
  final bool showDaily;
  final String selectedDateKey;

  const _TimetableGridView({
    required this.classId,
    required this.showDaily,
    required this.selectedDateKey,
  });

  @override
  Widget build(BuildContext context) {
    return _GridBuilder(
      classId: classId,
      showDaily: showDaily,
      selectedDateKey: selectedDateKey,
    );
  }
}

class _GridBuilder extends StatefulWidget {
  final String classId;
  final bool showDaily;
  final String selectedDateKey;

  const _GridBuilder({
    required this.classId,
    required this.showDaily,
    required this.selectedDateKey,
  });

  @override
  State<_GridBuilder> createState() => _GridBuilderState();
}

class _GridBuilderState extends State<_GridBuilder> {
  final _timetable = TimetableService();
  int? _unitsPerDay;
  TimeProfileModel? _timeProfile;

  @override
  void initState() {
    super.initState();
    _loadUnitsPerDay();
  }

  Future<void> _loadUnitsPerDay() async {
    final cls = await _timetable.getClass(widget.classId);
    if (!mounted) return;
    TimeProfileModel? profile;
    if (cls != null && cls.timeProfileId.isNotEmpty) {
      profile = await _timetable.getTimeProfile(cls.timeProfileId);
    }
    if (!mounted) return;
    setState(() {
      _unitsPerDay = cls?.unitsPerDay;
      _timeProfile = profile;
    });
  }



  /// REPLACES the old "query a separate `daily_timetables` collection"
  /// stream. There is no materialized daily collection any more — instead
  /// this merges the live weekly stream with the live exceptions-for-date
  /// stream and overlays one onto the other, exactly like the teacher's own
  /// "today" view does. Important: the merged list's doc ids are still the
  /// WEEKLY slot ids (never an exception id) — every assignment action in
  /// this file independently recomputes `TimetableService().slotId(...)`
  /// before writing, so this is purely a *display* concern.
  Stream<List<TimetableSlotModel>> _buildStream() {
    final weekly = FirebaseFirestore.instance
        .collection('weekly_timetables')
        .where('classId', isEqualTo: widget.classId)
        .snapshots();

    if (!widget.showDaily) {
      return weekly.map((snap) => snap.docs
          .map((d) => TimetableSlotModel.fromMap(d.id, d.data()))
          .toList());
    }

    final exceptions = FirebaseFirestore.instance
        .collection('timetable_exceptions')
        .where('classId', isEqualTo: widget.classId)
        .where('date', isEqualTo: widget.selectedDateKey)
        .snapshots();

    return Stream.multi((sink) {
      List<QueryDocumentSnapshot<Map<String, dynamic>>> weeklyDocs = [];
      List<QueryDocumentSnapshot<Map<String, dynamic>>> excDocs = [];

      void emit() {
        final excBySlotId = <String, Map<String, dynamic>>{};
        for (final d in excDocs) {
          final data = d.data();
          excBySlotId[(data['slotId'] as String?) ?? d.id] = data;
        }
        final merged = weeklyDocs.map((d) {
          final base = TimetableSlotModel.fromMap(d.id, d.data());
          final exc = excBySlotId[d.id];
          if (exc == null) return base;
          return base.copyWith(
            teacherId: (exc['teacherId'] as String?) ?? '',
            teacherName: (exc['teacherName'] as String?) ?? '',
            type: (exc['type'] as String?) ?? base.type,
          );
        }).toList();
        sink.add(merged);
      }

      final s1 = weekly.listen((snap) {
        weeklyDocs = snap.docs;
        emit();
      }, onError: sink.addError);
      final s2 = exceptions.listen((snap) {
        excDocs = snap.docs;
        emit();
      }, onError: sink.addError);

      sink.onCancel = () async {
        await s1.cancel();
        await s2.cancel();
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];

    return StreamBuilder<List<TimetableSlotModel>>(
      stream: _buildStream(),

      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final slots = snapshot.data!;
        if (slots.isEmpty) {
          return const Center(child: Text('No timetable slots found'));
        }

        final maxUnitFromDocs =
            slots.map((s) => s.unit).fold<int>(0, (p, c) => c > p ? c : p);

        final maxUnit = _unitsPerDay ?? maxUnitFromDocs;

        if (maxUnit <= 0) {
          return const Center(child: Text('No units found for this class'));
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final isNarrow = maxW < 600;

            // Bigger, deterministic slots; keeps content from “disappearing” on small screens.
            final headerH = isNarrow ? 56.0 : 62.0;
            final slotH = isNarrow ? 88.0 : 96.0;
            final slotPad = isNarrow ? 8.0 : 10.0;

            final dayColW = isNarrow ? 110.0 : 140.0;
            final unitColW = isNarrow ? 95.0 : 110.0;

            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.10),
                      Colors.white.withValues(alpha: 0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Column(
                    children: [
                      SizedBox(
                        height: headerH,
                        child: Row(
                          children: [
                            SizedBox(
                              width: dayColW,
                              child: Container(
                                alignment: Alignment.centerLeft,
                                padding: EdgeInsets.symmetric(horizontal: slotPad),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: const Text(
                                  'Day',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                              ),
                            ),
                            for (var unitIndex = 0; unitIndex < maxUnit; unitIndex++)
                              SizedBox(
                                width: unitColW,
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                    color: Colors.white.withValues(alpha: 0.06),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'U${unitIndex + 1}',
                                        style: const TextStyle(fontWeight: FontWeight.w800),
                                      ),
                                      if (_timeProfile != null &&
                                          unitIndex < _timeProfile!.teachingPeriods.length)
                                        Text(
                                          '${_timeProfile!.teachingPeriods[unitIndex].startTime}-${_timeProfile!.teachingPeriods[unitIndex].endTime}',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            color: Colors.white.withValues(alpha: 0.55),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // Body rows
                      for (var dayIndex = 0; dayIndex < days.length; dayIndex++)
                        SizedBox(
                          height: slotH,
                          child: Row(
                            children: [
                              SizedBox(
                                width: dayColW,
                                child: Container(
                                  alignment: Alignment.centerLeft,
                                  padding: EdgeInsets.symmetric(horizontal: slotPad),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Text(
                                    days[dayIndex],
                                    style: const TextStyle(fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                              for (var unitIndex = 0; unitIndex < maxUnit; unitIndex++)
                                Builder(builder: (ctx) {
                                  final unit = unitIndex + 1;
                                  final slot = slots.firstWhere(
                                    (s) => s.day == days[dayIndex] && s.unit == unit,
                                    orElse: () => TimetableSlotModel(
                                      id: 'empty',
                                      classId: widget.classId,
                                      className: '',
                                      teacherId: '',
                                      teacherName: '',
                                      day: days[dayIndex],
                                      unit: unit,
                                      startTime: '',
                                      endTime: '',
                                      type: 'permanent',
                                      originalTeacherId: '',
                                    ),
                                  );

                                  final empty = slot.teacherName.trim().isEmpty;
                                  return SizedBox(
                                    width: unitColW,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      child: empty
                                          ? _EmptySlotCell(
                                              day: days[dayIndex],
                                              unit: unit,
                                              slotH: slotH,
                                              showDaily: widget.showDaily,
                                              classId: widget.classId,
                                              startTime: slot.startTime,
                                              endTime: slot.endTime,
                                            )
                                          : _SlotCell(
                                              slot: slot,
                                              showDaily: widget.showDaily,
                                              classId: widget.classId,
                                            ),
                                    ),
                                  );
                                }),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptySlotCell extends StatelessWidget {
  final String day;
  final int unit;
  final double slotH;
  final bool showDaily;
  final String classId;
  final String startTime;
  final String endTime;

  const _EmptySlotCell({
    required this.day,
    required this.unit,
    required this.slotH,
    required this.showDaily,
    required this.classId,
    this.startTime = '',
    this.endTime = '',
  });

  Future<void> _assign(BuildContext context) async {
    final selectedTeacherId = await showDialog<String>(
      context: context,
      builder: (ctx) => _TeacherPickDialog(
        classId: classId,
        classDay: day,
        unit: unit,
        startTime: startTime,
        endTime: endTime,
      ),
    );

    if (selectedTeacherId == null || selectedTeacherId.isEmpty) return;
    if (!context.mounted) return;
    await _performAssign(context, selectedTeacherId);
  }

  Future<void> _performAssign(
    BuildContext context,
    String draggedTeacherId, {
    bool overrideQuota = false,
    bool allowLeaveOverride = false,
    bool bypassFirstUnitProtection = false,
  }) async {
    if (draggedTeacherId.isEmpty) return;

    final weeklySlotId = TimetableService().slotId(classId, day, unit);
    try {
      final outcome = await TimetableService().assignTeacherWithClashHandling(
        classId: classId,
        destinationSlotId: weeklySlotId,
        draggedTeacherId: draggedTeacherId,
        mode: ClashHandlingMode.rollback,
        overrideQuota: overrideQuota,
        allowLeaveOverride: allowLeaveOverride,
        bypassFirstUnitProtection: bypassFirstUnitProtection,
      );

      // Unit 1 is reserved for the class teacher. Admin-only bypass, with
      // an explicit warning — never a silent block, never automatic.
      if (!outcome.assigned && outcome.firstUnitConflict && context.mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unit 1 is reserved for the class teacher'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true && context.mounted) {
          await _performAssign(context, draggedTeacherId, bypassFirstUnitProtection: true);
        }
        return;
      }

      // Approved leave covers a future occurrence of this slot. Automation
      // never reaches this path at all (see TimetableService docs) — this
      // is strictly the manual "admin assigns anyway" warning, and even
      // after confirming, the teacher's leave dates stay vacated for cover.
      if (!outcome.assigned && outcome.leaveConflict && context.mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Teacher has approved leave'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true && context.mounted) {
          await _performAssign(context, draggedTeacherId, allowLeaveOverride: true);
        }
        return;
      }

      if (!outcome.assigned && outcome.quotaExceeded && context.mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Exceeds quota'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true && context.mounted) {
          await _performAssign(context, draggedTeacherId, overrideQuota: true);
        }
        return;
      }

      if (outcome.warnings.isNotEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(outcome.warnings.join('\n'))),
        );
      }
      TeacherBusyCache.instance.refresh();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not assign teacher: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onAcceptWithDetails: (details) => _performAssign(context, details.data),
      builder: (context, candidate, rejected) {
        final hoveredTeacherId = candidate.isNotEmpty ? candidate.first : null;
        final isBusyHover = hoveredTeacherId != null &&
            TeacherBusyCache.instance.isBusy(hoveredTeacherId, day, startTime, endTime);
        final isHovering = candidate.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: slotH,
          decoration: BoxDecoration(
            color: !isHovering
                ? null
                : (isBusyHover
                    ? Colors.redAccent.withValues(alpha: 0.18)
                    : Colors.greenAccent.withValues(alpha: 0.16)),
            borderRadius: BorderRadius.circular(8),
            border: isHovering
                ? Border.all(color: isBusyHover ? Colors.redAccent : Colors.greenAccent, width: 1.4)
                : null,
          ),
          child: InkWell(
            onTap: () => _assign(context),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isHovering ? (isBusyHover ? '✕' : '✓') : '+',
                    style: TextStyle(
                      color: isHovering
                          ? (isBusyHover ? Colors.redAccent : Colors.greenAccent)
                          : const Color(0x99FFFFFF),
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isHovering
                        ? (isBusyHover ? 'Busy here' : 'Free')
                        : (showDaily ? 'Add' : 'Add teacher'),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SlotCell extends StatefulWidget {
  final TimetableSlotModel slot;
  final bool showDaily;
  final String classId;


  const _SlotCell({
    required this.slot,
    required this.showDaily,
    required this.classId,
  });

  @override
  State<_SlotCell> createState() => _SlotCellState();
}

class _SlotCellState extends State<_SlotCell> {
  Future<void> _performAssign(
    String draggedTeacherId, {
    bool overrideQuota = false,
    bool allowLeaveOverride = false,
    bool bypassFirstUnitProtection = false,
  }) async {
    if (draggedTeacherId.isEmpty) return;

    final destinationWeeklySlotId = TimetableService().slotId(
      widget.classId,
      widget.slot.day,
      widget.slot.unit,
    );

    try {
      final outcome = await TimetableService().assignTeacherWithClashHandling(
        classId: widget.classId,
        destinationSlotId: destinationWeeklySlotId,
        draggedTeacherId: draggedTeacherId,
        mode: ClashHandlingMode.rollback,
        overrideQuota: overrideQuota,
        allowLeaveOverride: allowLeaveOverride,
        bypassFirstUnitProtection: bypassFirstUnitProtection,
      );

      if (!outcome.assigned && outcome.firstUnitConflict && mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unit 1 is reserved for the class teacher'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _performAssign(draggedTeacherId, bypassFirstUnitProtection: true);
        }
        return;
      }

      if (!outcome.assigned && outcome.leaveConflict && mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Teacher has approved leave'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _performAssign(draggedTeacherId, allowLeaveOverride: true);
        }
        return;
      }

      if (!outcome.assigned && outcome.quotaExceeded && mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Exceeds quota'),
            content: Text('${outcome.warnings.join('\n')}\n\nAssign anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Assign anyway'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await _performAssign(draggedTeacherId, overrideQuota: true);
        }
        return;
      }

      if (outcome.warnings.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(outcome.warnings.join('\n'))),
        );
      }
      TeacherBusyCache.instance.refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not assign teacher: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.slot.teacherName.trim().isEmpty;

    final cellColor = empty
        ? Colors.transparent
        : (widget.showDaily
            ? Colors.orange.withValues(alpha: 0.13)
            : Colors.blue.withValues(alpha: 0.13));

    return DragTarget<String>(
      onAcceptWithDetails: (details) => _performAssign(details.data),
      builder: (context, candidate, rejected) {
        final hoveredTeacherId = candidate.isNotEmpty ? candidate.first : null;
        final isBusyHover = hoveredTeacherId != null &&
            TeacherBusyCache.instance.isBusy(
              hoveredTeacherId,
              widget.slot.day,
              widget.slot.startTime,
              widget.slot.endTime,
            );
        final isHovering = candidate.isNotEmpty;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isHovering
                ? (isBusyHover
                    ? Colors.redAccent.withValues(alpha: 0.18)
                    : Colors.greenAccent.withValues(alpha: 0.16))
                : cellColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovering
                  ? (isBusyHover ? Colors.redAccent : Colors.greenAccent)
                  : (empty ? Colors.transparent : Colors.white.withValues(alpha: 0.18)),
              width: isHovering ? 1.4 : 1,
            ),
          ),
          child: InkWell(
            onTap: () async {
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                isDismissible: true,
                backgroundColor: Colors.transparent,
                builder: (ctx) => _SlotEditSheet(
                  classId: widget.classId,
                  slot: widget.slot,
                  showDaily: widget.showDaily,
                ),
              );
            },
            child: Align(
              alignment: Alignment.centerLeft,
              child: empty
                  ? Text(
                      isHovering ? (isBusyHover ? 'Busy' : 'Free') : '—',
                      style: TextStyle(
                        color: isHovering
                            ? (isBusyHover ? Colors.redAccent : Colors.greenAccent)
                            : const Color(0x99FFFFFF),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.slot.teacherName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.slot.startTime}${widget.slot.startTime.isEmpty ? '' : ' - '}${widget.slot.endTime}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _SlotEditSheet extends StatefulWidget {
  final String classId;
  final TimetableSlotModel slot;
  final bool showDaily;

  const _SlotEditSheet({
    required this.classId,
    required this.slot,
    required this.showDaily,
  });

  @override
  State<_SlotEditSheet> createState() => _SlotEditSheetState();
}

class _SlotEditSheetState extends State<_SlotEditSheet> {
  final _teacherService = TimetableService();

  late final TextEditingController _startController;
  late final TextEditingController _endController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: widget.slot.startTime);
    _endController = TextEditingController(text: widget.slot.endTime);
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  Future<void> _assignTeacher(BuildContext context) async {
    final teacherId = await showDialog<String>(
      context: context,
      builder: (ctx) => _TeacherPickDialog(
        classId: widget.classId,
        classDay: widget.slot.day,
        unit: widget.slot.unit,
        startTime: widget.slot.startTime,
        endTime: widget.slot.endTime,
      ),
    );

    if (teacherId == null || teacherId.isEmpty) return;

    final weeklySlotId = _teacherService.slotId(
      widget.classId,
      widget.slot.day,
      widget.slot.unit,
    );

    try {
      final outcome = await _teacherService.assignTeacherWithClashHandling(
        classId: widget.classId,
        destinationSlotId: weeklySlotId,
        draggedTeacherId: teacherId,
        mode: ClashHandlingMode.rollback,
      );
      if (!outcome.assigned) {
        if (!mounted) return;
        final extra = (outcome.leaveConflict || outcome.firstUnitConflict || outcome.quotaExceeded)
            ? ' Use the grid\'s drag-and-drop assignment instead — it offers an "assign anyway" override for this.'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${outcome.warnings.join('\n')}$extra')),
        );
        return;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not assign teacher: $e')),
      );
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _applyTimeOnly(BuildContext context) async {
    final weeklySlotId = _teacherService.slotId(
      widget.classId,
      widget.slot.day,
      widget.slot.unit,
    );

    await FirebaseFirestore.instance
        .collection('weekly_timetables')
        .doc(weeklySlotId)
        .set({
      'startTime': _startController.text.trim(),
      'endTime': _endController.text.trim(),
    }, SetOptions(merge: true));

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.slot.teacherName.trim().isEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.slot.day} · Unit ${widget.slot.unit}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(empty ? 'Empty' : 'Assigned')),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _startController,
              decoration: const InputDecoration(
                labelText: 'Start Time (e.g. 08:00 AM)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _endController,
              decoration: const InputDecoration(
                labelText: 'End Time (e.g. 08:40 AM)',
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _applyTimeOnly(context),
                    icon: const Icon(Icons.save),
                    label: const Text('Save time'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _assignTeacher(context),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Assign teacher'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherPickDialog extends StatefulWidget {
  final String classId;
  final String classDay;
  final int unit;
  final String startTime;
  final String endTime;

  const _TeacherPickDialog({
    required this.classId,
    required this.classDay,
    required this.unit,
    this.startTime = '',
    this.endTime = '',
  });

  @override
  State<_TeacherPickDialog> createState() => _TeacherPickDialogState();
}

class _TeacherPickDialogState extends State<_TeacherPickDialog> {

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final dialogWidth = screenSize.width < 480
        ? screenSize.width * 0.88
        : 420.0;
    final dialogHeight = (screenSize.height * 0.6).clamp(280.0, 420.0);

    return AlertDialog(
      title: const Text('Pick teacher'),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .where('role', isEqualTo: 'teacher')
              .snapshots(),
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final teachers = snap.data!.docs;
            if (teachers.isEmpty) {
              return const Center(child: Text('No teachers found'));
            }

            // Sort: free teachers first, busy ones (still selectable, just
            // flagged) pushed down — mirrors the "who's busy" requirement
            // without hiding anyone the admin might still want to override.
            final sorted = [...teachers];
            sorted.sort((a, b) {
              final aBusy = widget.startTime.isEmpty
                  ? false
                  : TeacherBusyCache.instance.isBusy(a.id, widget.classDay, widget.startTime, widget.endTime);
              final bBusy = widget.startTime.isEmpty
                  ? false
                  : TeacherBusyCache.instance.isBusy(b.id, widget.classDay, widget.startTime, widget.endTime);
              if (aBusy == bBusy) return 0;
              return aBusy ? 1 : -1;
            });

            return ListView.builder(
              itemCount: sorted.length,
              itemBuilder: (ctx, i) {
                final doc = sorted[i];
                final data = doc.data();
                final teacherId = doc.id;
                final teacherName = (data['name'] as String?) ?? 'Unknown';
                final totalUnits = TeacherBusyCache.instance.totalUnits(teacherId);
                final atCapacity = TeacherBusyCache.instance.isAtOrOverCapacity(teacherId);
                final isBusyNow = widget.startTime.isEmpty
                    ? false
                    : TeacherBusyCache.instance.isBusy(
                        teacherId, widget.classDay, widget.startTime, widget.endTime);

                return Opacity(
                  opacity: isBusyNow ? 0.55 : 1,
                  child: ListTile(
                    title: Text(teacherName),
                    subtitle: Text(
                      isBusyNow
                          ? 'Busy at this time'
                          : '$totalUnits/${TeacherBusyCache.instance.maxUnits} units${atCapacity ? ' · at capacity' : ''}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: isBusyNow ? Colors.redAccent : Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                    trailing: isBusyNow
                        ? const Icon(Icons.event_busy, color: Colors.redAccent, size: 18)
                        : (atCapacity
                            ? const Icon(Icons.warning_amber_outlined, color: Colors.orangeAccent, size: 18)
                            : const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 18)),
                    onTap: () => Navigator.of(context).pop(teacherId),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

