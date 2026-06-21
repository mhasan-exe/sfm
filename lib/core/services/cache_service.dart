import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // Cache keys
  static const String _prefix = 'sfm_';
  static const String _timeProfilesKey = '${_prefix}time_profiles';
  static const String _classesKey = '${_prefix}classes';
  static const String _timetableKey = '${_prefix}timetable_';
  static const String _teachersKey = '${_prefix}teachers';
  static const String _fixturesKey = '${_prefix}fixtures';
  static const String _leaveRequestsKey = '${_prefix}leave_requests';
  static const String _tempTimetableKey = '${_prefix}temp_timetable_';

  // Cache time profiles
  Future<void> cacheTimeProfiles(List<Map<String, dynamic>> profiles) async {
    await _prefs.setString(
      _timeProfilesKey,
      jsonEncode(profiles),
    );
  }

  List<Map<String, dynamic>>? getTimeProfiles() {
    final cached = _prefs.getString(_timeProfilesKey);
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache classes
  Future<void> cacheClasses(List<Map<String, dynamic>> classes) async {
    await _prefs.setString(
      _classesKey,
      jsonEncode(classes),
    );
  }

  List<Map<String, dynamic>>? getClasses() {
    final cached = _prefs.getString(_classesKey);
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache timetable for a class
  Future<void> cacheTimetable(
    String classId,
    List<Map<String, dynamic>> slots,
  ) async {
    await _prefs.setString(
      '$_timetableKey$classId',
      jsonEncode(slots),
    );
  }

  List<Map<String, dynamic>>? getTimetable(String classId) {
    final cached = _prefs.getString('$_timetableKey$classId');
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache temporary timetable (for live updates)
  Future<void> cacheTempTimetable(
    String userId,
    List<Map<String, dynamic>> assignments,
  ) async {
    await _prefs.setString(
      '$_tempTimetableKey$userId',
      jsonEncode(assignments),
    );
  }

  List<Map<String, dynamic>>? getTempTimetable(String userId) {
    final cached = _prefs.getString('$_tempTimetableKey$userId');
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache teachers
  Future<void> cacheTeachers(List<Map<String, dynamic>> teachers) async {
    await _prefs.setString(
      _teachersKey,
      jsonEncode(teachers),
    );
  }

  List<Map<String, dynamic>>? getTeachers() {
    final cached = _prefs.getString(_teachersKey);
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache fixtures
  Future<void> cacheFixtures(List<Map<String, dynamic>> fixtures) async {
    await _prefs.setString(
      _fixturesKey,
      jsonEncode(fixtures),
    );
  }

  List<Map<String, dynamic>>? getFixtures() {
    final cached = _prefs.getString(_fixturesKey);
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Cache leave requests
  Future<void> cacheLeaveRequests(
    List<Map<String, dynamic>> leaves,
  ) async {
    await _prefs.setString(
      _leaveRequestsKey,
      jsonEncode(leaves),
    );
  }

  List<Map<String, dynamic>>? getLeaveRequests() {
    final cached = _prefs.getString(_leaveRequestsKey);
    if (cached == null) return null;
    try {
      final List<dynamic> decoded = jsonDecode(cached);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return null;
    }
  }

  // Generic cache methods
  Future<void> set(String key, dynamic value) async {
    if (value is String) {
      await _prefs.setString(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is List<String>) {
      await _prefs.setStringList(key, value);
    } else {
      // For complex objects, encode as JSON
      await _prefs.setString(key, jsonEncode(value));
    }
  }

  dynamic get(String key) {
    return _prefs.get(key);
  }

  Future<bool> remove(String key) async {
    return await _prefs.remove(key);
  }

  Future<bool> clear() async {
    return await _prefs.clear();
  }

  // Clear specific cache sections
  Future<void> clearTimetableCache() async {
    final keys = _prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith(_timetableKey) ||
          key.startsWith(_tempTimetableKey)) {
        await _prefs.remove(key);
      }
    }
  }

  Future<void> clearAllCache() async {
    await _prefs.clear();
  }

  // Utility to check if cache exists
  bool has(String key) => _prefs.containsKey(key);
}
