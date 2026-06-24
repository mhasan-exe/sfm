
/// Result of a clash-aware teacher assignment attempt.
class ClashAssignmentOutcome {
  final bool assigned;
  final List<String> warnings;

  /// True when [assigned] is false specifically *because* a weekly quota
  /// would be exceeded (as opposed to a hard time clash). The UI uses this
  /// to offer an explicit "assign anyway" override instead of just
  /// reporting a dead-end failure.
  final bool quotaExceeded;

  /// True when [assigned] is false because the dragged teacher has an
  /// approved leave overlapping at least one future occurrence of this
  /// slot's weekday. Automation must never push through a leave conflict;
  /// only a manual admin "assign anyway" (passing `allowLeaveOverride:
  /// true`) may, and doing so still keeps every leave date vacated — the
  /// admin is overriding the *permanent weekly assignment*, not the leave
  /// itself.
  final bool leaveConflict;

  /// True when [assigned] is false because unit 1 is reserved for the
  /// class's configured class teacher and the dragged teacher isn't them.
  /// Only a manual admin "assign anyway" (passing `bypassFirstUnitProtection:
  /// true`) may override this, with a warning.
  final bool firstUnitConflict;

  const ClashAssignmentOutcome({
    required this.assigned,
    required this.warnings,
    this.quotaExceeded = false,
    this.leaveConflict = false,
    this.firstUnitConflict = false,
  });
}

