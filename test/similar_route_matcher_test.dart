import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/personalization/models/personalization_models.dart';
import 'package:janarym_app2/personalization/similar_route_matcher.dart';

void main() {
  group('SimilarRouteMatcher', () {
    const matcher = SimilarRouteMatcher();

    test('returns best similar route for close query', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = [
        RouteHistoryEntry(
          queryText: 'абая 10 астана',
          queryNorm: 'абая 10 астана',
          resolvedAddress: 'Астана, Абая 10',
          destLat: 51.12,
          destLon: 71.42,
          source: 'manual',
          startedAtEpochMs: now,
        ),
        RouteHistoryEntry(
          queryText: 'қабанбай батыр 60',
          queryNorm: 'қабанбай батыр 60',
          resolvedAddress: 'Астана, Қабанбай батыр 60',
          destLat: 51.13,
          destLon: 71.43,
          source: 'manual',
          startedAtEpochMs: now - 1000,
        ),
      ];

      final result = matcher.findBest(
        queryNorm: 'маршрут абая 10 астана',
        candidates: entries,
      );

      expect(result, isNotNull);
      expect(result!.entry.resolvedAddress, contains('Абая'));
      expect(result.score, greaterThan(0.56));
    });

    test('returns null when confidence is too low', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final entries = [
        RouteHistoryEntry(
          queryText: 'достык 1',
          queryNorm: 'достык 1',
          resolvedAddress: 'Астана, Достык 1',
          destLat: 51.11,
          destLon: 71.41,
          source: 'manual',
          startedAtEpochMs: now,
        ),
      ];

      final result = matcher.findBest(
        queryNorm: 'кабанбай 60',
        candidates: entries,
      );

      expect(result, isNull);
    });
  });
}
