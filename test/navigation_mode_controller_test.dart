import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/navigation/models/navigation_mode_state.dart';
import 'package:janarym_app2/navigation/navigation_mode_controller.dart';
import 'package:janarym_app2/navigation/services/dgis_transit_service.dart';
import 'package:janarym_app2/navigation/services/location_provider.dart';
import 'package:janarym_app2/navigation/services/navigation_route_service.dart';
import 'package:url_launcher/url_launcher.dart';

class _FakeLocationProvider implements NavigationLocationProvider {
  _FakeLocationProvider({NavPoint? current})
    : _current =
          current ?? const NavPoint(latitude: 43.2389, longitude: 76.8897);

  final StreamController<NavPoint> _controller =
      StreamController<NavPoint>.broadcast();
  bool permission = true;
  NavPoint _current;

  @override
  Future<bool> ensurePermission() async => permission;

  @override
  Future<NavPoint> getCurrentLocation() async => _current;

  @override
  Stream<NavPoint> positionStream() => _controller.stream;

  Future<void> emit(NavPoint point) async {
    _current = point;
    _controller.add(point);
  }

  Future<void> close() async {
    await _controller.close();
  }
}

class _FakeRouteService implements NavigationRouteService {
  _FakeRouteService(this.destination, {this.buildError});

  final DestinationCandidate destination;
  final String? buildError;
  NavigationDestinationKind lastSearchKind = NavigationDestinationKind.generic;

  @override
  void setLanguage(AppLanguage language) {}

  @override
  Future<RouteBuildResult> buildPedestrianRoute({
    required NavPoint origin,
    required NavPoint destination,
  }) async {
    if (buildError != null) {
      throw Exception(buildError);
    }
    return RouteBuildResult(
      polyline: [origin, destination],
      steps: const [
        NavStep(
          index: 0,
          polylineIndex: 1,
          maneuverType: NavManeuverType.arrive,
          instruction: 'Вы на месте.',
          distanceFromRouteStartMeters: 1200,
        ),
      ],
      totalDistanceMeters: 1200,
      estimatedDuration: const Duration(minutes: 15),
    );
  }

  @override
  Future<List<DestinationCandidate>> searchCandidates({
    required String query,
    required NavPoint origin,
    int limit = 3,
    NavigationDestinationKind destinationKind =
        NavigationDestinationKind.generic,
  }) async {
    lastSearchKind = destinationKind;
    return [destination];
  }
}

class _FakeTransitService implements NavigationTransitService {
  _FakeTransitService({
    required this.stops,
    this.routesByStop = const <String, List<TransitRouteSummary>>{},
    this.schedulesByStopAndRoute = const <String, List<TransitScheduleEntry>>{},
  });

  final List<TransitStopCandidate> stops;
  final Map<String, List<TransitRouteSummary>> routesByStop;
  final Map<String, List<TransitScheduleEntry>> schedulesByStopAndRoute;

  String? lastStopQuery;
  String? lastScheduleRouteName;

  @override
  void setLanguage(AppLanguage language) {}

  @override
  Future<List<TransitStopCandidate>> searchStops({
    required String query,
    required NavPoint nearLocation,
    int limit = 3,
  }) async {
    lastStopQuery = query;
    return stops.take(limit).toList(growable: false);
  }

  @override
  Future<List<TransitRouteSummary>> getStopRoutes({
    required TransitStopCandidate stop,
    NavPoint? nearLocation,
  }) async {
    return routesByStop[stop.id] ?? stop.routes;
  }

  @override
  Future<List<TransitScheduleEntry>> getScheduledArrivals({
    required TransitStopCandidate stop,
    required String routeName,
    NavPoint? nearLocation,
  }) async {
    lastScheduleRouteName = routeName;
    return schedulesByStopAndRoute['${stop.id}|$routeName'] ?? const [];
  }

  @override
  void dispose() {}
}

