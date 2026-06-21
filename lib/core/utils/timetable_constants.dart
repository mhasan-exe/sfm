/// Shared constants for the timetable domain.
///
/// Centralised here so every screen, service and the generator agree on the
/// same working week and field conventions. Changing the working week (e.g.
/// adding Saturday) only needs to happen in one place.
library;

/// Canonical ordered working days used for scaffolding and display.
///
/// A class may override this with its own `workingDays` field, but this is the
/// default and the order used when sorting/rendering.
const List<String> kWorkingDays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
];

/// All days (incl. weekend) used only for mapping `DateTime.weekday` -> name.
const List<String> kAllDayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Returns the weekday name (Monday..Sunday) for a [DateTime].
String dayNameForDate(DateTime date) => kAllDayNames[date.weekday - 1];

/// Returns the index of [day] within the canonical week order, or a large
/// number if it is not a recognised working day (so unknown days sort last).
int workingDayIndex(String day) {
  final i = kWorkingDays.indexOf(day);
  return i == -1 ? 1000 : i;
}

/// Parses a "HH:mm" (or "HH:mm AM/PM") time string into minutes since midnight.
///
/// Returns 0 when the value cannot be parsed so callers never crash on bad
/// Firestore data.
int parseTimeToMinutes(String? time) {
  if (time == null || time.trim().isEmpty) return 0;
  final cleaned = time.trim();
  final isPm = cleaned.toUpperCase().contains('PM');
  final isAm = cleaned.toUpperCase().contains('AM');
  final digits = cleaned.replaceAll(RegExp(r'[^0-9:]'), '');
  final parts = digits.split(':');
  if (parts.isEmpty) return 0;
  var hour = int.tryParse(parts[0]) ?? 0;
  final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  if (isPm && hour < 12) hour += 12;
  if (isAm && hour == 12) hour = 0;
  return hour * 60 + minute;
}

/// True when two [start, end) intervals (in "HH:mm") overlap.
bool timeRangesOverlap(
  String startA,
  String endA,
  String startB,
  String endB,
) {
  final sA = parseTimeToMinutes(startA);
  final eA = parseTimeToMinutes(endA);
  final sB = parseTimeToMinutes(startB);
  final eB = parseTimeToMinutes(endB);
  return sA < eB && sB < eA;
}
