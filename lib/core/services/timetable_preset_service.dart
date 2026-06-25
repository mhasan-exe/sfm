import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/timetable_preset_model.dart';
import 'timetable_service.dart';

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

    // Captured BEFORE any writes below — needed afterwards so we know
    // every teacherId/slotId that's about to change hands, in order to
    // clean up whatever that change makes stale (leave exceptions tied to
    // a teacher who no longer holds a slot, open fixtures for a vacancy a
    // restored assignment just resolved). Restoring a preset is, from the
    // schedule's point of view, just another way `weekly_timetables` can
    // change out from under teachers/fixtures/leave exceptions — it needs
    // the exact same reconciliation a manual assignment gets.
    final previousTeacherBySlotId = {
      for (final d in currentSnap.docs) d.id: (d.data()['teacherId'] as String?) ?? ''
    };

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

    // Every slot that existed before OR after the restore, and every
    // teacherId that lost or gained one — diffed against what each slot's
    // teacherId actually was beforehand vs. what the preset says now.
    final touchedSlotIds = <String>{};
    final touchedTeacherIds = <String>{};
    for (final d in restoreDocs) {
      final newTeacherId = (d.data()['teacherId'] as String?) ?? '';
      final oldTeacherId = previousTeacherBySlotId[d.id] ?? '';
      if (newTeacherId != oldTeacherId) {
        touchedSlotIds.add(d.id);
      }
      if (newTeacherId.isNotEmpty) touchedTeacherIds.add(newTeacherId);
      if (oldTeacherId.isNotEmpty) touchedTeacherIds.add(oldTeacherId);
    }
    for (final d in toDelete) {
      final oldTeacherId = previousTeacherBySlotId[d.id] ?? '';
      if (oldTeacherId.isNotEmpty) touchedTeacherIds.add(oldTeacherId);
    }

    try {
      await TimetableService().reconcileAfterBulkWeeklyRewrite(
        touchedSlotIds: touchedSlotIds.toList(),
        touchedTeacherIds: touchedTeacherIds.toList(),
        deletedSlotIds: toDelete.map((d) => d.id).toList(),
      );
    } catch (_) {
      // Best-effort — the restore itself already committed; worst case an
      // admin needs to hit "Resync schedule" for an affected teacher
      // afterwards, same recovery path leave approval already has.
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
