import 'package:sqflite/sqflite.dart';

import '../personalization/data/personalization_database.dart';
import '../personalization/data/secure_payload_codec.dart';

class ShoppingItemState {
  const ShoppingItemState({
    required this.name,
    required this.targetQty,
    required this.pickedQty,
    required this.status,
    this.shelfHint,
  });

  final String name;
  final int targetQty;
  final int pickedQty;
  final String status;
  final String? shelfHint;

  bool get isPicked => pickedQty >= targetQty || status == 'picked';
}

class ShoppingSessionSnapshot {
  const ShoppingSessionSnapshot({required this.sessionId, required this.items});

  final int sessionId;
  final List<ShoppingItemState> items;

  List<ShoppingItemState> get pendingItems =>
      items.where((item) => !item.isPicked).toList(growable: false);
}

class ShoppingModeService {
  ShoppingModeService({
    required PersonalizationDatabase database,
    required SecurePayloadCodec codec,
  }) : _database = database,
       _codec = codec;

  final PersonalizationDatabase _database;
  final SecurePayloadCodec _codec;

  Future<ShoppingSessionSnapshot?> currentSession() async {
    final db = await _database.database;
    final sessions = await db.query(
      'shopping_sessions',
      where: 'status = ?',
      whereArgs: ['active'],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (sessions.isEmpty) return null;
    final sessionId = sessions.first['id'] as int;
    return _loadSession(db, sessionId);
  }

  Future<ShoppingSessionSnapshot> startSessionFromText(String userText) async {
    final items = _parseItems(userText);
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionId = await _database.runInTransaction<int>((tx) async {
      await tx.update(
        'shopping_sessions',
        <String, Object?>{'status': 'cancelled', 'completed_at': now},
        where: 'status = ?',
        whereArgs: <Object>['active'],
      );
      final createdSessionId = await tx.insert(
        'shopping_sessions',
        <String, Object?>{
          'store_id': null,
          'started_at': now,
          'completed_at': null,
          'status': 'active',
        },
      );
      for (final item in items) {
        await tx.insert('shopping_items', <String, Object?>{
          'session_id': createdSessionId,
          'item_name': await _codec.encrypt(item),
          'target_qty': 1,
          'picked_qty': 0,
          'status': 'pending',
          'shelf_hint': null,
          'updated_at': now,
        });
      }
      return createdSessionId;
    });
    final db = await _database.database;
    return _loadSession(db, sessionId);
  }

  Future<ShoppingSessionSnapshot?> markPicked(String itemName) async {
    final db = await _database.database;
    final session = await currentSession();
    if (session == null) return null;
    final normalized = itemName.trim().toLowerCase();
    final rows = await db.query(
      'shopping_items',
      where: 'session_id = ?',
      whereArgs: [session.sessionId],
      orderBy: 'updated_at DESC',
    );
    for (final row in rows) {
      final currentName = (await _codec.decrypt(
        (row['item_name'] as String? ?? '').trim(),
      )).toLowerCase();
      if (currentName.isEmpty) continue;
      if (currentName == normalized ||
          currentName.contains(normalized) ||
          normalized.contains(currentName)) {
        final targetQty = ((row['target_qty'] as int?) ?? 1).clamp(1, 99);
        await db.update(
          'shopping_items',
          <String, Object?>{
            'picked_qty': targetQty,
            'status': 'picked',
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        break;
      }
    }
    final updated = await _loadSession(db, session.sessionId);
    if (updated.pendingItems.isEmpty) {
      await db.update(
        'shopping_sessions',
        <String, Object?>{
          'status': 'completed',
          'completed_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [session.sessionId],
      );
    }
    return _loadSession(db, session.sessionId);
  }

  Future<void> clearSession() async {
    final db = await _database.database;
    await db.update(
      'shopping_sessions',
      <String, Object?>{
        'status': 'cancelled',
        'completed_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'status = ?',
      whereArgs: ['active'],
    );
  }

  Future<ShoppingSessionSnapshot> _loadSession(
    Database db,
    int sessionId,
  ) async {
    final rows = await db.query(
      'shopping_items',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'updated_at ASC',
    );
    final items = <ShoppingItemState>[];
    for (final row in rows) {
      final name = await _codec.decrypt(
        (row['item_name'] as String? ?? '').trim(),
      );
      if (name.isEmpty) continue;
      items.add(
        ShoppingItemState(
          name: name,
          targetQty: ((row['target_qty'] as int?) ?? 1).clamp(1, 99),
          pickedQty: ((row['picked_qty'] as int?) ?? 0).clamp(0, 99),
          status: (row['status'] as String? ?? 'pending').trim(),
          shelfHint: (row['shelf_hint'] as String?)?.trim(),
        ),
      );
    }
    return ShoppingSessionSnapshot(sessionId: sessionId, items: items);
  }

  List<String> _parseItems(String userText) {
    var cleaned = userText
        .replaceAll(
          RegExp(
            r'\b(список|купить|нужно|надо|shopping|шопинг)\b',
            caseSensitive: false,
            unicode: true,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'\b(ал|әне|и|and)\b', caseSensitive: false, unicode: true),
          ',',
        )
        .replaceAll(';', ',')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return const <String>[];
    return cleaned
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .take(12)
        .toSet()
        .toList(growable: false);
  }
}
