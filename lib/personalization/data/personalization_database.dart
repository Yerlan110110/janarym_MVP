import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PersonalizationDatabase {
  PersonalizationDatabase({DatabaseFactory? dbFactory, String? databaseName})
    : _databaseFactory = dbFactory ?? databaseFactory,
      _databaseName = databaseName ?? _defaultDbName;

  static const int schemaVersion = 2;
  static const String _defaultDbName = 'janarym_personalization_v1.db';

  final DatabaseFactory _databaseFactory;
  final String _databaseName;
  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;

    final basePath = await _databaseFactory.getDatabasesPath();
    final fullPath = p.join(basePath, _databaseName);
    final opened = await _databaseFactory.openDatabase(
      fullPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    _db = opened;
    return opened;
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createSchemaV1(db);
    if (version >= 2) {
      await _migrateToV2(db);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      await _createSchemaV1(db);
    }
    if (oldVersion < 2) {
      await _migrateToV2(db);
    }
  }

  Future<void> _createSchemaV1(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_profile (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        display_name TEXT,
        response_length TEXT NOT NULL,
        tone_style TEXT NOT NULL,
        warning_intensity INTEGER NOT NULL DEFAULT 2,
        onboarding_completed INTEGER NOT NULL DEFAULT 0,
        onboarding_step INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS questionnaire_answers (
        question_id INTEGER PRIMARY KEY,
        question_key TEXT NOT NULL,
        raw_answer TEXT NOT NULL,
        normalized_value TEXT,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_fears (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fear_key TEXT,
        custom_text TEXT,
        severity INTEGER NOT NULL DEFAULT 2,
        source TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS place_labels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label_name TEXT NOT NULL,
        label_name_norm TEXT NOT NULL UNIQUE,
        address_text TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS route_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        query_text TEXT NOT NULL,
        query_norm TEXT NOT NULL,
        resolved_address TEXT NOT NULL,
        dest_lat REAL NOT NULL,
        dest_lon REAL NOT NULL,
        source TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        completed INTEGER NOT NULL DEFAULT 1
      );
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_route_history_query_norm '
      'ON route_history(query_norm);',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_route_history_started_at '
      'ON route_history(started_at DESC);',
    );
  }

  Future<void> _migrateToV2(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scene_objects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_key TEXT NOT NULL,
        object_label TEXT NOT NULL,
        anchor_hint TEXT,
        x REAL,
        y REAL,
        z REAL,
        confidence REAL NOT NULL DEFAULT 0,
        last_seen_at INTEGER NOT NULL
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scene_objects_room ON scene_objects(room_key);',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scene_objects_label ON scene_objects(object_label);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS danger_zones (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        room_key TEXT NOT NULL,
        hazard_type TEXT NOT NULL,
        severity TEXT NOT NULL,
        anchor_hint TEXT,
        x REAL,
        y REAL,
        trigger_count INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_danger_zones_room ON danger_zones(room_key);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS stores (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        store_name TEXT NOT NULL,
        store_name_norm TEXT NOT NULL UNIQUE,
        lat REAL,
        lon REAL,
        preferred INTEGER NOT NULL DEFAULT 0,
        visit_count INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_stores_preferred ON stores(preferred);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS store_layout (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        store_id INTEGER NOT NULL,
        zone_type TEXT NOT NULL,
        anchor_object TEXT,
        x REAL,
        y REAL,
        confidence REAL NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(store_id) REFERENCES stores(id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_store_layout_store ON store_layout(store_id);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS shopping_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        store_id INTEGER,
        started_at INTEGER NOT NULL,
        completed_at INTEGER,
        status TEXT NOT NULL,
        FOREIGN KEY(store_id) REFERENCES stores(id) ON DELETE SET NULL
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shopping_sessions_status ON shopping_sessions(status);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS shopping_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        item_name TEXT NOT NULL,
        target_qty INTEGER NOT NULL DEFAULT 1,
        picked_qty INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        shelf_hint TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES shopping_sessions(id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shopping_items_session ON shopping_items(session_id);',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_shopping_items_status ON shopping_items(status);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS product_catalog_local (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        canonical_name TEXT NOT NULL,
        canonical_norm TEXT NOT NULL UNIQUE,
        aliases TEXT,
        last_seen_price REAL,
        updated_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS cooking_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recipe_name TEXT,
        started_at INTEGER NOT NULL,
        completed_at INTEGER,
        status TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS cooking_steps_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        step_index INTEGER NOT NULL,
        instruction TEXT NOT NULL,
        hand_offset_cm REAL,
        safety_notes TEXT,
        confirmed INTEGER NOT NULL DEFAULT 0,
        logged_at INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES cooking_sessions(id) ON DELETE CASCADE
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cooking_steps_session ON cooking_steps_log(session_id);',
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS currency_checks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        expected_total REAL,
        detected_total REAL,
        discrepancy REAL,
        notes TEXT,
        created_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ocr_reads (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        read_kind TEXT NOT NULL,
        raw_text TEXT NOT NULL,
        price REAL,
        calories INTEGER,
        created_at INTEGER NOT NULL
      );
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ocr_reads_kind ON ocr_reads(read_kind);',
    );
  }

  Future<T> runInTransaction<T>(
    Future<T> Function(Transaction tx) action,
  ) async {
    final db = await database;
    return db.transaction(action);
  }

  Future<void> pruneOcrReads({int maxEntries = 100}) async {
    final db = await database;
    await db.rawDelete(
      '''
      DELETE FROM ocr_reads
      WHERE id NOT IN (
        SELECT id FROM ocr_reads
        ORDER BY created_at DESC, id DESC
        LIMIT ?
      )
      ''',
      <Object>[maxEntries],
    );
  }

  Future<void> pruneSceneObjects({int maxEntries = 150}) async {
    final db = await database;
    await db.rawDelete(
      '''
      DELETE FROM scene_objects
      WHERE id NOT IN (
        SELECT id FROM scene_objects
        ORDER BY last_seen_at DESC, id DESC
        LIMIT ?
      )
      ''',
      <Object>[maxEntries],
    );
  }

  Future<void> close() async {
    final existing = _db;
    _db = null;
    if (existing != null) {
      await existing.close();
    }
  }
}
