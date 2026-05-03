import 'offline_storage.dart';

/// OfflineQueue handles per-UID action storage using a UID-specific key.
/// All operations use the key captured at construction so concurrent syncs
/// for different UIDs never corrupt each other's queue.
class OfflineQueue {
  final String uid;
  final String _key;

  OfflineQueue(this.uid) : _key = 'offline_queue_$uid';

  /// Add a single pending action
  Future<void> add(Map<String, dynamic> action) async {
    final current = await OfflineStorage.loadQueueForKey(_key);
    current.add(action);
    await OfflineStorage.saveQueueForKey(_key, current);
  }

  /// Return all queued actions for this UID
  Future<List<Map<String, dynamic>>> getAll() async {
    return OfflineStorage.loadQueueForKey(_key);
  }

  /// Clear actions after successful sync
  Future<void> clear() async {
    await OfflineStorage.clearQueueForKey(_key);
  }
}


