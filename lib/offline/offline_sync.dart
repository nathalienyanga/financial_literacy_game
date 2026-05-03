import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'offline_queue.dart';

/// Handles background syncing of offline actions to Firestore
class OfflineSync {
  static Timer? _timer;

  /// Starts periodic sync every 10 seconds for the given UID
  static void startWorker(String uid) {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 10),
          (_) => sync(uid),
    );
  }

  /// Stop the sync worker
  static void stopWorker() {
    _timer?.cancel();
    _timer = null;
  }

  /// Manually trigger sync (used at login or app resume)
  static Future<void> sync(String uid) async {
    final queue = OfflineQueue(uid);
    final pending = await queue.getAll();

    if (pending.isEmpty) {
      debugPrint("Sync: No pending items for $uid");
      return;
    }

    debugPrint("Sync: ${pending.length} pending items for $uid");

    // Separate by type
    final subcollectionActions       = <Map<String, dynamic>>[];
    final participantDecisionActions = <Map<String, dynamic>>[];
    final legacyGamePlayActions      = <Map<String, dynamic>>[];
    final otherActions               = <Map<String, dynamic>>[];

    for (final action in pending) {
      if (action['actionType'] == 'participantDecision') {
        // Flat decision map: participantDecisions/{uid}
        participantDecisionActions.add(action);
      } else if (action.containsKey('subcollection')) {
        // Detailed rounds subcollection: participants/{uid}/rounds/{roundKey}
        subcollectionActions.add(action);
      } else if (action["collection"] == "gamePlay") {
        // Legacy round data written before subcollection migration
        legacyGamePlayActions.add(action);
      } else {
        // sessions, participants (non-subcollection), etc.
        otherActions.add(action);
      }
    }

    try {
      // Write flat decision documents (researcher-friendly view)
      if (participantDecisionActions.isNotEmpty) {
        await _syncParticipantDecisions(participantDecisionActions);
      }

      // Write subcollection documents (detailed per-round data)
      if (subcollectionActions.isNotEmpty) {
        await _syncSubcollectionBatch(subcollectionActions);
      }

      // Migrate any legacy gamePlay actions (batched dot-notation update)
      if (legacyGamePlayActions.isNotEmpty) {
        await _syncLegacyGamePlayBatch(legacyGamePlayActions);
      }

      // Scalar / summary documents
      for (final action in otherActions) {
        await _sendToFirestore(action);
      }

      // All successful → clear queue
      await queue.clear();
      debugPrint("Sync: Successfully synced ${pending.length} items");
    } catch (e) {
      debugPrint("Sync error: $e");
      // Queue remains for next sync attempt
    }
  }

  // ------------------------------------------------------------------
  // PARTICIPANT DECISIONS SYNC
  // Writes all per-round decisions as flat fields on participantDecisions/{uid}.
  // Uses merge:true so each sync call only adds new round keys without
  // overwriting existing ones.
  // ------------------------------------------------------------------
  static Future<void> _syncParticipantDecisions(
      List<Map<String, dynamic>> actions) async {
    // Group by uid (doc)
    final Map<String, Map<String, dynamic>> byUid = {};

    for (final action in actions) {
      final uid      = action['doc']      as String;
      final roundKey = action['roundKey'] as String;
      final data     = Map<String, dynamic>.from(action['data'] as Map);
      data['syncedAt'] = FieldValue.serverTimestamp();

      byUid.putIfAbsent(uid, () => {'uid': uid})[roundKey] = data;
    }

    final db = FirebaseFirestore.instance;
    for (final entry in byUid.entries) {
      final uid        = entry.key;
      final updateData = entry.value;
      await db
          .collection('participantDecisions')
          .doc(uid)
          .set(updateData, SetOptions(merge: true));
      debugPrint(
          'participantDecisions/$uid: ${updateData.length - 1} round(s) written');
    }
  }

  // ------------------------------------------------------------------
  // SUBCOLLECTION SYNC
  // Each action has: collection, doc, subcollection, subdoc, data
  // Writes: {collection}/{doc}/{subcollection}/{subdoc}
  // ------------------------------------------------------------------
  static Future<void> _syncSubcollectionBatch(
      List<Map<String, dynamic>> actions) async {
    // Group by parent collection+doc to batch per-parent
    final Map<String, List<Map<String, dynamic>>> byParent = {};
    for (final action in actions) {
      final parentKey = '${action["collection"]}/${action["doc"]}';
      byParent.putIfAbsent(parentKey, () => []).add(action);
    }

    final db = FirebaseFirestore.instance;

    for (final entry in byParent.entries) {
      final actions = entry.value;
      if (actions.isEmpty) continue;

      final firstAction = actions.first;
      final parentCol  = firstAction["collection"] as String;
      final parentDoc  = firstAction["doc"]         as String;
      final subCol     = firstAction["subcollection"] as String;

      final parentRef = db.collection(parentCol).doc(parentDoc);

      // Ensure parent document exists (no-op if already present)
      await parentRef.set({'uid': parentDoc}, SetOptions(merge: true));

      // Firestore WriteBatch limit is 500 docs; use chunks of 400 to be safe.
      const chunkSize = 400;
      for (var i = 0; i < actions.length; i += chunkSize) {
        final chunk = actions.sublist(i, (i + chunkSize).clamp(0, actions.length));
        final batch = db.batch();
        for (final action in chunk) {
          final subdoc = action["subdoc"] as String;
          final data   = Map<String, dynamic>.from(action["data"] as Map);
          data['syncedAt'] = FieldValue.serverTimestamp();
          batch.set(parentRef.collection(subCol).doc(subdoc), data);
        }
        await batch.commit();
      }

      debugPrint(
          "$parentCol/$parentDoc/$subCol: ${actions.length} doc(s) written");
    }
  }

  // ------------------------------------------------------------------
  // LEGACY GAMEPLAY SYNC  (pre-subcollection format)
  // Kept so any items already in the queue before this update still sync.
  // ------------------------------------------------------------------
  static Future<void> _syncLegacyGamePlayBatch(
      List<Map<String, dynamic>> actions) async {
    final gamePlayRef = FirebaseFirestore.instance.collection('gamePlay');

    final Map<String, List<Map<String, dynamic>>> byUid = {};
    for (final action in actions) {
      final uid = (action["doc"] as String?) ?? 'UNKNOWN';
      byUid.putIfAbsent(uid, () => []).add(
        Map<String, dynamic>.from(action["data"] as Map),
      );
    }

    for (final entry in byUid.entries) {
      final uid    = entry.key;
      final rounds = entry.value;
      final ref    = gamePlayRef.doc(uid);

      await ref.set({'uid': uid}, SetOptions(merge: true));

      final updateMap = <String, dynamic>{
        'syncedAt': FieldValue.serverTimestamp(),
      };
      for (final round in rounds) {
        final levelId   = round['levelId']     as int;
        final sessionId = round['sessionId']   as String;
        final roundNum  = round['roundNumber'] as int;
        updateMap['level_$levelId.${sessionId}_round_$roundNum'] = round;
      }
      await ref.update(updateMap);

      debugPrint("(legacy) gamePlay/$uid updated: ${rounds.length} round(s)");
    }
  }

  // ------------------------------------------------------------------
  // SINGLE DOCUMENT WRITE  (sessionSummaries, playerSummaries)
  // ------------------------------------------------------------------
  static Future<void> _sendToFirestore(Map<String, dynamic> action) async {
    final String collection = action["collection"];
    final Map<String, dynamic> data = Map<String, dynamic>.from(action["data"]);
    final String? doc = action["doc"];

    data['syncedAt'] = FieldValue.serverTimestamp();

    final colRef = FirebaseFirestore.instance.collection(collection);

    if ((collection == 'participants' || collection == 'playerSummaries') &&
        doc != null && doc.isNotEmpty) {
      await _upsertPlayerSummary(colRef.doc(doc), data);
      return;
    }

    if (doc != null && doc.isNotEmpty) {
      await colRef.doc(doc).set(data, SetOptions(merge: true));
    } else {
      await colRef.add(data);
    }
  }

  // ------------------------------------------------------------------
  // PLAYER SUMMARY UPSERT  (incremental counters via FieldValue)
  // ------------------------------------------------------------------
  static Future<void> _upsertPlayerSummary(
    DocumentReference ref,
    Map<String, dynamic> data,
  ) async {
    final Map<String, dynamic> writeData = {};

    for (final entry in data.entries) {
      if (!entry.key.startsWith('_increment')) {
        writeData[entry.key] = entry.value;
      }
    }

    if (data.containsKey('_incrementSessions'))
      writeData['totalSessions']      = FieldValue.increment(data['_incrementSessions'] as int);
    if (data.containsKey('_incrementRounds'))
      writeData['totalRounds']        = FieldValue.increment(data['_incrementRounds'] as int);
    if (data.containsKey('_incrementDurationMs'))
      writeData['totalDurationMs']    = FieldValue.increment(data['_incrementDurationMs'] as int);
    if (data.containsKey('_incrementBuyCash'))
      writeData['totalBuyCash']       = FieldValue.increment(data['_incrementBuyCash'] as int);
    if (data.containsKey('_incrementLoan'))
      writeData['totalLoan']          = FieldValue.increment(data['_incrementLoan'] as int);
    if (data.containsKey('_incrementDontBuy'))
      writeData['totalDontBuy']       = FieldValue.increment(data['_incrementDontBuy'] as int);
    if (data.containsKey('_incrementOptimal'))
      writeData['totalOptimal']       = FieldValue.increment(data['_incrementOptimal'] as int);
    if (data.containsKey('_incrementSuboptimal'))
      writeData['totalSuboptimal']    = FieldValue.increment(data['_incrementSuboptimal'] as int);
    if (data.containsKey('_incrementPoor'))
      writeData['totalPoor']          = FieldValue.increment(data['_incrementPoor'] as int);
    if (data.containsKey('_incrementRushing'))
      writeData['totalRushingRounds'] = FieldValue.increment(data['_incrementRushing'] as int);

    await ref.set(writeData, SetOptions(merge: true));
  }

  /// Sync every UID that has a pending queue on this device.
  /// Call this when the tablet comes back online to flush all offline sessions.
  /// Returns the number of UIDs that had pending data.
  static Future<int> syncAll() async {
    final prefs = await SharedPreferences.getInstance();
    final queueKeys = prefs.getKeys()
        .where((k) => k.startsWith('offline_queue_'))
        .toList();

    int count = 0;
    for (final key in queueKeys) {
      final uid = key.replaceFirst('offline_queue_', '');
      if (uid.isEmpty) continue;
      final pending = prefs.getString(key);
      if (pending == null || pending == '[]' || pending.isEmpty) continue;
      debugPrint("syncAll: syncing $uid");
      await sync(uid);
      count++;
    }
    debugPrint("syncAll: done — $count UID(s) synced");
    return count;
  }

  /// Check if currently syncing
  static bool get isRunning => _timer != null && _timer!.isActive;
}