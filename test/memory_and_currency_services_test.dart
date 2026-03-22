import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/anti_fraud/currency_check_analyzer.dart';
import 'package:janarym_app2/anti_fraud/currency_check_audit_service.dart';
import 'package:janarym_app2/personalization/data/personalization_database.dart';
import 'package:janarym_app2/personalization/data/secure_payload_codec.dart';
import 'package:janarym_app2/services/scene_memory_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _InMemorySecureStoragePlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async {
    return _data.containsKey(key);
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    _data.remove(key);
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _data.clear();
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    return _data[key];
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    return Map<String, String>.from(_data);
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    _data[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FlutterSecureStoragePlatform originalStoragePlatform;

  setUp(() {
    originalStoragePlatform = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = _InMemorySecureStoragePlatform();
  });

  tearDown(() {
    FlutterSecureStoragePlatform.instance = originalStoragePlatform;
  });

  group('SceneMemoryService', () {
    test('stores text notes in memory_notes and survives reopen', () async {
      final dbName = 'test_memory_${DateTime.now().microsecondsSinceEpoch}.db';
      final codec = SecurePayloadCodec();

      var database = PersonalizationDatabase(
        dbFactory: databaseFactoryFfi,
        databaseName: dbName,
      );
      var service = SceneMemoryService(database: database, codec: codec);

      await service.saveAnchor(
        anchorName: 'код домофона',
        summary: '2450',
        kind: 'code',
      );

      final firstRead = await service.findBestAnchor('домофон');
      expect(firstRead, isNotNull);
      expect(firstRead!.summary, '2450');
      expect(firstRead.kind, 'code');

      final db = await database.database;
      final rows = await db.query('memory_notes');
      expect(rows, hasLength(1));

      await database.close();

      database = PersonalizationDatabase(
        dbFactory: databaseFactoryFfi,
        databaseName: dbName,
      );
      service = SceneMemoryService(database: database, codec: codec);

      final reopened = await service.findBestAnchor('код домофона');
      expect(reopened, isNotNull);
      expect(reopened!.summary, '2450');

      final recent = await service.recentAnchors();
      expect(recent.map((item) => item.name), contains('код домофона'));

      await database.close();
    });
  });

  group('CurrencyCheckAuditService', () {
    test('writes encrypted audit trail into currency_checks', () async {
      final dbName =
          'test_currency_${DateTime.now().microsecondsSinceEpoch}.db';
      final database = PersonalizationDatabase(
        dbFactory: databaseFactoryFfi,
        databaseName: dbName,
      );
      final codec = SecurePayloadCodec();
      final service = CurrencyCheckAuditService(
        database: database,
        codec: codec,
      );

      await service.record(
        result: const CurrencyCheckResult(
          verdict: CurrencyCheckVerdict.counterfeit,
          reasons: <String>['сувенир'],
          nominal: '5000',
          source: 'ocr',
        ),
        rawSourceText: 'НЕ ЯВЛЯЕТСЯ ПЛАТЕЖНЫМ СРЕДСТВОМ',
      );

      final db = await database.database;
      final rows = await db.query('currency_checks');
      expect(rows, hasLength(1));
      final notes = await codec.decrypt((rows.first['notes'] as String?) ?? '');
      expect(notes, contains('verdict=counterfeit'));
      expect(notes, contains('nominal=5000'));

      await database.close();
    });
  });
}
