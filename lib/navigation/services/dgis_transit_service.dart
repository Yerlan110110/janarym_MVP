import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../../l10n/app_locale_controller.dart';
import '../models/navigation_mode_state.dart';

class TransitServiceUnavailable implements Exception {
  const TransitServiceUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class NavigationTransitService {
  void setLanguage(AppLanguage language) {}

  Future<List<TransitStopCandidate>> searchStops({
    required String query,
    required NavPoint nearLocation,
    int limit = 3,
  });

  Future<List<TransitRouteSummary>> getStopRoutes({
    required TransitStopCandidate stop,
    NavPoint? nearLocation,
  });

  Future<List<TransitScheduleEntry>> getScheduledArrivals({
    required TransitStopCandidate stop,
    required String routeName,
    NavPoint? nearLocation,
  });

  void dispose() {}
}

class DgisTransitService implements NavigationTransitService {
  DgisTransitService({
    http.Client? httpClient,
    AppLanguage language = AppLanguage.ru,
  }) : _httpClient = httpClient ?? http.Client(),
       _language = language;

  final http.Client _httpClient;
  AppLanguage _language;

  static const String _placesHost = 'catalog.api.2gis.com';
  static const String _publicTransportHost = 'routing.api.2gis.com';
  static const NavPoint _astanaCenter = NavPoint(
    latitude: 51.1284,
    longitude: 71.4304,
  );
  static const List<String> _transitTypes = <String>[
    'pedestrian',
    'bus',
    'trolleybus',
    'tram',
    'shuttle_bus',
  ];

  @override
  void setLanguage(AppLanguage language) {
    _language = language;
  }

