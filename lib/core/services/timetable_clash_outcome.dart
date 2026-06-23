
/// Result of a clash-aware teacher assignment attempt.
class ClashAssignmentOutcome {
  final bool assigned;
  final List<String> warnings;

  /// True when [assigned] is false specifically *because* a weekly quota
  /// would be exceeded (as opposed to a hard time clash). The UI uses this
  /// to offer an explicit "assign anyway" override instead of just
  /// reporting a dead-end failure.
  final bool quotaExceeded;

  const ClashAssignmentOutcome({
    required this.assigned,
    required this.warnings,
    this.quotaExceeded = false,
  });
}

