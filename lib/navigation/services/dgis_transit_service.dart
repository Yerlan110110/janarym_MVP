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
    DateTime Function()? nowProvider,
  }) : _httpClient = httpClient ?? http.Client(),
       _language = language,
       _nowProvider = nowProvider ?? DateTime.now;

  final http.Client _httpClient;
  AppLanguage _language;
  final DateTime Function() _nowProvider;

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
      throw const TransitServiceUnavailable('2GIS API key is not configured');
    }

    final cleanQuery = _normalizeStopQuery(query);

    final Map<String, String> params = {
      'key': apiKey,
      'type': 'station,station_platform',
      'fields':
          'items.point,items.full_address_name,items.routes,items.directions,'
          'items.station_id,items.platforms',
      'locale': _placesLocale,
      'location': '${nearLocation.longitude},${nearLocation.latitude}',
      'radius': '35000',
      'sort': 'relevance',
    };

    if (cleanQuery.isNotEmpty) {
      params['q'] = cleanQuery;
      params['search_nearby'] = 'false';
    } else {
      params['point'] = '${nearLocation.longitude},${nearLocation.latitude}';
      params['search_nearby'] = 'true';
    }

    final uri = Uri.https(_placesHost, '/3.0/items', params);

    final response = await _httpClient
        .get(uri)
        .timeout(const Duration(seconds: 8));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      print(
        '[TRANSIT] Places API error: ${response.statusCode} Body: ${response.body}',
      );
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
      throw const TransitServiceUnavailable('2GIS API key is not configured');
    }

    final normalizedRoute = _normalizeRouteName(routeName);
    if (normalizedRoute.isEmpty) return const [];

    final requestedAt = _nowProvider();
    final entries = <TransitScheduleEntry>[];
    final seen = <String>{};
    for (final target in _scheduleProbeTargets(stop.point, nearLocation)) {
      if (_samePoint(stop.point, target)) continue;
      final options = await _requestPublicTransportOptions(
        apiKey: apiKey,
        source: stop.point,
        target: target,
        startTime: requestedAt,
      );
      for (final option in options) {
        final routeNames = _extractBoardingRouteNames(option);
        final isMatch = routeNames.any((name) {
          final d = _normalizeRouteName(name);
          if (d == normalizedRoute) return true;

          final searchDigits = routeName.replaceAll(RegExp(r'[^0-9]'), '');
          final dataDigits = name.replaceAll(RegExp(r'[^0-9]'), '');
          if (searchDigits.isNotEmpty && searchDigits == dataDigits)
            return true;

          return d.contains(normalizedRoute) || normalizedRoute.contains(d);
        });

        if (!isMatch) continue;
        final scheduleItems = option['schedules'];
        if (scheduleItems is! List) continue;
        final destinationLabel = _directionLabelForRoute(stop, normalizedRoute);
        final parsed = _parseScheduleEntries(
          scheduleItems,
          rawScheduleEvents: option['schedules_events'],
          routeName: routeName,
          destinationLabel: destinationLabel,
          requestedAt: requestedAt,
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
    required DateTime startTime,
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
      'start_time': startTime.millisecondsSinceEpoch ~/ 1000,
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
      print(
        '[TRANSIT] Public transport API error: ${response.statusCode} Body: ${response.body} URI: $uri',
      );
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
    final type = '${item['type'] ?? ''}'.toLowerCase();
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
      isPlatformLevel: type == 'station_platform',
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
    required Object? rawScheduleEvents,
    required String routeName,
    required String destinationLabel,
    required DateTime requestedAt,
  }) {
    final exactTimes = <DateTime>[];
    int? smallestIntervalMinutes;
    final scheduleEvents = _parseScheduleEvents(
      rawScheduleEvents,
      requestedAt: requestedAt,
    );

    for (final rawSchedule in rawSchedules) {
      if (rawSchedule is! Map) continue;
      final schedule = Map<String, dynamic>.from(rawSchedule);
      final type = _stringOrNull(schedule['type']) ?? '';
      final preciseTime = _stringOrNull(schedule['precise_time']);
      final period = (schedule['period'] as num?)?.toInt();
      if (type == 'precise' && preciseTime != null) {
        final preciseDateTime = _resolvePreciseScheduleDateTime(
          schedule,
          preciseTime: preciseTime,
          requestedAt: requestedAt,
        );
        if (preciseDateTime == null) continue;
        if (preciseDateTime.isBefore(
          requestedAt.subtract(const Duration(minutes: 1)),
        )) {
          continue;
        }
        exactTimes.add(preciseDateTime);
        continue;
      }
      if (type == 'periodic' &&
          period != null &&
          period > 0 &&
          period < 0xFFFFFFFF &&
          _periodicScheduleLooksActive(
            schedule,
            scheduleEvents: scheduleEvents,
            requestedAt: requestedAt,
          )) {
        if (smallestIntervalMinutes == null ||
            period < smallestIntervalMinutes) {
          smallestIntervalMinutes = period;
        }
      }
    }

    if (exactTimes.isNotEmpty) {
      exactTimes.sort();
      return <TransitScheduleEntry>[
        TransitScheduleEntry(
          routeName: routeName,
          destinationLabel: destinationLabel,
          exactTimes:
              exactTimes
                  .map(_formatScheduleTime)
                  .toSet()
                  .toList(growable: false)
                ..sort(),
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

  List<String> _extractBoardingRouteNames(Map<String, dynamic> option) {
    final waypoints = option['waypoints'];
    if (waypoints is! List) return const [];

    for (final rawWaypoint in waypoints) {
      if (rawWaypoint is! Map) continue;
      final waypoint = Map<String, dynamic>.from(rawWaypoint);
      final routeNames = waypoint['routes_names'];
      if (routeNames is! List) continue;
      final result = <String>{};
      for (final rawName in routeNames) {
        final name = _stringOrNull(rawName);
        if (name != null) {
          result.add(name);
        }
      }
      if (result.isNotEmpty) {
        return result.toList(growable: false);
      }
    }
    return const [];
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
    String n = routeName.split('(')[0].split('（')[0].trim();
    return n
        .toUpperCase()
        .replaceAll('МАРШРУТ', '')
        .replaceAll('АВТОБУС', '')
        .replaceAll(RegExp(r'[^A-Z0-9\u0410-\u044F\u0401\u0451]'), '');
  }

  String _formatScheduleTime(DateTime dateTime) {
    final hh = dateTime.hour.toString().padLeft(2, '0');
    final mm = dateTime.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  DateTime? _resolvePreciseScheduleDateTime(
    Map<String, dynamic> schedule, {
    required String preciseTime,
    required DateTime requestedAt,
  }) {
    final fromStartTime = _resolveScheduleDateTime(schedule, requestedAt);
    if (fromStartTime != null) {
      return fromStartTime;
    }
    return _timeOfDayOnRequestedDate(preciseTime, requestedAt: requestedAt);
  }

  DateTime? _resolveScheduleDateTime(
    Map<String, dynamic> schedule,
    DateTime requestedAt,
  ) {
    final utcSeconds = _normalizedUnixSeconds(schedule['start_time_utc']);
    if (utcSeconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        utcSeconds * 1000,
        isUtc: true,
      ).toLocal();
    }

    final localSeconds = _secondsFromDayStart(schedule['start_time']);
    if (localSeconds == null) return null;

    var candidate = _startOfRequestedDay(
      requestedAt,
    ).add(Duration(seconds: localSeconds));
    if (candidate.isBefore(requestedAt.subtract(const Duration(hours: 12)))) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  int? _normalizedUnixSeconds(Object? value) {
    final raw = _intValue(value);
    if (raw == null || raw <= 0) return null;

    var candidate = raw;
    const maxReasonableUnixSeconds = 4102444800; // 2100-01-01T00:00:00Z
    const unsignedIntSpan = 4294967296;
    while (candidate > maxReasonableUnixSeconds) {
      candidate -= unsignedIntSpan;
    }
    if (candidate <= 0) return null;
    return candidate;
  }

  int? _secondsFromDayStart(Object? value) {
    final seconds = _intValue(value);
    if (seconds == null || seconds < 0) return null;
    if (seconds >= const Duration(days: 1).inSeconds) return null;
    return seconds;
  }

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  DateTime? _timeOfDayOnRequestedDate(
    String value, {
    required DateTime requestedAt,
  }) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.tryParse(match.group(1)!);
    final minutes = int.tryParse(match.group(2)!);
    if (hours == null || minutes == null) return null;
    if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null;
    return requestedAt.isUtc
        ? DateTime.utc(
            requestedAt.year,
            requestedAt.month,
            requestedAt.day,
            hours,
            minutes,
          )
        : DateTime(
            requestedAt.year,
            requestedAt.month,
            requestedAt.day,
            hours,
            minutes,
          );
  }

  DateTime _startOfRequestedDay(DateTime requestedAt) {
    return requestedAt.isUtc
        ? DateTime.utc(requestedAt.year, requestedAt.month, requestedAt.day)
        : DateTime(requestedAt.year, requestedAt.month, requestedAt.day);
  }

  List<_TransitScheduleEvent> _parseScheduleEvents(
    Object? rawEvents, {
    required DateTime requestedAt,
  }) {
    if (rawEvents is! List) return const [];
    final result = <_TransitScheduleEvent>[];
    for (final rawEvent in rawEvents) {
      if (rawEvent is! Map) continue;
      final event = Map<String, dynamic>.from(rawEvent);
      final type = _stringOrNull(event['type'])?.toLowerCase();
      if (type == null) continue;
      final dateTime = _resolvePreciseScheduleDateTime(
        event,
        preciseTime: _stringOrNull(event['precise_time']) ?? '',
        requestedAt: requestedAt,
      );
      if (dateTime == null) continue;
      result.add(_TransitScheduleEvent(type: type, dateTime: dateTime));
    }
    return result;
  }

  bool _periodicScheduleLooksActive(
    Map<String, dynamic> schedule, {
    required List<_TransitScheduleEvent> scheduleEvents,
    required DateTime requestedAt,
  }) {
    final grace = requestedAt.add(const Duration(minutes: 1));
    final scheduleStart = _resolveScheduleDateTime(schedule, requestedAt);
    if (scheduleStart != null && scheduleStart.isAfter(grace)) {
      return false;
    }

    final beginEvents = scheduleEvents
        .where((event) => event.type.contains('begin'))
        .map((event) => event.dateTime)
        .toList(growable: false);
    if (beginEvents.isNotEmpty &&
        beginEvents.every((event) => event.isAfter(grace))) {
      return false;
    }

    final endEvents = scheduleEvents
        .where(
          (event) =>
              event.type.contains('end') || event.type.contains('finish'),
        )
        .map((event) => event.dateTime)
        .toList(growable: false);
    if (endEvents.isNotEmpty &&
        endEvents.every(
          (event) =>
              event.isBefore(requestedAt) ||
              event.isAtSameMomentAs(requestedAt),
        )) {
      return false;
    }

    return true;
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

class _TransitScheduleEvent {
  const _TransitScheduleEvent({required this.type, required this.dateTime});

  final String type;
  final DateTime dateTime;
}
