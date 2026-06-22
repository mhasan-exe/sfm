import 'dart:math';

import 'timetable_constants.dart';

class TeacherQuota {
  final String uid;
  final String name;
  final int unitsWeek;
  final bool isClassTeacher;

  const TeacherQuota({
    required this.uid,
    required this.name,
    required this.unitsWeek,
    required this.isClassTeacher,
  });
}

class AssignmentSlot {
  final String day;
  final int unit;
  final String slotId;
  final String startTime;
  final String endTime;

  const AssignmentSlot({
    required this.day,
    required this.unit,
    required this.slotId,
    required this.startTime,
    required this.endTime,
  });
}

class BusyBlock {
  final String day;
  final String startTime;
  final String endTime;

  const BusyBlock({
    required this.day,
    required this.startTime,
    required this.endTime,
  });
}

class TimetableGeneratorResult {
  final Map<String, String> slotIdToTeacherId;
  final List<String> unfilledSlotIds;
  final List<String> warnings;

  const TimetableGeneratorResult({
    required this.slotIdToTeacherId,
    required this.unfilledSlotIds,
    required this.warnings,
  });
}

/// Greedy heuristic timetable generator.
///
/// Hard rules (NEVER violated, even in [force] mode — these would create a
/// physically impossible schedule):
/// - A teacher is never double-booked at an overlapping time, whether the
///   clash is inside this class or against [externalBusy] from another class.
///
/// Strong rules (enforced unless [force] is set):
/// - The class teacher always takes unit 1 of every working day.
/// - A teacher teaches at most one unit per day in this class.
/// - A teacher must not be assigned more units in a week than their quota.
///
/// Preferences (soft, expressed as scoring penalties — lower score wins):
/// - Avoid back-to-back units for the same teacher.
/// - Avoid giving a teacher the SAME unit number on consecutive working days
///   (e.g. unit 8 on Monday should discourage unit 8 again on Tuesday).
/// - Strongly avoid giving a teacher the same unit number repeatedly across
///   the week — this is what stops "the same teacher every day on unit 2"
///   whenever a genuinely free alternate teacher exists for that slot.
/// - Spread load: mildly prefer teachers who are furthest below their quota.
/// - When several teachers end up scoring about the same for a slot, the
///   choice is randomized fairly between them rather than always picking
///   whichever teacher happens to be listed first — re-running generation
///   on the same input can therefore produce a slightly different (but
///   equally valid) rotation, which is intentional.
///
/// Note: if a class genuinely only has ONE eligible teacher for a given
/// unit (no clash, has quota) on every working day, the generator cannot
/// invent variety out of nothing — add a second teacher with quota for
/// that slot if rotation is wanted.
class TimetableGenerator {
  static TimetableGeneratorResult generate({
    required List<AssignmentSlot> slots,
    required List<TeacherQuota> teacherQuotas,
    Map<String, List<BusyBlock>> externalBusy = const {},
    bool force = false,
    Random? random,
  }) {
    final rng = random ?? Random();
    final warnings = <String>[];
    final slotToTeacher = <String, String>{};
    final unfilled = <String>[];

    if (slots.isEmpty) {
      return const TimetableGeneratorResult(
        slotIdToTeacherId: {},
        unfilledSlotIds: [],
        warnings: ['No slots to assign. Create the timetable grid first.'],
      );
    }
    if (teacherQuotas.isEmpty) {
      return TimetableGeneratorResult(
        slotIdToTeacherId: const {},
        unfilledSlotIds: slots.map((s) => s.slotId).toList(),
        warnings: const ['No teachers assigned to this class.'],
      );
    }

    final remaining = <String, int>{
      for (final t in teacherQuotas) t.uid: t.unitsWeek,
    };
    // Slots already given to each teacher in THIS run (for clash + 1/day).
    final assigned = <String, List<AssignmentSlot>>{
      for (final t in teacherQuotas) t.uid: <AssignmentSlot>[],
    };

    bool clashes(String teacherId, AssignmentSlot s) {
      for (final a in assigned[teacherId]!) {
        if (a.day == s.day &&
            timeRangesOverlap(a.startTime, a.endTime, s.startTime, s.endTime)) {
          return true;
        }
      }
      for (final b in externalBusy[teacherId] ?? const <BusyBlock>[]) {
        if (b.day == s.day &&
            timeRangesOverlap(b.startTime, b.endTime, s.startTime, s.endTime)) {
          return true;
        }
      }
      return false;
    }

    bool sameDayAlready(String teacherId, AssignmentSlot s) =>
        assigned[teacherId]!.any((a) => a.day == s.day);

    void commit(AssignmentSlot s, String teacherId) {
      slotToTeacher[s.slotId] = teacherId;
      assigned[teacherId]!.add(s);
      remaining[teacherId] = (remaining[teacherId] ?? 0) - 1;
    }

    // Order slots deterministically: by day order, then unit.
    final ordered = [...slots]..sort((a, b) {
        final d = workingDayIndex(a.day).compareTo(workingDayIndex(b.day));
        return d != 0 ? d : a.unit.compareTo(b.unit);
      });

    // Unique, day-ordered list of working days actually present in the grid.
    final orderedDays = ordered.map((s) => s.day).toSet().toList()
      ..sort((a, b) => workingDayIndex(a).compareTo(workingDayIndex(b)));

    /// Returns the working day immediately before [day] in [orderedDays],
    /// or null if [day] is the first working day in the grid.
    String? previousWorkingDay(String day) {
      final idx = orderedDays.indexOf(day);
      if (idx <= 0) return null;
      return orderedDays[idx - 1];
    }

    final classTeachers = teacherQuotas.where((t) => t.isClassTeacher).toList();

    // Track how often each teacher gets each unit across the week (for the
    // "avoid repeating units" soft rule).
    final unitRepeatCount = <String, Map<int, int>>{
      for (final t in teacherQuotas) t.uid: <int, int>{}
    };

    // ---------------------------------------------------------------------
    // Step 1: the class teacher ALWAYS takes unit 1 of every working day.
    // This is a strong rule, not a preference — we don't "choose" a unit
    // here, unit 1 is fixed by definition of what a class teacher is.
    // ---------------------------------------------------------------------
    for (final day in orderedDays) {
      if (classTeachers.isEmpty) break;

      final unitOneSlot = ordered.firstWhere(
        (s) => s.day == day && s.unit == 1,
        orElse: () => const AssignmentSlot(
          day: '', unit: -1, slotId: '', startTime: '', endTime: '',
        ),
      );
      if (unitOneSlot.unit < 0) continue; // no unit-1 slot scaffolded for this day

      for (final ct in classTeachers) {
        if (slotToTeacher.containsKey(unitOneSlot.slotId)) break;

        if (clashes(ct.uid, unitOneSlot)) {
          warnings.add(
              '${ct.name} (class teacher) clashes on ${unitOneSlot.day} unit 1; left for manual fix.');
          continue;
        }

        if (!force && (remaining[ct.uid] ?? 0) <= 0) {
          warnings.add(
              '${ct.name} ran out of weekly units before covering ${unitOneSlot.day} unit 1. Increase their quota.');
        }

        commit(unitOneSlot, ct.uid);
        unitRepeatCount[ct.uid]?[1] = (unitRepeatCount[ct.uid]?[1] ?? 0) + 1;
      }
    }

    // ---------------------------------------------------------------------
    // Step 2: fill every remaining slot (every non-class-teacher slot, plus
    // any unit-1 slot the class teacher couldn't take due to a clash).
    // ---------------------------------------------------------------------
    for (final s in ordered) {
      if (slotToTeacher.containsKey(s.slotId)) continue;

      // Collect every eligible teacher's score, then pick randomly among
      // whichever are tied for best (within a small tolerance) — this is
      // the "if multiple valid teachers exist, randomize fairly" rule.
      // Without this, ties were always broken by list order, so the same
      // first-listed teacher silently won every single day → zero variety.
      final candidates = <(String uid, int score)>[];

      for (final t in teacherQuotas) {
        if (clashes(t.uid, s)) continue; // hard rule, always

        final hasQuota = (remaining[t.uid] ?? 0) > 0;
        if (!hasQuota && !force) continue; // strong rule: never exceed quota

        var score = 0;

        // Strong: one unit per day per teacher in this class.
        if (sameDayAlready(t.uid, s)) {
          if (!force) continue;
          score += 10000;
        }

        // Soft: avoid consecutive units for the same teacher.
        for (final a in assigned[t.uid]!) {
          if (a.day == s.day && (a.unit - s.unit).abs() == 1) score += 500;
        }

        // Soft, but heavily weighted: avoid repeating the exact same unit
        // the teacher had on the immediately preceding working day.
        // E.g. unit 8 on Monday should strongly discourage unit 8 again on
        // Tuesday for the same teacher.
        final prevDay = previousWorkingDay(s.day);
        if (prevDay != null) {
          final hadSameUnitYesterday = assigned[t.uid]!
              .any((a) => a.day == prevDay && a.unit == s.unit);
          if (hadSameUnitYesterday) score += 600;
        }

        // Soft: avoid repeating the same unit for this teacher across the
        // whole week. Weighted heavily (300/occurrence, escalating) so it
        // reliably outweighs the quota-spread term below whenever a
        // genuinely free alternate teacher exists — this is the main fix
        // for "the same teacher gets unit 2 every single day".
        final repeatCnt = unitRepeatCount[t.uid]?[s.unit] ?? 0;
        score += repeatCnt * 300;

        // Soft: over-quota is undesirable even in force mode.
        if (!hasQuota) score += 2000;

        // Balance: mildly prefer teachers with more remaining quota
        // (spreads load) — intentionally a *small* influence relative to
        // the repeat penalty above, so it tie-breaks rather than dominates.
        score -= (remaining[t.uid] ?? 0) * 2;

        // Small random jitter so genuinely-comparable candidates don't
        // always resolve to the same teacher in the same order every time
        // a timetable is (re)generated.
        score += rng.nextInt(20);

        candidates.add((t.uid, score));
      }

      if (candidates.isNotEmpty) {
        candidates.sort((a, b) => a.$2.compareTo(b.$2));
        final bestScore = candidates.first.$2;
        // Anyone within a small tolerance of the best score is considered
        // an equally valid pick — randomize among them.
        final tied = candidates.where((c) => c.$2 <= bestScore + 15).toList();
        final chosen = tied[rng.nextInt(tied.length)].$1;

        commit(s, chosen);
        unitRepeatCount[chosen]?[s.unit] = (unitRepeatCount[chosen]?[s.unit] ?? 0) + 1;
      } else {
        unfilled.add(s.slotId);
      }
    }

    if (unfilled.isNotEmpty) {
      warnings.add(
          '${unfilled.length} slot(s) could not be auto-filled. Assign them manually or add teacher quota.');
    }

    return TimetableGeneratorResult(
      slotIdToTeacherId: slotToTeacher,
      unfilledSlotIds: unfilled,
      warnings: warnings,
    );
  }
}
