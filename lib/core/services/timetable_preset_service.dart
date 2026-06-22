import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/timetable_preset_model.dart';

/// Save/load/rollback for whole-school timetable snapshots. Each preset
/// stores every `weekly_timetables` document as-is in a `slots`
/// subcollection (rather than one big array field) so there's no risk of
/// hitting Firestore's 1MB document size limit on a large school.
class TimetablePresetService {
  CollectionReference<Map<String, dynamic>> get _presets =>
      FirebaseFirestore.instance.collection('timetable_presets');

  CollectionReference<Map<String, dynamic>> get _weekly =>
      FirebaseFirestore.instance.collection('weekly_timetables');

  static const _batchLimit = 400;

  Future<String> savePreset({
    required String name,
    required String createdBy,
    required String createdByName,
    bool isAutoBackup = false,
  }) async {
    final weeklySnap = await _weekly.get();

    final classIds = <String>{};
    for (final d in weeklySnap.docs) {
      final cid = d.data()['classId']?.toString();
      if (cid != null && cid.isNotEmpty) classIds.add(cid);
    }

    final presetRef = _presets.doc();
    await presetRef.set({
      'name': name,
      'createdBy': createdBy,
      'createdByName': createdByName,
      'createdAt': FieldValue.serverTimestamp(),
      'classCount': classIds.length,
      'slotCount': weeklySnap.docs.length,
      'isAutoBackup': isAutoBackup,
    });

    final docs = weeklySnap.docs;
    for (var i = 0; i < docs.length; i += _batchLimit) {
      final batch = FirebaseFirestore.instance.batch();
      for (final d in docs.skip(i).take(_batchLimit)) {
        batch.set(presetRef.collection('slots').doc(d.id), d.data());
      }
      await batch.commit();
    }

    return presetRef.id;
  }

  Stream<List<TimetablePresetModel>> watchPresets() {
    return _presets.snapshots().map((snap) {
      final list = snap.docs
          .map((d) => TimetablePresetModel.fromMap(d.id, d.data()))
          .toList();
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  Future<void> deletePreset(String id) async {
    final slotsSnap = await _presets.doc(id).collection('slots').get();
    final docs = slotsSnap.docs;
    for (var i = 0; i < docs.length; i += _batchLimit) {
      final batch = FirebaseFirestore.instance.batch();
      for (final d in docs.skip(i).take(_batchLimit)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }
    await _presets.doc(id).delete();
  }

  /// Restores `weekly_timetables` to EXACTLY match the preset snapshot:
  /// any current slot not present in the preset is deleted, and every
  /// slot in the preset is written back verbatim (same doc IDs, so daily
  /// timetable links and audit history stay consistent).
  ///
  /// Unless [skipAutoBackup] is true, this first transparently saves the
  /// CURRENT state as an "Auto-backup before loading ..." preset, so a
  /// rollback is itself always recoverable.
  Future<void> loadPreset(
    String presetId, {
    required String loadedBy,
    required String loadedByName,
    bool skipAutoBackup = false,
  }) async {
    final presetDoc = await _presets.doc(presetId).get();
    if (!presetDoc.exists) throw Exception('Preset not found');
    final presetName = presetDoc.data()?['name']?.toString() ?? 'preset';

    if (!skipAutoBackup) {
      await savePreset(
        name: 'Auto-backup before loading "$presetName"',
        createdBy: loadedBy,
        createdByName: loadedByName,
        isAutoBackup: true,
      );
    }

    final presetSlotsSnap = await _presets.doc(presetId).collection('slots').get();
    final currentSnap = await _weekly.get();

    final presetIds = presetSlotsSnap.docs.map((d) => d.id).toSet();
    final toDelete =
        currentSnap.docs.where((d) => !presetIds.contains(d.id)).toList();

    for (var i = 0; i < toDelete.length; i += _batchLimit) {
      final batch = FirebaseFirestore.instance.batch();
      for (final d in toDelete.skip(i).take(_batchLimit)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    }

    final restoreDocs = presetSlotsSnap.docs;
    for (var i = 0; i < restoreDocs.length; i += _batchLimit) {
      final batch = FirebaseFirestore.instance.batch();
      for (final d in restoreDocs.skip(i).take(_batchLimit)) {
        batch.set(_weekly.doc(d.id), d.data());
      }
      await batch.commit();
    }

    await FirebaseFirestore.instance.collection('audit_logs').add({
      'action': 'timetable_preset_loaded',
      'presetId': presetId,
      'presetName': presetName,
      'triggeredBy': loadedBy,
      'timestamp': FieldValue.serverTimestamp(),
    });
  }
}
