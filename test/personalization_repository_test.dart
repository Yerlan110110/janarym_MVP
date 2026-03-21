import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/personalization/data/personalization_database.dart';
import 'package:janarym_app2/personalization/models/personalization_models.dart';
import 'package:janarym_app2/personalization/personalization_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('PersonalizationRepository', () {
    late PersonalizationDatabase db;
    late PersonalizationRepository repository;

    setUp(() {
      final dbName =
          'test_personalization_${DateTime.now().microsecondsSinceEpoch}.db';
      db = PersonalizationDatabase(
        dbFactory: databaseFactoryFfi,
        databaseName: dbName,
      );
      repository = PersonalizationRepository(database: db);
    });

    tearDown(() async {
      await repository.close();
    });

    test('upsert/get profile', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final profile = UserProfile(
        displayName: 'Yerlan',
        responseLength: ResponseLength.short,
        toneStyle: ToneStyle.direct,
        warningIntensity: 3,
        onboardingCompleted: false,
        onboardingStep: 4,
        onboardingDeferredUntilEpochMs:
            now + const Duration(hours: 1).inMilliseconds,
        createdAtEpochMs: now,
        updatedAtEpochMs: now,
      );

      await repository.upsertProfile(profile);
      final loaded = await repository.getProfile();

      expect(loaded, isNotNull);
      expect(loaded!.displayName, 'Yerlan');
      expect(loaded.responseLength, ResponseLength.short);
      expect(loaded.toneStyle, ToneStyle.direct);
      expect(loaded.warningIntensity, 3);
      expect(
        loaded.onboardingDeferredUntilEpochMs,
        now + const Duration(hours: 1).inMilliseconds,
      );
    });

    test('stores fears and labels', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await repository.upsertFear(
        UserFear(
          fearKey: 'перекрестки',
          customText: 'перекрестки',
          source: 'voice',
          updatedAtEpochMs: now,
        ),
      );
      final fears = await repository.getFears();
      expect(fears, isNotEmpty);
      expect(fears.first.displayText, contains('перекрест'));

      await repository.upsertPlaceLabel(
        PlaceLabel(
          labelName: 'Дом',
          labelNameNorm: 'дом',
          addressText: 'Астана, Абая 10',
          lat: 51.12,
          lon: 71.42,
          createdAtEpochMs: now,
          updatedAtEpochMs: now,
        ),
      );
      final byName = await repository.findPlaceLabelByName('дом');
      expect(byName, isNotNull);
      expect(byName!.addressText, contains('Абая'));

      final byInflected = await repository.findPlaceLabelByName('дома');
      expect(byInflected, isNotNull);
      expect(byInflected!.addressText, contains('Абая'));

      final byNoisyInput = await repository.findPlaceLabelByName('да дома');
      expect(byNoisyInput, isNotNull);
      expect(byNoisyInput!.addressText, contains('Абая'));

      final byAdverb = await repository.findPlaceLabelByName('домой');
      expect(byAdverb, isNotNull);
      expect(byAdverb!.addressText, contains('Абая'));
    });

    test('finds similar route from history', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await repository.recordRouteUsage(
        RouteHistoryEntry(
          queryText: 'абая 10 астана',
          queryNorm: 'абая 10 астана',
          resolvedAddress: 'Астана, Абая 10',
          destLat: 51.12,
          destLon: 71.42,
          source: 'manual',
          startedAtEpochMs: now,
        ),
      );
      await repository.recordRouteUsage(
        RouteHistoryEntry(
          queryText: 'кабанбай батыр 60',
          queryNorm: 'кабанбай батыр 60',
          resolvedAddress: 'Астана, Кабанбай батыр 60',
          destLat: 51.13,
          destLon: 71.43,
          source: 'manual',
          startedAtEpochMs: now - 2000,
        ),
      );

      final result = await repository.findBestSimilarRoute('маршрут абая 10');
      expect(result, isNotNull);
      expect(result!.resolvedAddress, contains('Абая'));
    });
  });
}
