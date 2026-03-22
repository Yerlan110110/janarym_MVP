import 'dart:convert';
import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/navigation/models/transit_models.dart';
import 'package:janarym_app2/navigation/services/dgis_transit_service.dart';
import 'package:janarym_app2/navigation/services/navigation_utils.dart';

String _normalizeStopName(String value) {
  return value
      .replaceFirst(
        RegExp(r'^(остановка|аялдама)\s+', caseSensitive: false, unicode: true),
        '',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

List<TransitStopCandidate> _preferPlatformLevel(
  List<TransitStopCandidate> candidates,
) {
  final platformLevel = candidates
      .where((candidate) => candidate.isPlatformLevel)
      .toList(growable: false);
  return platformLevel.isNotEmpty ? platformLevel : candidates;
}

TransitStopCandidate? _chooseNearestStop(
  List<TransitStopCandidate> candidates,
  NavPoint origin,
  String query,
) {
  if (candidates.isEmpty) return null;
  final normalizedQuery = _normalizeStopName(query);
  final exact = candidates
      .where(
        (candidate) => _normalizeStopName(candidate.title) == normalizedQuery,
      )
      .toList(growable: false);
  final pool = _preferPlatformLevel(exact.isNotEmpty ? exact : candidates);
  pool.sort((a, b) {
    final distanceA = distanceMeters(origin, a.point);
    final distanceB = distanceMeters(origin, b.point);
    final byDistance = distanceA.compareTo(distanceB);
    if (byDistance != 0) return byDistance;
    return a.id.compareTo(b.id);
  });
  return pool.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const runLiveSmoke = bool.fromEnvironment('RUN_LIVE_SMOKE');

  test('2GIS live bus smoke for representative Astana stops', () async {
    final envFile = File('assets/runtime/env.runtime');
    expect(envFile.existsSync(), isTrue, reason: 'env.runtime is required');

    dotenv.clean();
    dotenv.loadFromString(envString: envFile.readAsStringSync());

    final service = DgisTransitService(
      language: AppLanguage.ru,
      nowProvider: () => DateTime.parse('2026-03-23T08:00:00+05:00'),
    );
    final cases = <Map<String, Object>>[
      <String, Object>{
        'stopQuery': 'ЖК Эксплаза',
        'location': const NavPoint(latitude: 51.0900, longitude: 71.4137),
      },
      <String, Object>{
        'stopQuery': 'Университет',
        'location': const NavPoint(latitude: 51.1284, longitude: 71.4304),
      },
      <String, Object>{
        'stopQuery': 'Хан Шатыр',
        'location': const NavPoint(latitude: 51.1328, longitude: 71.4037),
      },
      <String, Object>{
        'stopQuery': 'Дом министерств',
        'location': const NavPoint(latitude: 51.1259, longitude: 71.4308),
      },
      <String, Object>{
        'stopQuery': 'Керуен',
        'location': const NavPoint(latitude: 51.1286, longitude: 71.4272),
      },
    ];

    final results = <Map<String, Object?>>[];
    for (final item in cases) {
      final stopQuery = item['stopQuery'] as String;
      final location = item['location'] as NavPoint;
      try {
        final candidates = await service.searchStops(
          query: stopQuery,
          nearLocation: location,
          limit: 10,
        );
        final selected = _chooseNearestStop(candidates, location, stopQuery);
        if (selected == null) {
          results.add(<String, Object?>{
            'stop_query': stopQuery,
            'status': 'not_found',
            'candidate_count': candidates.length,
          });
          continue;
        }
        final routes = await service.getStopRoutes(
          stop: selected,
          nearLocation: location,
        );
        final primaryRoute = routes.isEmpty ? null : routes.first.displayName;
        final schedule = primaryRoute == null
            ? const <TransitScheduleEntry>[]
            : await service.getScheduledArrivals(
                stop: selected,
                routeName: primaryRoute,
                nearLocation: location,
              );
        results.add(<String, Object?>{
          'stop_query': stopQuery,
          'status': 'ok',
          'candidate_count': candidates.length,
          'selected_stop': selected.title,
          'selected_stop_id': selected.id,
          'platform_level': selected.isPlatformLevel,
          'routes_preview': routes
              .take(5)
              .map((route) => route.displayName)
              .toList(growable: false),
          'primary_route': primaryRoute,
          'schedule_source': schedule.isEmpty
              ? null
              : schedule.first.sourceType.name,
          'schedule_times': schedule.isEmpty
              ? const <String>[]
              : schedule.first.exactTimes,
          'schedule_interval': schedule.isEmpty
              ? null
              : schedule.first.intervalMinutes,
        });
      } catch (error) {
        results.add(<String, Object?>{
          'stop_query': stopQuery,
          'status': 'error',
          'error': error.toString(),
        });
      }
    }

    for (final result in results) {
      // ignore: avoid_print
      print(jsonEncode(result));
    }

    expect(results, hasLength(cases.length));
    final successful = results.where((item) => item['status'] == 'ok').length;
    expect(successful, greaterThanOrEqualTo(3));
    expect(
      results
          .where((item) => item['stop_query'] == 'ЖК Эксплаза')
          .first['status'],
      isNot('error'),
    );

    service.dispose();
  }, skip: !runLiveSmoke);
}
