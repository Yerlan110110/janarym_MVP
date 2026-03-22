import '../personalization/data/personalization_database.dart';
import '../personalization/data/secure_payload_codec.dart';
import 'currency_check_analyzer.dart';

class CurrencyCheckAuditService {
  CurrencyCheckAuditService({
    required PersonalizationDatabase database,
    required SecurePayloadCodec codec,
  }) : _database = database,
       _codec = codec;

  final PersonalizationDatabase _database;
  final SecurePayloadCodec _codec;

  Future<void> record({
    required CurrencyCheckResult result,
    String? rawSourceText,
  }) async {
    final db = await _database.database;
    final parts = <String>[
      'verdict=${result.verdict.name}',
      'source=${result.source}',
      if (result.nominal != null && result.nominal!.trim().isNotEmpty)
        'nominal=${result.nominal!.trim()}',
      if (result.reasons.isNotEmpty) 'reasons=${result.reasons.join('|')}',
      if (rawSourceText != null && rawSourceText.trim().isNotEmpty)
        'raw=${rawSourceText.trim()}',
    ];
    await db.insert('currency_checks', <String, Object?>{
      'expected_total': null,
      'detected_total': null,
      'discrepancy': null,
      'notes': await _codec.encrypt(parts.join('; ')),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
