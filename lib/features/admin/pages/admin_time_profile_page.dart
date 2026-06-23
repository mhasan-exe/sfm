import 'package:flutter/material.dart';

import '../../../core/services/timetable_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/time_profile_model.dart';

/// Time Profile management: list, create, edit, delete. Reached from the
/// Timetables tab's "Manage Time Profiles" entry point. Replaces raw text
/// time entry with real time pickers, adds first-class break periods, and
/// offers a "quick generate" helper so admins don't have to type 8+ start/
/// end times by hand.
class AdminTimeProfilePage extends StatefulWidget {
  const AdminTimeProfilePage({super.key});

  @override
  State<AdminTimeProfilePage> createState() => _AdminTimeProfilePageState();
}

class _AdminTimeProfilePageState extends State<AdminTimeProfilePage> {
  final _service = TimetableService();

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Time Profiles'),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openEditor(null),
          icon: const Icon(Icons.add),
          label: const Text('New profile'),
        ),
        body: SafeArea(
          child: StreamBuilder<List<TimeProfileModel>>(
            stream: _service.watchTimeProfiles(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final profiles = snapshot.data!;
              if (profiles.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No time profiles yet. Tap "New profile" to define your school\'s daily period structure.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                itemCount: profiles.length,
                itemBuilder: (context, index) => _profileCard(profiles[index]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _profileCard(TimeProfileModel profile) {
    final teaching = profile.teachingPeriods;
    final breaks = profile.breakPeriods;
    final hours = profile.totalDayMinutes / 60.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    profile.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit',
                  onPressed: () => _openEditor(profile),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  tooltip: 'Delete',
                  onPressed: () => _confirmDelete(profile),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _chip(Icons.school_outlined, '${teaching.length} teaching periods'),
                if (breaks.isNotEmpty) _chip(Icons.free_breakfast_outlined, '${breaks.length} break(s)'),
                _chip(Icons.schedule_outlined, '${hours.toStringAsFixed(1)}h school day'),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: profile.orderedAll.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final p = profile.orderedAll[i];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: p.isBreak
                          ? Colors.orangeAccent.withValues(alpha: 0.18)
                          : Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: p.isBreak
                            ? Colors.orangeAccent.withValues(alpha: 0.4)
                            : Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        '${p.displayLabel}  ${p.startTime}-${p.endTime}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.75)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11.5)),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(TimeProfileModel profile) async {
    final usedBy = await _service.classesUsingTimeProfile(profile.id);
    if (!mounted) return;

    if (usedBy.isNotEmpty) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Profile in use'),
          content: Text(
            '"${profile.name}" is used by: ${usedBy.join(', ')}. Reassign those classes to a different time profile before deleting this one.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete time profile?'),
        content: Text('This permanently removes "${profile.name}". This cannot be undone.'),
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
    if (confirm != true) return;

    try {
      await _service.deleteTimeProfile(profile.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${profile.name}" deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _openEditor(TimeProfileModel? existing) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => TimeProfileEditorPage(existing: existing)),
    );
  }
}

/// Full editor for a single time profile: name, quick-generate helper, and
/// a manual list of teaching periods + breaks, each with real time pickers.
class TimeProfileEditorPage extends StatefulWidget {
  final TimeProfileModel? existing;
  const TimeProfileEditorPage({super.key, this.existing});

  @override
  State<TimeProfileEditorPage> createState() => _TimeProfileEditorPageState();
}

class _TimeProfileEditorPageState extends State<TimeProfileEditorPage> {
  final _service = TimetableService();
  late final TextEditingController _nameController;
  late List<TimePeriod> _rows;
  bool _saving = false;

  // Quick-generate inputs
  TimeOfDay _genStart = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _genEnd = const TimeOfDay(hour: 14, minute: 0);
  int _genPeriodCount = 8;
  int _genBreakCount = 1;
  int _genBreakDuration = 20;
  int _genBreakAfterPeriod = 4;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _rows = widget.existing != null
        ? widget.existing!.orderedAll.map((p) => p.copyWith()).toList()
        : <TimePeriod>[];
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Auto-distributes [_genPeriodCount] equal-length teaching periods
  /// between [_genStart] and [_genEnd], inserting [_genBreakCount] breaks
  /// of [_genBreakDuration] minutes — the first one landing right after
  /// period [_genBreakAfterPeriod], the rest spaced evenly through the
  /// remaining periods. This is the "easier units recommendation" helper:
  /// admins set the big picture (day start/end, how many periods, break
  /// length) and get a sane starting timetable instead of typing 16+ times.
  void _quickGenerate() {
    final startMin = _genStart.hour * 60 + _genStart.minute;
    final endMin = _genEnd.hour * 60 + _genEnd.minute;
    if (endMin <= startMin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('School end time must be after start time')),
      );
      return;
    }
    if (_genPeriodCount < 1) return;

    final totalMinutes = endMin - startMin;
    final totalBreakMinutes = _genBreakCount * _genBreakDuration;
    final teachingMinutes = totalMinutes - totalBreakMinutes;
    if (teachingMinutes <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Breaks don\'t fit in the school day — shorten them or extend the day')),
      );
      return;
    }
    final perPeriod = teachingMinutes ~/ _genPeriodCount;
    if (perPeriod < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That\'s too many periods for the available time — reduce the count')),
      );
      return;
    }

    // Spread break insertion points roughly evenly across the periods,
    // starting from the admin's preferred "after period N".
    final breakAfterPeriods = <int>{};
    if (_genBreakCount > 0) {
      final spacing = (_genPeriodCount / (_genBreakCount + 1)).floor().clamp(1, _genPeriodCount);
      var anchor = _genBreakAfterPeriod.clamp(1, _genPeriodCount);
      breakAfterPeriods.add(anchor);
      for (var i = 1; i < _genBreakCount; i++) {
        anchor = (anchor + spacing).clamp(1, _genPeriodCount);
        breakAfterPeriods.add(anchor);
      }
    }

    final rows = <TimePeriod>[];
    var cursor = startMin;
    var periodNumber = 1;
    var teachingIndex = 0;
    var breaksPlaced = 0;
    final sortedBreakPoints = breakAfterPeriods.toList()..sort();

    for (var i = 1; i <= _genPeriodCount; i++) {
      final pStart = cursor;
      final pEnd = cursor + perPeriod;
      rows.add(TimePeriod(
        periodNumber: periodNumber++,
        startTime: _fmt(pStart),
        endTime: _fmt(pEnd),
        label: 'Period $i',
      ));
      cursor = pEnd;
      teachingIndex = i;

      if (sortedBreakPoints.contains(teachingIndex) && breaksPlaced < _genBreakCount) {
        final bStart = cursor;
        final bEnd = cursor + _genBreakDuration;
        breaksPlaced++;
        rows.add(TimePeriod(
          periodNumber: periodNumber++,
          startTime: _fmt(bStart),
          endTime: _fmt(bEnd),
          isBreak: true,
          label: breaksPlaced == 1 && _genBreakDuration >= 30 ? 'Lunch Break' : 'Break $breaksPlaced',
        ));
        cursor = bEnd;
      }
    }

    setState(() => _rows = rows);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Generated — review below, then Save')),
    );
  }

  String _fmt(int minutesSinceMidnight) {
    final h = (minutesSinceMidnight ~/ 60) % 24;
    final m = minutesSinceMidnight % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String _displayTime(String hhmm) {
    final minutes = TimePeriod.toMinutes(hhmm);
    if (minutes == null) return hhmm;
    final tod = TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60);
    return tod.format(context);
  }

  Future<void> _pickTime(int index, bool isStart) async {
    final row = _rows[index];
    final currentMinutes = TimePeriod.toMinutes(isStart ? row.startTime : row.endTime);
    final initial = currentMinutes != null
        ? TimeOfDay(hour: currentMinutes ~/ 60, minute: currentMinutes % 60)
        : TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    if (!mounted) return;
    final formatted =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    setState(() {
      _rows[index] = isStart ? row.copyWith(startTime: formatted) : row.copyWith(endTime: formatted);
    });
  }

  void _addRow({required bool isBreak}) {
    final nextNumber = _rows.isEmpty ? 1 : (_rows.map((r) => r.periodNumber).reduce((a, b) => a > b ? a : b) + 1);
    // Default the new row to start right after the last row ends, when known.
    String start = '08:00';
    String end = '08:40';
    if (_rows.isNotEmpty) {
      final last = _rows.reduce((a, b) => a.periodNumber > b.periodNumber ? a : b);
      final lastEndMin = TimePeriod.toMinutes(last.endTime);
      if (lastEndMin != null) {
        start = _fmt(lastEndMin);
        end = _fmt(lastEndMin + (isBreak ? 20 : 40));
      }
    }
    setState(() {
      _rows.add(TimePeriod(
        periodNumber: nextNumber,
        startTime: start,
        endTime: end,
        isBreak: isBreak,
        label: isBreak ? 'Break' : 'Period',
      ));
    });
  }

  void _removeRow(int index) => setState(() => _rows.removeAt(index));

  void _moveRow(int index, int delta) {
    final newIndex = index + delta;
    if (newIndex < 0 || newIndex >= _rows.length) return;
    setState(() {
      final a = _rows[index];
      final b = _rows[newIndex];
      // Swap period numbers AND list positions so ordering & numbering
      // stay in sync.
      _rows[index] = b.copyWith(periodNumber: a.periodNumber);
      _rows[newIndex] = a.copyWith(periodNumber: b.periodNumber);
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give this profile a name')),
      );
      return;
    }
    if (_rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one period')),
      );
      return;
    }
    for (final r in _rows) {
      if (TimePeriod.toMinutes(r.startTime) == null || TimePeriod.toMinutes(r.endTime) == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${r.displayLabel} has an invalid time')),
        );
        return;
      }
      if (TimePeriod.toMinutes(r.endTime)! <= TimePeriod.toMinutes(r.startTime)!) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${r.displayLabel} end time must be after start time')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    try {
      if (widget.existing != null) {
        await _service.updateTimeProfile(
          timeProfileId: widget.existing!.id,
          name: name,
          periods: _rows,
        );
      } else {
        await _service.createTimeProfile(name: name, periods: _rows);
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
    final sortedRows = [..._rows]..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(widget.existing != null ? 'Edit time profile' : 'New time profile')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
            children: [
              GlassCard(
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Profile name',
                    hintText: 'e.g. Standard School Day',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.auto_awesome_outlined, size: 18),
                        SizedBox(width: 6),
                        Text('Quick generate', style: TextStyle(fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Set the big picture and we\'ll lay out evenly-spaced periods with your breaks slotted in.',
                      style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.65)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _timeField('School starts', _genStart, (t) => setState(() => _genStart = t))),
                        const SizedBox(width: 10),
                        Expanded(child: _timeField('School ends', _genEnd, (t) => setState(() => _genEnd = t))),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _numberField('Teaching periods', _genPeriodCount, 1, 16, (v) => setState(() => _genPeriodCount = v))),
                        const SizedBox(width: 10),
                        Expanded(child: _numberField('Number of breaks', _genBreakCount, 0, 4, (v) => setState(() => _genBreakCount = v))),
                      ],
                    ),
                    if (_genBreakCount > 0) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: _numberField('Break length (min)', _genBreakDuration, 5, 90, (v) => setState(() => _genBreakDuration = v))),
                          const SizedBox(width: 10),
                          Expanded(child: _numberField('First break after period', _genBreakAfterPeriod, 1, _genPeriodCount, (v) => setState(() => _genBreakAfterPeriod = v))),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _quickGenerate,
                        icon: const Icon(Icons.bolt_outlined),
                        label: const Text('Generate periods'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text('Periods & breaks', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  TextButton.icon(
                    onPressed: () => _addRow(isBreak: false),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Period'),
                  ),
                  TextButton.icon(
                    onPressed: () => _addRow(isBreak: true),
                    icon: const Icon(Icons.free_breakfast_outlined, size: 18),
                    label: const Text('Break'),
                  ),
                ],
              ),
              if (sortedRows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    'No periods yet — use Quick Generate above or add rows manually.',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                  ),
                ),
              ...sortedRows.asMap().entries.map((entry) {
                final displayIndex = entry.key;
                final period = entry.value;
                final actualIndex = _rows.indexOf(period);
                return _periodRow(period, actualIndex, displayIndex, sortedRows.length);
              }),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving…' : 'Save profile'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _periodRow(TimePeriod period, int actualIndex, int displayIndex, int total) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: period.isBreak
                    ? Colors.orangeAccent.withValues(alpha: 0.2)
                    : Colors.deepPurpleAccent.withValues(alpha: 0.2),
              ),
              child: Icon(
                period.isBreak ? Icons.free_breakfast_outlined : Icons.menu_book_outlined,
                size: 16,
                color: period.isBreak ? Colors.orangeAccent : Colors.deepPurpleAccent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 32,
                    child: TextFormField(
                      initialValue: period.label,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onChanged: (v) => _rows[actualIndex] = _rows[actualIndex].copyWith(label: v),
                    ),
                  ),
                  Row(
                    children: [
                      InkWell(
                        onTap: () => _pickTime(actualIndex, true),
                        child: Text(
                          _displayTime(period.startTime),
                          style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.8)),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text('–', style: TextStyle(fontSize: 12)),
                      ),
                      InkWell(
                        onTap: () => _pickTime(actualIndex, false),
                        child: Text(
                          _displayTime(period.endTime),
                          style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.8)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  onPressed: displayIndex > 0 ? () => _moveRow(actualIndex, -1) : null,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  onPressed: displayIndex < total - 1 ? () => _moveRow(actualIndex, 1) : null,
                ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
              onPressed: () => _removeRow(actualIndex),
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeField(String label, TimeOfDay value, ValueChanged<TimeOfDay> onPick) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(context: context, initialTime: value);
        if (!mounted) return;
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true),
        child: Text(value.format(context)),
      ),
    );
  }

  Widget _numberField(String label, int value, int min, int max, ValueChanged<int> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label, isDense: true),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('$value'),
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove, size: 16),
                onPressed: value > min ? () => onChanged(value - 1) : null,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add, size: 16),
                onPressed: value < max ? () => onChanged(value + 1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