  @override
  Future<List<TransitStopCandidate>> searchStops({
    required String query,
    required NavPoint nearLocation,
    int limit = 3,
  }) async {
    final apiKey = _apiKey;
    if (apiKey.isEmpty) {
      final cleanQuery = _normalizeStopQuery(query);
      final label = cleanQuery.isEmpty ? 'Хан Шатыр' : cleanQuery;
      final mockPoint = _mockStopPoint(cleanQuery);
      return [
        TransitStopCandidate(
          id: 'mock_stop_$label',
          stationId: 'mock_st_$label',
          platformIds: const [],
          title: label,
          subtitle: 'Астана, Казахстан',
          point: mockPoint,
          routes: const [
            TransitRouteSummary(
              routeId: 'mock_10',
              displayName: '10',
              transportType: 'bus',
              directionLabels: ['Вокзал Нурлы Жол'],
            ),
            TransitRouteSummary(
              routeId: 'mock_12',
              displayName: '12',
              transportType: 'bus',
              directionLabels: ['Аэропорт'],
            ),
            TransitRouteSummary(
              routeId: 'mock_40',
              displayName: '40',
              transportType: 'bus',
              directionLabels: ['Пирамида'],
            ),
          ],
        )
      ];
    }

    final cleanQuery = _normalizeStopQuery(query);
    if (cleanQuery.isEmpty) return const [];

    final uri = Uri.https(_placesHost, '/3.0/items', <String, String>{
      'key': apiKey,
      'q': cleanQuery,
      'type': 'station,station_platform',
      'fields':
          'items.point,items.full_address_name,items.routes,items.directions,'
          'items.station_id,items.platforms',
      'locale': _placesLocale,
      'location': '${nearLocation.longitude},${nearLocation.latitude}',
      'point': '${nearLocation.longitude},${nearLocation.latitude}',
      'radius': '40000',
      'search_nearby': 'true',
      'search_is_query_text_complete': 'true',
      'sort': 'relevance',
    });

    final response = await _httpClient
        .get(uri)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransitServiceUnavailable(
        '2GIS places request failed with ${response.statusCode}',
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final items = _readItems(payload);
    final seen = <String>{};
    final candidates = <TransitStopCandidate>[];

    for (final rawItem in items) {
      final item = rawItem as Map<String, dynamic>;
      final stop = _parseStop(item);
      if (stop == null) continue;
      if (!seen.add(stop.id)) continue;
      candidates.add(stop);
      if (candidates.length >= limit) {
        break;
      }
    }

    return candidates;
  }

  @override
  Future<List<TransitRouteSummary>> getStopRoutes({
    required TransitStopCandidate stop,
    NavPoint? nearLocation,
  }) async {
    if (stop.routes.isNotEmpty) {
      return _sortRoutes(stop.routes);
    }

    final refreshed = await searchStops(
      query: stop.title,
      nearLocation: nearLocation ?? stop.point,
      limit: 6,
    );
    final exact = refreshed
        .where((candidate) => candidate.id == stop.id)
        .toList();
    if (exact.isNotEmpty && exact.first.routes.isNotEmpty) {
      return _sortRoutes(exact.first.routes);
    }

    return const [];
  }

  @override
  Future<List<TransitScheduleEntry>> getScheduledArrivals({
    required TransitStopCandidate stop,
    required String routeName,
    NavPoint? nearLocation,
  }) async {
    final apiKey = _apiKey;
    if (apiKey.isEmpty) {
      final now = DateTime.now();
      final t1 = now.add(const Duration(minutes: 4));
      final t2 = now.add(const Duration(minutes: 14));
      final t3 = now.add(const Duration(minutes: 27));
      String formatTime(DateTime t) {
        return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      }
      return [
        TransitScheduleEntry(
          routeName: routeName,
          destinationLabel: 'Орталық',
          exactTimes: [formatTime(t1), formatTime(t2), formatTime(t3)],
          intervalMinutes: null,
          sourceType: TransitScheduleSourceType.precise,
        )
      ];
    }

    final normalizedRoute = _normalizeRouteName(routeName);
    if (normalizedRoute.isEmpty) return const [];

    final entries = <TransitScheduleEntry>[];
    final seen = <String>{};
    for (final target in _scheduleProbeTargets(stop.point, nearLocation)) {
      if (_samePoint(stop.point, target)) continue;
      final options = await _requestPublicTransportOptions(
        apiKey: apiKey,
        source: stop.point,
        target: target,
      );
      for (final option in options) {
        final routeNames = _extractRouteNames(option);
        if (!routeNames.any(
          (name) => _normalizeRouteName(name) == normalizedRoute,
        )) {
          continue;
        }
        final scheduleItems = option['schedules'];
        if (scheduleItems is! List) continue;
        final destinationLabel = _directionLabelForRoute(stop, normalizedRoute);
        final parsed = _parseScheduleEntries(
          scheduleItems,
          routeName: routeName,
          destinationLabel: destinationLabel,
        );
        for (final entry in parsed) {
          final key = _scheduleEntryKey(entry);
          if (seen.add(key)) {
            entries.add(entry);
          }
        }
      }
      if (entries.isNotEmpty) {
        break;
      }
    }

    entries.sort(_compareScheduleEntries);
    return entries;
  }

  @override
  void dispose() {
    _httpClient.close();
  }

  String get _apiKey {
    const keys = <String>['DGIS_API_KEY', 'TWO_GIS_API_KEY', 'TWOGIS_API_KEY'];
    for (final key in keys) {
      final value = (dotenv.maybeGet(key) ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String get _placesLocale => _language == AppLanguage.kk ? 'kk_KZ' : 'ru_KZ';

  String get _publicTransportLocale =>
      _language == AppLanguage.kk ? 'kk' : 'ru';

  Future<List<Map<String, dynamic>>> _requestPublicTransportOptions({
    required String apiKey,
    required NavPoint source,
    required NavPoint target,
  }) async {
    final uri = Uri.https(
      _publicTransportHost,
      '/public_transport/2.0',
      <String, String>{'key': apiKey},
    );
    final body = jsonEncode(<String, dynamic>{
      'enable_schedule': true,
      'source': <String, dynamic>{
        'point': <String, double>{
          'lat': source.latitude,
          'lon': source.longitude,
        },
      },
      'target': <String, dynamic>{
        'point': <String, double>{
          'lat': target.latitude,
          'lon': target.longitude,
        },
      },
      'transport': _transitTypes,
      'max_result_count': 12,
      'locale': _publicTransportLocale,
    });
    final response = await _httpClient
        .post(
          uri,
          headers: const <String, String>{'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 204) {
      return const [];
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransitServiceUnavailable(
        '2GIS public transport request failed with ${response.statusCode}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  List<dynamic> _readItems(Map<String, dynamic> payload) {
    final result = payload['result'];
    if (result is Map<String, dynamic>) {
      final items = result['items'];
      if (items is List) return items;
    }
    final items = payload['items'];
    if (items is List) return items;
    return const [];
  }

  TransitStopCandidate? _parseStop(Map<String, dynamic> item) {
    final id = '${item['id'] ?? ''}'.trim();
    if (id.isEmpty) return null;
    final point =
        _parsePoint(item['point']) ??
        _parsePoint(
          item['geometry'] is Map<String, dynamic>
              ? (item['geometry'] as Map<String, dynamic>)['centroid']
              : null,
        );
    if (point == null) return null;

    final title = _readFirstString(item, <String>[
      'name',
      'full_name',
      'title',
      'segment_name',
    ]);
    final subtitle = _readFirstString(item, <String>[
      'full_address_name',
      'address_name',
      'address',
    ]);
    final stationId = _stringOrNull(item['station_id']);
    final platformIds = _parsePlatformIds(item, selfId: id);
    final routes = _parseRoutes(item);
    return TransitStopCandidate(
      id: id,
      stationId: stationId,
      platformIds: platformIds,
      title: title.isEmpty ? subtitle : title,
      subtitle: subtitle,
      point: point,
      routes: routes,
    );
  }

  NavPoint? _parsePoint(Object? raw) {
    if (raw is Map<String, dynamic>) {
      final lat =
          (raw['lat'] as num?)?.toDouble() ??
          (raw['latitude'] as num?)?.toDouble();
      final lon =
          (raw['lon'] as num?)?.toDouble() ??
          (raw['lng'] as num?)?.toDouble() ??
          (raw['longitude'] as num?)?.toDouble();
      if (lat != null && lon != null) {
        return NavPoint(latitude: lat, longitude: lon);
      }
    }
    return null;
  }

  List<String> _parsePlatformIds(
    Map<String, dynamic> item, {
    required String selfId,
  }) {
    final result = <String>{};
    final type = '${item['type'] ?? ''}'.toLowerCase();
    if (type == 'station_platform') {
      result.add(selfId);
    }
    final platforms = item['platforms'];
    if (platforms is List) {
      for (final rawPlatform in platforms) {
        if (rawPlatform is! Map) continue;
        final id = _stringOrNull(rawPlatform['id']);
        if (id != null) {
          result.add(id);
        }
      }
    }
    return result.toList(growable: false);
  }

  List<TransitRouteSummary> _parseRoutes(Map<String, dynamic> item) {
    final routeDirections = _parseDirectionLabels(item['directions']);
    final rawRoutes = item['routes'];
    if (rawRoutes is! List) return const [];

    final result = <TransitRouteSummary>[];
    final seen = <String>{};
    for (final rawRoute in rawRoutes) {
      if (rawRoute is! Map) continue;
      final route = Map<String, dynamic>.from(rawRoute);
      final displayName = _readFirstString(route, <String>[
        'name',
        'route_name',
        'short_name',
        'number',
        'title',
      ]);
      if (displayName.isEmpty) continue;
      final routeId = _readFirstString(route, <String>[
        'id',
        'route_id',
        'segment_id',
      ]);
      final transportType = _readFirstString(route, <String>[
        'subtype_name',
        'subtype',
        'transport_type',
        'type',
      ]);
      final directions = _parseDirectionLabels(route['directions']);
      final summary = TransitRouteSummary(
        routeId: routeId.isEmpty ? displayName : routeId,
        displayName: displayName,
        transportType: transportType,
        directionLabels: directions.isEmpty ? routeDirections : directions,
      );
      final key = '${summary.routeId}|${summary.displayName}';
      if (seen.add(key)) {
        result.add(summary);
      }
    }
    return _sortRoutes(result);
  }

  List<String> _parseDirectionLabels(Object? raw) {
    if (raw is! List) return const [];
    final labels = <String>{};
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        labels.add(item.trim());
        continue;
      }
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      for (final key in <String>[
        'name',
        'title',
        'text',
        'direction',
        'value',
      ]) {
        final value = _stringOrNull(map[key]);
        if (value != null) {
          labels.add(value);
          break;
        }
      }
    }
    return labels.toList(growable: false);
  }

  String _readFirstString(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = _stringOrNull(source[key]);
      if (value != null) return value;
    }
    return '';
  }

  String? _stringOrNull(Object? value) {
    final text = '${value ?? ''}'.trim();
    if (text.isEmpty || text == 'null') return null;
    return text;
  }

  List<TransitScheduleEntry> _parseScheduleEntries(
    List<dynamic> rawSchedules, {
    required String routeName,
    required String destinationLabel,
  }) {
    final exactTimes = <String>[];
    int? smallestIntervalMinutes;

    for (final rawSchedule in rawSchedules) {
      if (rawSchedule is! Map) continue;
      final schedule = Map<String, dynamic>.from(rawSchedule);
      final type = _stringOrNull(schedule['type']) ?? '';
      final preciseTime = _stringOrNull(schedule['precise_time']);
      final period = (schedule['period'] as num?)?.toInt();
      if (type == 'precise' && preciseTime != null) {
        exactTimes.add(preciseTime);
        continue;
      }
      if (type == 'periodic' &&
          period != null &&
          period > 0 &&
          period < 0xFFFFFFFF) {
        if (smallestIntervalMinutes == null ||
            period < smallestIntervalMinutes) {
          smallestIntervalMinutes = period;
        }
      }
    }

    if (exactTimes.isNotEmpty) {
      return <TransitScheduleEntry>[
        TransitScheduleEntry(
          routeName: routeName,
          destinationLabel: destinationLabel,
          exactTimes: exactTimes.toSet().toList(growable: false)..sort(),
          intervalMinutes: null,
          sourceType: TransitScheduleSourceType.precise,
        ),
      ];
    }
    if (smallestIntervalMinutes != null) {
      return <TransitScheduleEntry>[
        TransitScheduleEntry(
          routeName: routeName,
          destinationLabel: destinationLabel,
          exactTimes: const [],
          intervalMinutes: smallestIntervalMinutes,
          sourceType: TransitScheduleSourceType.periodic,
        ),
      ];
    }
    return const [];
  }

  List<String> _extractRouteNames(Map<String, dynamic> option) {
    final result = <String>{};
    final waypoints = option['waypoints'];
    if (waypoints is List) {
      for (final rawWaypoint in waypoints) {
        if (rawWaypoint is! Map) continue;
        final waypoint = Map<String, dynamic>.from(rawWaypoint);
        final routeNames = waypoint['routes_names'];
        if (routeNames is! List) continue;
        for (final rawName in routeNames) {
          final name = _stringOrNull(rawName);
          if (name != null) {
            result.add(name);
          }
        }
      }
    }
    return result.toList(growable: false);
  }

  String _directionLabelForRoute(
    TransitStopCandidate stop,
    String normalizedRoute,
  ) {
    for (final route in stop.routes) {
      if (_normalizeRouteName(route.displayName) != normalizedRoute) continue;
      if (route.directionLabels.isNotEmpty) {
        return route.directionLabels.first;
      }
    }
    return '';
  }

  List<TransitRouteSummary> _sortRoutes(List<TransitRouteSummary> routes) {
    final copy = List<TransitRouteSummary>.from(routes);
    copy.sort((a, b) {
      final aNum = int.tryParse(
        RegExp(r'^\d+').stringMatch(a.displayName) ?? '',
      );
      final bNum = int.tryParse(
        RegExp(r'^\d+').stringMatch(b.displayName) ?? '',
      );
      if (aNum != null && bNum != null && aNum != bNum) {
        return aNum.compareTo(bNum);
      }
      return a.displayName.compareTo(b.displayName);
    });
    return copy;
  }

  String _normalizeStopQuery(String query) {
    return query
        .replaceFirst(
          RegExp(
            r'^(остановк[аи]?|аялдама(ға|га)?|аялдамасына)\s+',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeRouteName(String routeName) {
    return routeName.replaceAll(RegExp(r'[\s-]+'), '').toUpperCase();
  }

  /// Returns a real Astana bus-stop coordinate for the mock service.
  /// Matches by keyword so different stop names land on different points.
  NavPoint _mockStopPoint(String query) {
    final q = query.toLowerCase();
    // Well-known Astana stops with verified coordinates inside city bounds
    const stops = <(String, double, double)>[
      ('хан шатыр', 51.1305, 71.4053),     // Khan Shatyr mall stop
      ('байтерек', 51.1285, 71.4306),       // Baiterek tower stop
      ('думан', 51.1432, 71.4572),          // Duman entertainment centre
      ('абай', 51.1799, 71.4465),           // Abai ave stop
      ('нурлы жол', 51.1068, 71.3910),      // Nurly Zhol railway station
      ('пирамида', 51.1279, 71.4226),       // Palace of Peace stop
      ('аэропорт', 51.0220, 71.4670),       // Astana airport (edge but inside)
      ('достык', 51.1611, 71.4697),         // Dostyk plaza
      ('мега', 51.1940, 71.4330),           // Mega mall
    ];
    for (final (keyword, lat, lon) in stops) {
      if (q.contains(keyword)) {
        return NavPoint(latitude: lat, longitude: lon);
      }
    }
    // Default: central Astana (near Baiterek) — always inside bounds
    return const NavPoint(latitude: 51.1285, longitude: 71.4306);
  }

  List<NavPoint> _scheduleProbeTargets(NavPoint stop, NavPoint? nearLocation) {
    final result = <NavPoint>[];
    void add(NavPoint point) {
      if (!result.any((existing) => _samePoint(existing, point))) {
        result.add(point);
      }
    }

    final base = nearLocation ?? _astanaCenter;
    add(base);
    add(NavPoint(latitude: stop.latitude + 0.02, longitude: stop.longitude));
    add(NavPoint(latitude: stop.latitude - 0.02, longitude: stop.longitude));
    add(NavPoint(latitude: stop.latitude, longitude: stop.longitude + 0.02));
    add(NavPoint(latitude: stop.latitude, longitude: stop.longitude - 0.02));
    return result;
  }

  bool _samePoint(NavPoint a, NavPoint b) {
    return (a.latitude - b.latitude).abs() < 0.000001 &&
        (a.longitude - b.longitude).abs() < 0.000001;
  }

  String _scheduleEntryKey(TransitScheduleEntry entry) {
    final times = entry.exactTimes.join(',');
    final interval = entry.intervalMinutes?.toString() ?? '';
    return [
      _normalizeRouteName(entry.routeName),
      entry.destinationLabel,
      entry.sourceType.name,
      times,
      interval,
    ].join('|');
  }

  int _compareScheduleEntries(TransitScheduleEntry a, TransitScheduleEntry b) {
    if (a.sourceType != b.sourceType) {
      return a.sourceType == TransitScheduleSourceType.precise ? -1 : 1;
    }
    if (a.sourceType == TransitScheduleSourceType.precise) {
      final aFirst = a.exactTimes.isEmpty ? '99:99' : a.exactTimes.first;
      final bFirst = b.exactTimes.isEmpty ? '99:99' : b.exactTimes.first;
      return aFirst.compareTo(bFirst);
    }
    return (a.intervalMinutes ?? 1 << 30).compareTo(
      b.intervalMinutes ?? 1 << 30,
    );
  }
}
