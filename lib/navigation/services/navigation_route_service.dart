import 'package:yandex_mapkit/yandex_mapkit.dart';

import '../../l10n/app_locale_controller.dart';
import '../../l10n/app_localizations.dart';
import '../models/navigation_mode_state.dart';
import 'instruction_engine.dart';
import 'navigation_utils.dart';

class RouteBuildResult {
  final List<NavPoint> polyline;
  final List<NavStep> steps;
  final double totalDistanceMeters;
  final Duration estimatedDuration;

  const RouteBuildResult({
    required this.polyline,
    required this.steps,
    required this.totalDistanceMeters,
    required this.estimatedDuration,
  });
}

abstract class NavigationRouteService {
  void setLanguage(AppLanguage language) {}

  Future<List<DestinationCandidate>> searchCandidates({
    required String query,
    required NavPoint origin,
    int limit = 3,
  });

  Future<RouteBuildResult> buildPedestrianRoute({
    required NavPoint origin,
    required NavPoint destination,
  });
}

class YandexNavigationRouteService implements NavigationRouteService {
  YandexNavigationRouteService({
    InstructionEngine? instructionEngine,
    AppLanguage language = AppLanguage.ru,
  }) : _instructionEngine = instructionEngine ?? InstructionEngine(),
       _language = language {
    _instructionEngine.setLanguage(language);
  }

  final InstructionEngine _instructionEngine;
  AppLanguage _language;
  static const BoundingBox _astanaBounds = BoundingBox(
    southWest: Point(latitude: 50.95, longitude: 71.15),
    northEast: Point(latitude: 51.28, longitude: 71.62),
  );

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  @override
  void setLanguage(AppLanguage language) {
    _language = language;
    _instructionEngine.setLanguage(language);
  }

  @override
  Future<List<DestinationCandidate>> searchCandidates({
    required String query,
    required NavPoint origin,
    int limit = 3,
  }) async {
    // Interface keeps origin; Astana-only mode intentionally ignores it.
    final _ = origin;
    final cleanQuery = _normalizeAstanaQuery(query.trim());
    if (cleanQuery.isEmpty) return const [];
    return _searchInAstana(query: cleanQuery, limit: limit);
  }

  Future<List<DestinationCandidate>> _searchInAstana({
    required String query,
    required int limit,
  }) async {
    final geometry = Geometry.fromBoundingBox(_astanaBounds);

    final resultPageSize = limit.clamp(1, 7).toInt();
    final (session, future) = await YandexSearch.searchByText(
      searchText: query,
      geometry: geometry,
      searchOptions: SearchOptions(
        geometry: true,
        searchType: SearchType.geo,
        resultPageSize: resultPageSize,
        userPosition: const Point(latitude: 51.1284, longitude: 71.4304),
      ),
    );

    try {
      final result = await future;
      if (result.error != null && result.error!.trim().isNotEmpty) {
        throw Exception(result.error);
      }

      final items = result.items ?? const <SearchItem>[];
      final candidates = <DestinationCandidate>[];

      for (final item in items) {
        final candidatePoint = _extractPoint(item);
        if (candidatePoint == null) continue;
        if (!_isInsideAstana(candidatePoint)) continue;

        candidates.add(
          DestinationCandidate(
            title: item.name.trim().isEmpty
                ? _l10n.routeTitleFallback
                : item.name.trim(),
            subtitle:
                item.toponymMetadata?.address.formattedAddress.trim() ?? '',
            point: candidatePoint,
          ),
        );

        if (candidates.length >= limit) break;
      }

      return candidates;
    } finally {
      await session.close();
    }
  }

  @override
  Future<RouteBuildResult> buildPedestrianRoute({
    required NavPoint origin,
    required NavPoint destination,
  }) async {
    if (!_isInsideAstana(destination)) {
      throw Exception(_l10n.routeAstanaOnly);
    }

    final points = <RequestPoint>[
      RequestPoint(
        point: Point(latitude: origin.latitude, longitude: origin.longitude),
        requestPointType: RequestPointType.wayPoint,
      ),
      RequestPoint(
        point: Point(
          latitude: destination.latitude,
          longitude: destination.longitude,
        ),
        requestPointType: RequestPointType.wayPoint,
      ),
    ];

    final (session, future) = await YandexPedestrian.requestRoutes(
      points: points,
      fitnessOptions: const FitnessOptions(
        avoidSteep: false,
        avoidStairs: false,
      ),
      timeOptions: const TimeOptions(),
    );

    try {
      final result = await future;
      if (result.error != null && result.error!.trim().isNotEmpty) {
        throw Exception(result.error);
      }
      final route = result.routes?.isNotEmpty == true
          ? result.routes!.first
          : null;
      if (route == null) {
        throw Exception(_l10n.routeNotFound);
      }

      final polyline = route.geometry.points
          .map(
            (point) =>
                NavPoint(latitude: point.latitude, longitude: point.longitude),
          )
          .toList(growable: false);

      if (polyline.length < 2) {
        throw Exception(_l10n.routeInsufficientData);
      }

      var distance = route.metadata.weight.walkingDistance.value ?? 0;
      if (distance <= 0) {
        distance = _estimateDistanceFromPolyline(polyline);
      }

      final timeSeconds = route.metadata.weight.time.value ?? 0;
      final duration = Duration(
        seconds: timeSeconds > 0
            ? timeSeconds.round()
            : (distance / 1.25).round(),
      );

      return RouteBuildResult(
        polyline: polyline,
        steps: _instructionEngine.buildSteps(polyline),
        totalDistanceMeters: distance,
        estimatedDuration: duration,
      );
    } finally {
      await session.close();
    }
  }

  NavPoint? _extractPoint(SearchItem item) {
    final toponymPoint = item.toponymMetadata?.balloonPoint;
    if (toponymPoint != null) {
      return NavPoint(
        latitude: toponymPoint.latitude,
        longitude: toponymPoint.longitude,
      );
    }

    for (final geometry in item.geometry) {
      if (geometry.point != null) {
        return NavPoint(
          latitude: geometry.point!.latitude,
          longitude: geometry.point!.longitude,
        );
      }
      if (geometry.boundingBox != null) {
        final sw = geometry.boundingBox!.southWest;
        final ne = geometry.boundingBox!.northEast;
        return NavPoint(
          latitude: (sw.latitude + ne.latitude) / 2,
          longitude: (sw.longitude + ne.longitude) / 2,
        );
      }
    }

    return null;
  }

  double _estimateDistanceFromPolyline(List<NavPoint> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += distanceMeters(points[i - 1], points[i]);
    }
    return total;
  }

  bool _isInsideAstana(NavPoint point) {
    return point.latitude >= _astanaBounds.southWest.latitude &&
        point.latitude <= _astanaBounds.northEast.latitude &&
        point.longitude >= _astanaBounds.southWest.longitude &&
        point.longitude <= _astanaBounds.northEast.longitude;
  }

  String _normalizeAstanaQuery(String query) {
    if (query.isEmpty) return query;
    final lowered = query.toLowerCase();
    if (lowered.contains('астана') ||
        lowered.contains('astana') ||
        lowered.contains('нур султан') ||
        lowered.contains('нұр сұлтан') ||
        lowered.contains('nursultan')) {
      return query;
    }
    return '$query, ${_l10n.routeCityAstana}';
  }
}
