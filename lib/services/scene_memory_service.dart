import '../personalization/data/personalization_database.dart';
import '../personalization/data/secure_payload_codec.dart';
import '../personalization/personalization_repository.dart';
import 'package:sqflite/sqflite.dart';

class SceneAnchorRecord {
  const SceneAnchorRecord({
    required this.name,
    required this.summary,
    required this.kind,
    required this.updatedAtMs,
  });

  final String name;
  final String summary;
  final String kind;
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
    String kind = 'note',
  }) async {
    final db = await _database.database;
    final cleanName = anchorName.trim();
    final cleanSummary = summary.trim();
    if (cleanName.isEmpty || cleanSummary.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final nameNorm = normalizeText(cleanName);
    final encryptedName = await _codec.encrypt(cleanName);
    final encryptedSummary = await _codec.encrypt(cleanSummary);
    final cleanKind = kind.trim().isEmpty ? 'note' : kind.trim();
    await db.insert('memory_notes', <String, Object?>{
      'key_name': encryptedName,
      'key_name_norm': nameNorm.isEmpty ? 'memory' : nameNorm,
      'note_value': encryptedSummary,
      'kind': cleanKind,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _database.pruneMemoryNotes();
  }

  Future<SceneAnchorRecord?> findBestAnchor(String query) async {
    final db = await _database.database;
    final normalized = normalizeText(query);
    final noteRows = await db.query(
      'memory_notes',
      orderBy: 'updated_at DESC',
      limit: 60,
    );
    final noteMatch = await _findInMemoryNotes(noteRows, normalized);
    if (noteMatch != null) {
      return noteMatch;
    }

    // Backward-compatible read path for old scene-memory entries.
    final legacyRows = await db.query(
      'scene_objects',
      orderBy: 'last_seen_at DESC',
      limit: 40,
    );
    return _findInLegacySceneObjects(legacyRows, normalized);
  }

  Future<List<SceneAnchorRecord>> recentAnchors({int limit = 6}) async {
    final db = await _database.database;
    final rows = await db.query(
      'memory_notes',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    final result = <SceneAnchorRecord>[];
    for (final row in rows) {
      final name = await _codec.decrypt(
        (row['key_name'] as String? ?? '').trim(),
      );
      final summary = await _codec.decrypt(
        (row['note_value'] as String? ?? '').trim(),
      );
      if (name.isEmpty || summary.isEmpty) continue;
      result.add(
        SceneAnchorRecord(
          name: name,
          summary: summary,
          kind: (row['kind'] as String? ?? 'note').trim(),
          updatedAtMs: (row['updated_at'] as int?) ?? 0,
        ),
      );
    }
    if (result.isNotEmpty) {
      return result;
    }

    final legacyRows = await db.query(
      'scene_objects',
      orderBy: 'last_seen_at DESC',
      limit: limit,
    );
    for (final row in legacyRows) {
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
          kind: 'legacy_scene',
          updatedAtMs: (row['last_seen_at'] as int?) ?? 0,
        ),
      );
    }
    return result;
  }

  Future<SceneAnchorRecord?> _findInMemoryNotes(
    List<Map<String, Object?>> rows,
    String normalized,
  ) async {
    for (final row in rows) {
      final name = await _codec.decrypt(
        (row['key_name'] as String? ?? '').trim(),
      );
      final summary = await _codec.decrypt(
        (row['note_value'] as String? ?? '').trim(),
      );
      if (name.isEmpty || summary.isEmpty) continue;
      final labelNorm = normalizeText(name);
      if (normalized.isEmpty ||
          labelNorm == normalized ||
          labelNorm.contains(normalized) ||
          normalized.contains(labelNorm)) {
        return SceneAnchorRecord(
          name: name,
          summary: summary,
          kind: (row['kind'] as String? ?? 'note').trim(),
          updatedAtMs: (row['updated_at'] as int?) ?? 0,
        );
      }
    }
    return null;
  }

  Future<SceneAnchorRecord?> _findInLegacySceneObjects(
    List<Map<String, Object?>> rows,
    String normalized,
  ) async {
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
          kind: 'legacy_scene',
          updatedAtMs: (row['last_seen_at'] as int?) ?? 0,
        );
      }
    }
    return null;
  }
}