void main() {
  group('NavigationModeController', () {
    late _FakeLocationProvider locationProvider;
    late List<String> spoken;
    late NavigationModeController controller;
    late _FakeTransitService transitService;

    setUp(() {
      spoken = [];
      locationProvider = _FakeLocationProvider();
      transitService = _FakeTransitService(
        stops: const <TransitStopCandidate>[
          TransitStopCandidate(
            id: 'stop_university',
            stationId: 'station_university',
            platformIds: <String>['platform_1'],
            title: 'Остановка Университет',
            subtitle: 'Астана',
            point: NavPoint(latitude: 43.2400, longitude: 76.9000),
            routes: <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_10',
                displayName: '10',
                transportType: 'bus',
                directionLabels: <String>['Вокзал'],
              ),
              TransitRouteSummary(
                routeId: 'route_12',
                displayName: '12',
                transportType: 'bus',
              ),
            ],
          ),
        ],
        routesByStop: const <String, List<TransitRouteSummary>>{
          'stop_university': <TransitRouteSummary>[
            TransitRouteSummary(
              routeId: 'route_10',
              displayName: '10',
              transportType: 'bus',
              directionLabels: <String>['Вокзал'],
            ),
            TransitRouteSummary(
              routeId: 'route_12',
              displayName: '12',
              transportType: 'bus',
            ),
          ],
        },
        schedulesByStopAndRoute: const <String, List<TransitScheduleEntry>>{
          'stop_university|10': <TransitScheduleEntry>[
            TransitScheduleEntry(
              routeName: '10',
              destinationLabel: 'Вокзал',
              exactTimes: <String>['17:36', '17:42', '17:49'],
              intervalMinutes: null,
              sourceType: TransitScheduleSourceType.precise,
            ),
          ],
        },
      );
      controller = NavigationModeController(
        speak: (text) async => spoken.add(text),
        routeService: _FakeRouteService(
          const DestinationCandidate(
            title: 'Абая 10',
            subtitle: 'Абая 10, Алматы',
            point: NavPoint(latitude: 43.2400, longitude: 76.9000),
          ),
        ),
        transitService: transitService,
        locationProvider: locationProvider,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
      );
    });

    tearDown(() async {
      await controller.dispose();
      await locationProvider.close();
    });

    test('enter and exit mode', () async {
      await controller.enterMode();
      expect(controller.state.value.modeEnabled, isTrue);
      expect(controller.state.value.navStatus, NavigationStatus.idle);

      await controller.exitMode();
      expect(controller.state.value.modeEnabled, isFalse);
      expect(controller.state.value.activeRoute, isNull);
    });

    test('start route outside mode is blocked', () async {
      await controller.startRoute('абая 10');
      expect(spoken.isNotEmpty, isTrue);
      expect(spoken.last, contains('Сначала включите режим маршрута'));
    });

    test('stop route does not disable mode', () async {
      await controller.enterMode();
      await controller.startRoute('абая 10');
      expect(controller.state.value.activeRoute, isNotNull);
      expect(controller.state.value.modeEnabled, isTrue);

      await controller.stopRoute();
      expect(controller.state.value.modeEnabled, isTrue);
      expect(controller.state.value.activeRoute, isNull);
      expect(controller.state.value.navStatus, NavigationStatus.idle);
    });

    test(
      'routes to stop with transit stop hint and announces stop arrival',
      () async {
        final stopRouteService = _FakeRouteService(
          const DestinationCandidate(
            title: 'Остановка Университет',
            subtitle: 'Астана',
            point: NavPoint(latitude: 43.2400, longitude: 76.9000),
            kind: NavigationDestinationKind.transitStop,
          ),
        );
        await controller.dispose();
        controller = NavigationModeController(
          speak: (text) async => spoken.add(text),
          routeService: stopRouteService,
          transitService: transitService,
          locationProvider: locationProvider,
          launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async =>
              false,
        );

        await controller.enterMode();
        await controller.startRouteWithKind(
          'университет',
          destinationKind: NavigationDestinationKind.transitStop,
        );

        expect(transitService.lastStopQuery, 'университет');
        expect(
          controller.state.value.activeRoute?.destination.kind,
          NavigationDestinationKind.transitStop,
        );
        expect(
          controller.state.value.activeRoute?.destination.transitStop?.id,
          'stop_university',
        );

        await locationProvider.emit(
          const NavPoint(latitude: 43.2400, longitude: 76.9000),
        );
        await Future<void>.delayed(Duration.zero);

        expect(spoken.last, contains('Вы у остановки'));
        expect(spoken.last, contains('Университет'));
      },
    );

    test('speaks in kazakh when language is kk', () async {
      final kkSpoken = <String>[];
      final kkController = NavigationModeController(
        speak: (text) async => kkSpoken.add(text),
        routeService: _FakeRouteService(
          const DestinationCandidate(
            title: 'Қабанбай батыр',
            subtitle: 'Қабанбай батыр, Астана',
            point: NavPoint(latitude: 51.1284, longitude: 71.4304),
          ),
        ),
        locationProvider: locationProvider,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
        language: AppLanguage.kk,
      );

      await kkController.enterMode();

      expect(kkSpoken.last, contains('Маршрут режимі қосылды'));

      await kkController.dispose();
    });

    test('surfaces astana-only route rejection', () async {
      await controller.dispose();
      controller = NavigationModeController(
        speak: (text) async => spoken.add(text),
        routeService: _FakeRouteService(
          const DestinationCandidate(
            title: 'Арбат 1',
            subtitle: 'Алматы',
            point: NavPoint(latitude: 43.2389, longitude: 76.8897),
          ),
          buildError: 'Сейчас поддерживаются только маршруты по Астане.',
        ),
        transitService: transitService,
        locationProvider: locationProvider,
        launchUrlFn: (uri, {mode = LaunchMode.platformDefault}) async => false,
      );

      await controller.enterMode();
      await controller.startRoute('арбат 1 алматы');

      expect(spoken.last, contains('только маршруты по Астане'));
    });
  });
}
