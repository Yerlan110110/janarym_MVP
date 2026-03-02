import '../personalization/data/personalization_database.dart';
import '../personalization/data/secure_payload_codec.dart';
import '../personalization/personalization_repository.dart';

class SceneAnchorRecord {
  const SceneAnchorRecord({
    required this.name,
    required this.summary,
    required this.updatedAtMs,
  });

  final String name;
  final String summary;
  final int updatedAtMs;
}

class SceneMemoryService {
  SceneMemoryService({
    required PersonalizationDatabase database,
    required SecurePayloadCodec codec,
  }) : _database = database,
       _codec = codec;

  final PersonalizationDatabase _database;
  final SecurePayloadCodec _codec;

  Future<void> saveAnchor({
    required String anchorName,
    required String summary,
  }) async {
    final db = await _database.database;
    final cleanName = anchorName.trim();
    final cleanSummary = summary.trim();
    if (cleanName.isEmpty || cleanSummary.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final roomKey = normalizeText(cleanName);
    final encryptedName = await _codec.encrypt(cleanName);
    final encryptedSummary = await _codec.encrypt(cleanSummary);
    await db.insert('scene_objects', <String, Object?>{
      'room_key': roomKey.isEmpty ? 'scene' : roomKey,
      'object_label': encryptedName,
      'anchor_hint': encryptedSummary,
      'x': null,
      'y': null,
      'z': null,
      'confidence': 1.0,
      'last_seen_at': now,
    });
    await _database.pruneSceneObjects();
  }

  Future<SceneAnchorRecord?> findBestAnchor(String query) async {
    final db = await _database.database;
    final normalized = normalizeText(query);
    final rows = await db.query(
      'scene_objects',
      orderBy: 'last_seen_at DESC',
      limit: 40,
    );
    for (final row in rows) {
      final label = await _codec.decrypt(
        (row['object_label'] as String? ?? '').trim(),
      );
      final summary = await _codec.decrypt(
        (row['anchor_hint'] as String? ?? '').trim(),
      );
      if (label.isEmpty || summary.isEmpty) continue;
      final labelNorm = normalizeText(label);
      if (normalized.isEmpty ||
          labelNorm == normalized ||
          labelNorm.contains(normalized) ||
          normalized.contains(labelNorm)) {
        return SceneAnchorRecord(
          name: label,
          summary: summary,
          updatedAtMs: (row['last_seen_at'] as int?) ?? 0,
        );
      }
    }
    return null;
  }

  Future<List<SceneAnchorRecord>> recentAnchors({int limit = 6}) async {
    final db = await _database.database;
    final rows = await db.query(
      'scene_objects',
      orderBy: 'last_seen_at DESC',
      limit: limit,
    );
    final result = <SceneAnchorRecord>[];
    for (final row in rows) {
      final name = await _codec.decrypt(
        (row['object_label'] as String? ?? '').trim(),
      );
      final summary = await _codec.decrypt(
        (row['anchor_hint'] as String? ?? '').trim(),
      );
      if (name.isEmpty || summary.isEmpty) continue;
      result.add(
        SceneAnchorRecord(
          name: name,
          summary: summary,
          updatedAtMs: (row['last_seen_at'] as int?) ?? 0,
        ),
      );
    }
    return result;
  }
}
