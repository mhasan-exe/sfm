/// One row in a [TimeProfileModel]: either a teaching period or a break
/// (recess/lunch/etc). Breaks are never assigned a teacher by the timetable
/// generator/scaffolder — they exist purely so the school day's timing is
/// fully represented (and so break duties can be scheduled against them).
class TimePeriod {
  final int periodNumber;

  final String startTime;
  final String endTime;

  /// True when this row is a break (recess, lunch, assembly, etc) rather
  /// than a teaching unit. Defaults to false so older documents (created
  /// before this field existed) are treated as ordinary teaching periods.
  final bool isBreak;

  /// Human label, e.g. "Period 3" or "Lunch Break". Optional — when empty
  /// the UI falls back to "Period N" / "Break".
  final String label;

  TimePeriod({
    required this.periodNumber,
    required this.startTime,
    required this.endTime,
    this.isBreak = false,
    this.label = '',
  });

  /// Duration of this period in minutes (best-effort; 0 if times are bad).
  int get durationMinutes {
    final s = toMinutes(startTime);
    final e = toMinutes(endTime);
    if (s == null || e == null) return 0;
    final diff = e - s;
    return diff > 0 ? diff : 0;
  }

  String get displayLabel =>
      label.trim().isNotEmpty ? label.trim() : (isBreak ? 'Break' : 'Period $periodNumber');

  /// Parses a "HH:mm" (24h) or "h:mm AM/PM" string into minutes since
  /// midnight. Returns null when unparseable.
  static int? toMinutes(String t) {
    final trimmed = t.trim();
    if (trimmed.isEmpty) return null;
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?$').firstMatch(trimmed);
    if (match == null) return null;
    var hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    final ampm = match.group(3);
    if (ampm != null) {
      final isPM = ampm.toUpperCase() == 'PM';
      if (hour == 12) {
        hour = isPM ? 12 : 0;
      } else {
        hour = isPM ? hour + 12 : hour;
      }
    }
    return hour * 60 + minute;
  }

  Map<String, dynamic> toMap() {
    return {
      'periodNumber': periodNumber,
      'startTime': startTime,
      'endTime': endTime,
      'isBreak': isBreak,
      'label': label,
    };
  }

  factory TimePeriod.fromMap(Map<String, dynamic> map) {
    return TimePeriod(
      periodNumber: (map['periodNumber'] as num?)?.toInt() ?? 0,
      startTime: map['startTime']?.toString() ?? '',
      endTime: map['endTime']?.toString() ?? '',
      isBreak: map['isBreak'] as bool? ?? false,
      label: map['label']?.toString() ?? '',
    );
  }

  TimePeriod copyWith({
    int? periodNumber,
    String? startTime,
    String? endTime,
    bool? isBreak,
    String? label,
  }) {
    return TimePeriod(
      periodNumber: periodNumber ?? this.periodNumber,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isBreak: isBreak ?? this.isBreak,
      label: label ?? this.label,
    );
  }
}

class TimeProfileModel {
  final String id;

  final String name;

  final List<TimePeriod> periods;

  /// Optional Friday-specific override rows. Empty means "no override —
  /// Friday uses [periods] like every other day" (the default). When set,
  /// this completely replaces [periods] for Friday only; every other day
  /// keeps using [periods] untouched.
  final List<TimePeriod> fridayPeriods;

  TimeProfileModel({
    required this.id,
    required this.name,
    required this.periods,
    this.fridayPeriods = const [],
  });

  /// True when Friday has its own custom periods set on this profile.
  bool get hasCustomFriday => fridayPeriods.isNotEmpty;

  /// Teaching periods only, in order — what the timetable grid actually
  /// scaffolds slots for. Breaks are intentionally excluded.
  List<TimePeriod> get teachingPeriods {
    final list = periods.where((p) => !p.isBreak).toList()
      ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    return list;
  }

  /// Friday's own teaching periods (from [fridayPeriods]), in order.
  /// Empty when Friday has no override — check [hasCustomFriday] or use
  /// [teachingPeriodsForDay] instead of calling this directly.
  List<TimePeriod> get fridayTeachingPeriods {
    final list = fridayPeriods.where((p) => !p.isBreak).toList()
      ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    return list;
  }

  /// The teaching periods to scaffold for [day] — [fridayTeachingPeriods]
  /// on Friday when a custom override is set, [teachingPeriods] otherwise.
  List<TimePeriod> teachingPeriodsForDay(String day) =>
      (day == 'Friday' && hasCustomFriday) ? fridayTeachingPeriods : teachingPeriods;

  List<TimePeriod> get breakPeriods {
    final list = periods.where((p) => p.isBreak).toList()
      ..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    return list;
  }

  /// All rows (teaching + breaks) sorted chronologically by period number.
  List<TimePeriod> get orderedAll {
    final list = [...periods]..sort((a, b) => a.periodNumber.compareTo(b.periodNumber));
    return list;
  }

  /// Total minutes the school day spans, from first row's start to last
  /// row's end (includes breaks).
  int get totalDayMinutes {
    if (periods.isEmpty) return 0;
    final ordered = orderedAll;
    final startMin = TimePeriod.toMinutes(ordered.first.startTime);
    final endMin = TimePeriod.toMinutes(ordered.last.endTime);
    if (startMin == null || endMin == null) return 0;
    final diff = endMin - startMin;
    return diff > 0 ? diff : 0;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'periods': periods.map((e) => e.toMap()).toList(),
      'fridayPeriods': fridayPeriods.map((e) => e.toMap()).toList(),
    };
  }

  factory TimeProfileModel.fromMap(Map<String, dynamic> map) {
    final rawPeriods = map['periods'];
    final rawFridayPeriods = map['fridayPeriods'];
    return TimeProfileModel(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      periods: rawPeriods is List
          ? rawPeriods
              .whereType<Map>()
              .map((e) => TimePeriod.fromMap(Map<String, dynamic>.from(e)))
              .toList()
          : <TimePeriod>[],
      fridayPeriods: rawFridayPeriods is List
          ? rawFridayPeriods
              .whereType<Map>()
              .map((e) => TimePeriod.fromMap(Map<String, dynamic>.from(e)))
              .toList()
          : <TimePeriod>[],
    );
  }
}
