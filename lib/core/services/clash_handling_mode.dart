enum ClashHandlingMode {
  /// Abort swap if clash is detected; transaction rollback.
  rollback,

  /// Allow swap even if clash; UI should warn the admin.
  warnOnly,

  /// Best-effort auto resolution by clearing the conflicting teacher(s)
  /// for destination slot(s).
  autoFindNonClashing,
}

