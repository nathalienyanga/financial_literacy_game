import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineStorage {
  static String _activeUID = '';
  static SharedPreferences? _prefs;

  /// ------------------------------------------------------------
  /// UID management for queue operations
  /// ------------------------------------------------------------
  static void setActiveUID(String uid) {
    _activeUID = uid;
  }

  static Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// ------------------------------------------------------------
  /// QUEUE operations for offline actions
  /// ------------------------------------------------------------
  static String _queueKey() => 'offline_queue_$_activeUID';

  static List<Map<String, dynamic>> loadQueue() {
    if (_prefs == null) return [];
    final jsonString = _prefs!.getString(_queueKey());
    if (jsonString == null || jsonString.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(jsonString);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveQueue(List<Map<String, dynamic>> queue) async {
    final prefs = await _getPrefs();
    await prefs.setString(_queueKey(), jsonEncode(queue));
  }

  static Future<void> clearQueue() async {
    final prefs = await _getPrefs();
    await prefs.remove(_queueKey());
  }

  // Key-explicit variants used by OfflineQueue to avoid _activeUID race conditions.
  static Future<List<Map<String, dynamic>>> loadQueueForKey(String key) async {
    final prefs = await _getPrefs();
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) return [];
    try {
      final List<dynamic> decoded = jsonDecode(jsonString);
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveQueueForKey(String key, List<Map<String, dynamic>> queue) async {
    final prefs = await _getPrefs();
    await prefs.setString(key, jsonEncode(queue));
  }

  static Future<void> clearQueueForKey(String key) async {
    final prefs = await _getPrefs();
    await prefs.remove(key);
  }
  /// ------------------------------------------------------------
  /// SAVE simple key–value game state
  /// ------------------------------------------------------------
  static Future<void> saveSimpleState(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    if (data["cash"] != null) {
      await prefs.setDouble("cash", data["cash"]);
    }
    if (data["levelId"] != null) {
      await prefs.setInt("levelId", data["levelId"]);
    }
    if (data["period"] != null) {
      await prefs.setInt("period", data["period"]);
    }
    if (data["locale"] != null) {
      await prefs.setString("locale", data["locale"]);
      await prefs.setString("languageCode", data["locale"]);
    }
  }

  /// ------------------------------------------------------------
  /// LOAD simple game state
  /// ------------------------------------------------------------
  static Future<Map<String, dynamic>> loadSimpleState() async {
    final prefs = await SharedPreferences.getInstance();

    return {
      "cash": prefs.getDouble("cash"),
      "levelId": prefs.getInt("levelId"),
      "period": prefs.getInt("period"),
      "locale": prefs.getString("locale"),
    };
  }

  /// ------------------------------------------------------------
  /// CLEAR simple saved game data
  /// Called when logging out or switching user
  /// ------------------------------------------------------------
  static Future<void> clearSimpleState() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove("cash");
    await prefs.remove("levelId");
    await prefs.remove("period");
    await prefs.remove("locale");
  }

  /// ------------------------------------------------------------
  /// LAST ROUND tracking for resume functionality
  /// ------------------------------------------------------------

  /// Save current round data for resume
  static Future<void> saveLastRound(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    if (data["roundNumber"] != null) {
      await prefs.setInt("lastRoundNumber", data["roundNumber"]);
    }
    if (data["sessionId"] != null) {
      await prefs.setString("lastSessionId", data["sessionId"]);
    }
  }

  /// Load last round data for resume
  static Future<Map<String, dynamic>?> loadLastRound() async {
    final prefs = await SharedPreferences.getInstance();

    final roundNumber = prefs.getInt("lastRoundNumber");
    final sessionId = prefs.getString("lastSessionId");

    if (roundNumber == null && sessionId == null) {
      return null;
    }

    return {
      "roundNumber": roundNumber ?? 0,
      "sessionId": sessionId ?? "",
    };
  }

  /// Clear last round data on logout
  static Future<void> clearLastRound() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove("lastRoundNumber");
    await prefs.remove("lastSessionId");
  }

  /// ------------------------------------------------------------
  /// Initialize - must be called before using queue operations
  /// ------------------------------------------------------------
  static Future<void> initialize() async {
    await _getPrefs();
  }
}
