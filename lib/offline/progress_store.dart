import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists level progress to Firestore (the authoritative cross-device source)
/// and mirrors it in SharedPreferences as an instant local fallback.
///
/// Firestore's built-in offline persistence queues writes when the tablet is
/// offline and flushes them automatically once connectivity returns, so no
/// separate sync worker is needed for progress data.
class ProgressStore {
  static const String _collection = 'participants';

  // ------------------------------------------------------------------ WRITE
  /// Call whenever a player completes a level.
  /// [nextLevelId] is 0-indexed: the level the player should start next.
  static Future<void> recordLevelComplete({
    required String uid,
    required int nextLevelId,
  }) async {
    if (uid.isEmpty || uid == 'UNKNOWN') return;

    // Firestore write — queued offline automatically by the SDK.
    try {
      await FirebaseFirestore.instance
          .collection(_collection)
          .doc(uid)
          .set({
        'currentLevel': nextLevelId,
        'lastCompletedLevel': nextLevelId > 0 ? nextLevelId - 1 : 0,
        'updatedAt': FieldValue.serverTimestamp(),
        'version': FieldValue.increment(1),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('ProgressStore.recordLevelComplete Firestore error: $e');
    }

    // Local mirror — always works, zero latency.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nextLevel_$uid', nextLevelId);

    debugPrint('ProgressStore: uid=$uid nextLevel=$nextLevelId saved');
  }

  // ------------------------------------------------------------------- READ
  /// Returns the next level index (0-indexed) for [uid], or null for a new
  /// player.  Reads from Firestore first, falls back to local prefs, then
  /// resolves conflicts with "highest level wins".
  static Future<int?> getNextLevel(String uid) async {
    if (uid.isEmpty) return null;

    final prefs = await SharedPreferences.getInstance();
    final localLevel = prefs.getInt('nextLevel_$uid');
    int? firestoreLevel;

    // Try server; fall through to Firestore's local cache if unreachable.
    try {
      final snap = await FirebaseFirestore.instance
          .collection(_collection)
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 3));
      if (snap.exists) {
        firestoreLevel = (snap.data()?['currentLevel'] as num?)?.toInt();
      }
    } catch (_) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(_collection)
            .doc(uid)
            .get(const GetOptions(source: Source.cache));
        if (snap.exists) {
          firestoreLevel = (snap.data()?['currentLevel'] as num?)?.toInt();
        }
      } catch (_) {}
    }

    final resolved = _maxLevel(localLevel, firestoreLevel);
    debugPrint('ProgressStore.getNextLevel uid=$uid '
        'local=$localLevel firestore=$firestoreLevel resolved=$resolved');

    if (resolved == null) return null;

    // Reconcile whichever source is behind.
    if (localLevel == null || resolved > localLevel) {
      await prefs.setInt('nextLevel_$uid', resolved);
    }
    if (firestoreLevel == null || resolved > firestoreLevel) {
      _pushToFirestore(uid, resolved); // fire-and-forget, offline-safe
    }

    return resolved;
  }

  // -------------------------------------------------------- PENDING-SYNC CHECK
  /// True if any UID on this device still has unsynced round data.
  static Future<bool> hasAnyPending() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getKeys().any((k) {
      if (!k.startsWith('offline_queue_')) return false;
      final v = prefs.getString(k);
      return v != null && v != '[]' && v.isNotEmpty;
    });
  }

  /// Returns {uid: roundCount} for every UID with pending data on this device.
  static Future<Map<String, int>> allPendingCounts() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <String, int>{};
    for (final key
        in prefs.getKeys().where((k) => k.startsWith('offline_queue_'))) {
      final uid = key.replaceFirst('offline_queue_', '');
      if (uid.isEmpty) continue;
      final raw = prefs.getString(key) ?? '[]';
      if (raw == '[]' || raw.isEmpty) continue;
      try {
        result[uid] = (jsonDecode(raw) as List).length;
      } catch (_) {
        result[uid] = 1; // non-empty but unparseable
      }
    }
    return result;
  }

  // ----------------------------------------------------------------- HELPERS
  static int? _maxLevel(int? a, int? b) {
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  static void _pushToFirestore(String uid, int level) {
    FirebaseFirestore.instance
        .collection(_collection)
        .doc(uid)
        .set({
      'currentLevel': level,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true))
        .catchError((_) {});
  }
}