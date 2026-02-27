import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PersonalizationDatabase {
  PersonalizationDatabase({DatabaseFactory? dbFactory, String? databaseName})
    : _databaseFactory = dbFactory ?? databaseFactory,
      _databaseName = databaseName ?? _defaultDbName;

  static const int schemaVersion = 1;
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
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      await _createSchemaV1(db);
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

  Future<T> runInTransaction<T>(
    Future<T> Function(Transaction tx) action,
  ) async {
    final db = await database;
    return db.transaction(action);
  }

  Future<void> close() async {
    final existing = _db;
    _db = null;
    if (existing != null) {
      await existing.close();
    }
  }
}
