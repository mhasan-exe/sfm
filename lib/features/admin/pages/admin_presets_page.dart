import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/services/timetable_preset_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_card.dart';
import '../../../models/timetable_preset_model.dart';

/// Save the entire school's current weekly timetable as a named snapshot,
/// and load/rollback to any saved snapshot later. Loading a preset
/// automatically backs up whatever's currently live first, so a rollback
/// is itself always recoverable.
class AdminPresetsPage extends StatefulWidget {
  const AdminPresetsPage({super.key});

  @override
  State<AdminPresetsPage> createState() => _AdminPresetsPageState();
}

class _AdminPresetsPageState extends State<AdminPresetsPage> {
  final _service = TimetablePresetService();
  bool _saving = false;
  bool _loadingPresetId = false;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? 'admin';
  String get _name =>
      FirebaseAuth.instance.currentUser?.displayName ??
      FirebaseAuth.instance.currentUser?.email ??
      'Admin';

  Future<void> _saveCurrentAsPreset() async {
    final controller = TextEditingController(
      text: 'Preset · ${DateFormat('MMM d, h:mm a').format(DateTime.now())}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save current timetable as preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    setState(() => _saving = true);
    try {
      await _service.savePreset(name: name, createdBy: _uid, createdByName: _name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Preset saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _loadPreset(TimetablePresetModel preset) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Load this preset?'),
        content: Text(
          'This replaces the ENTIRE school\'s weekly timetable with "${preset.name}" '
          '(${preset.slotCount} slots across ${preset.classCount} classes). '
          'Your current timetable will be auto-backed-up first, so you can undo this.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Load preset'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _loadingPresetId = true);
    try {
      await _service.loadPreset(preset.id, loadedBy: _uid, loadedByName: _name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${preset.name}" loaded — timetable updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingPresetId = false);
    }
  }

  Future<void> _deletePreset(TimetablePresetModel preset) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete preset?'),
        content: Text('Remove "${preset.name}" permanently. This cannot be undone.'),
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
    if (confirm == true) await _service.deletePreset(preset.id);
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Timetable Presets')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _saving ? null : _saveCurrentAsPreset,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving…' : 'Save current as preset'),
        ),
        body: SafeArea(
          child: StreamBuilder<List<TimetablePresetModel>>(
            stream: _service.watchPresets(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final presets = snapshot.data!;
              if (presets.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No presets yet. Save the current timetable as a preset so you can roll back to it later, or use it for scheduled automation instead of regenerating.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                itemCount: presets.length,
                itemBuilder: (context, i) => _presetCard(presets[i]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _presetCard(TimetablePresetModel preset) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (preset.isAutoBackup ? Colors.orangeAccent : Colors.blueAccent)
                    .withValues(alpha: 0.18),
              ),
              child: Icon(
                preset.isAutoBackup ? Icons.history : Icons.save_outlined,
                size: 17,
                color: preset.isAutoBackup ? Colors.orangeAccent : Colors.blueAccent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(preset.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    '${preset.slotCount} slots · ${preset.classCount} classes · ${DateFormat('MMM d, h:mm a').format(preset.createdAt)} · ${preset.createdByName}',
                    style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: _loadingPresetId
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.restore, size: 20),
              tooltip: 'Load',
              onPressed: _loadingPresetId ? null : () => _loadPreset(preset),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
              tooltip: 'Delete',
              onPressed: () => _deletePreset(preset),
            ),
          ],
        ),
      ),
    );
  }
}
