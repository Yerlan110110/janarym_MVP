import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/bus/bus_mode_controller.dart';
import 'package:janarym_app2/bus/models/bus_mode_state.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/navigation/models/transit_models.dart';
import 'package:janarym_app2/navigation/services/dgis_transit_service.dart';
import 'package:janarym_app2/navigation/services/location_provider.dart';

class _FakeLocationProvider implements NavigationLocationProvider {
  _FakeLocationProvider({NavPoint? current})
    : _current =
          current ?? const NavPoint(latitude: 51.08995, longitude: 71.41365);

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
  String? lastRoutesStopId;
  String? lastScheduleStopId;
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
    lastRoutesStopId = stop.id;
    return routesByStop[stop.id] ?? stop.routes;
  }

  @override
  Future<List<TransitScheduleEntry>> getScheduledArrivals({
    required TransitStopCandidate stop,
    required String routeName,
    NavPoint? nearLocation,
  }) async {
    lastScheduleStopId = stop.id;
    lastScheduleRouteName = routeName;
    return schedulesByStopAndRoute['${stop.id}|$routeName'] ?? const [];
  }

  @override
  void dispose() {}
}

void main() {
  group('BusModeController', () {
    late _FakeLocationProvider locationProvider;
    late _FakeTransitService transitService;
    late List<String> spoken;
    late BusModeController controller;

    setUp(() {
      spoken = [];
      locationProvider = _FakeLocationProvider();
      transitService = _FakeTransitService(
        stops: const <TransitStopCandidate>[
          TransitStopCandidate(
            id: 'expo_right_platform',
            stationId: 'expo_station_right',
            platformIds: <String>['expo_right_platform'],
            title: 'ЖК Эксплаза',
            subtitle: 'Астана',
            point: NavPoint(latitude: 51.0900, longitude: 71.4137),
            routes: <TransitRouteSummary>[],
            isPlatformLevel: true,
          ),
          TransitStopCandidate(
            id: 'expo_left_platform',
            stationId: 'expo_station_left',
            platformIds: <String>['expo_left_platform'],
            title: 'ЖК Эксплаза',
            subtitle: 'Астана',
            point: NavPoint(latitude: 51.0893, longitude: 71.4137),
            routes: <TransitRouteSummary>[],
            isPlatformLevel: true,
          ),
        ],
        routesByStop: const <String, List<TransitRouteSummary>>{
          'expo_right_platform': <TransitRouteSummary>[
            TransitRouteSummary(
              routeId: 'route_10_right',
              displayName: '10',
              transportType: 'bus',
              directionLabels: <String>['Аэропорт'],
            ),
          ],
          'expo_left_platform': <TransitRouteSummary>[
            TransitRouteSummary(
              routeId: 'route_10_left',
              displayName: '10',
              transportType: 'bus',
              directionLabels: <String>['Вокзал'],
            ),
            TransitRouteSummary(
              routeId: 'route_22_left',
              displayName: '22',
              transportType: 'bus',
            ),
          ],
        },
        schedulesByStopAndRoute: const <String, List<TransitScheduleEntry>>{
          'expo_right_platform|10': <TransitScheduleEntry>[
            TransitScheduleEntry(
              routeName: '10',
              destinationLabel: 'Аэропорт',
              exactTimes: <String>['17:42'],
              intervalMinutes: null,
              sourceType: TransitScheduleSourceType.precise,
            ),
          ],
          'expo_left_platform|10': <TransitScheduleEntry>[
            TransitScheduleEntry(
              routeName: '10',
              destinationLabel: 'Вокзал',
              exactTimes: <String>['17:36'],
              intervalMinutes: null,
              sourceType: TransitScheduleSourceType.precise,
            ),
          ],
        },
      );
      controller = BusModeController(
        speak: (text) async => spoken.add(text),
        transitService: transitService,
        locationProvider: locationProvider,
      );
    });

    tearDown(() async {
      await controller.dispose();
      await locationProvider.close();
    });

    test('enter and exit mode', () async {
      await controller.enterMode();
      expect(controller.state.value.modeEnabled, isTrue);
      expect(controller.state.value.status, BusModeStatus.idle);

      await controller.exitMode();
      expect(controller.state.value.modeEnabled, isFalse);
      expect(controller.state.value.candidates, isEmpty);
    });

    test(
      'uses only nearest physical stop for route list when names match',
      () async {
        await controller.enterMode(speak: false);
        await controller.speakStopRoutes('ЖК Эксплаза');

        expect(transitService.lastRoutesStopId, 'expo_right_platform');
        expect(spoken.last, contains('ЖК Эксплаза'));
        expect(spoken.last, contains('автобус 10'));
        expect(spoken.last, isNot(contains('автобус 22')));
      },
    );

    test(
      'uses only nearest physical stop for schedule even if opposite side is earlier',
      () async {
        await controller.enterMode(speak: false);
        await controller.speakScheduledArrivals(
          stopQuery: 'ЖК Эксплаза',
          routeName: '10',
        );

        expect(transitService.lastScheduleStopId, 'expo_right_platform');
        expect(transitService.lastScheduleRouteName, '10');
        expect(spoken.last, contains('17:42'));
        expect(spoken.last, isNot(contains('17:36')));
      },
    );

    test(
      'explains that route exists but no live arrival data is available',
      () async {
        transitService = _FakeTransitService(
          stops: const <TransitStopCandidate>[
            TransitStopCandidate(
              id: 'expo_right_platform',
              stationId: 'expo_station_right',
              platformIds: <String>['expo_right_platform'],
              title: 'ЖК Эксплаза',
              subtitle: 'Астана',
              point: NavPoint(latitude: 51.0900, longitude: 71.4137),
              routes: <TransitRouteSummary>[],
              isPlatformLevel: true,
            ),
          ],
          routesByStop: const <String, List<TransitRouteSummary>>{
            'expo_right_platform': <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_10_right',
                displayName: '10',
                transportType: 'bus',
                directionLabels: <String>['Аэропорт'],
              ),
              TransitRouteSummary(
                routeId: 'route_37_right',
                displayName: '37',
                transportType: 'bus',
              ),
            ],
          },
        );
        await controller.dispose();
        controller = BusModeController(
          speak: (text) async => spoken.add(text),
          transitService: transitService,
          locationProvider: locationProvider,
        );

        await controller.enterMode(speak: false);
        await controller.speakScheduledArrivals(
          stopQuery: 'ЖК Эксплаза',
          routeName: '10',
        );

        expect(
          spoken.last,
          contains('Маршрут 10 есть на остановке ЖК Эксплаза'),
        );
        expect(
          spoken.last,
          contains(
            'нет активных рейсов, ночной перерыв или расписание временно недоступно',
          ),
        );
        expect(spoken.last, contains('автобус 10'));
        expect(spoken.last, isNot(contains('не найден')));
      },
    );

    test(
      'does not present periodic schedule as a guaranteed live arrival',
      () async {
        transitService = _FakeTransitService(
          stops: const <TransitStopCandidate>[
            TransitStopCandidate(
              id: 'expo_right_platform',
              stationId: 'expo_station_right',
              platformIds: <String>['expo_right_platform'],
              title: 'ЖК Эксплаза',
              subtitle: 'Астана',
              point: NavPoint(latitude: 51.0900, longitude: 71.4137),
              routes: <TransitRouteSummary>[],
              isPlatformLevel: true,
            ),
          ],
          routesByStop: const <String, List<TransitRouteSummary>>{
            'expo_right_platform': <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_10_right',
                displayName: '10',
                transportType: 'bus',
                directionLabels: <String>['Аэропорт'],
              ),
            ],
          },
          schedulesByStopAndRoute: const <String, List<TransitScheduleEntry>>{
            'expo_right_platform|10': <TransitScheduleEntry>[
              TransitScheduleEntry(
                routeName: '10',
                destinationLabel: 'Аэропорт',
                exactTimes: <String>[],
                intervalMinutes: 15,
                sourceType: TransitScheduleSourceType.periodic,
              ),
            ],
          },
        );
        await controller.dispose();
        controller = BusModeController(
          speak: (text) async => spoken.add(text),
          transitService: transitService,
          locationProvider: locationProvider,
        );

        await controller.enterMode(speak: false);
        await controller.speakScheduledArrivals(
          stopQuery: 'ЖК Эксплаза',
          routeName: '10',
        );

        expect(spoken.last, contains('интервал около 15 минут'));
        expect(spoken.last, contains('ближайшее прибытие сейчас не показано'));
        expect(spoken.last, contains('Возможно, сейчас рейсов нет'));
        expect(spoken.last, isNot(contains('ходит примерно каждые 15 минут')));
      },
    );

    test(
      'uses non-contradictory wording when route cannot be confirmed on stop',
      () async {
        transitService = _FakeTransitService(
          stops: const <TransitStopCandidate>[
            TransitStopCandidate(
              id: 'expo_right_platform',
              stationId: 'expo_station_right',
              platformIds: <String>['expo_right_platform'],
              title: 'ЖК Эксплаза',
              subtitle: 'Астана',
              point: NavPoint(latitude: 51.0900, longitude: 71.4137),
              routes: <TransitRouteSummary>[],
              isPlatformLevel: true,
            ),
          ],
          routesByStop: const <String, List<TransitRouteSummary>>{
            'expo_right_platform': <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_18_right',
                displayName: '18',
                transportType: 'bus',
              ),
              TransitRouteSummary(
                routeId: 'route_37_right',
                displayName: '37',
                transportType: 'bus',
              ),
            ],
          },
        );
        await controller.dispose();
        controller = BusModeController(
          speak: (text) async => spoken.add(text),
          transitService: transitService,
          locationProvider: locationProvider,
        );

        await controller.enterMode(speak: false);
        await controller.speakScheduledArrivals(
          stopQuery: 'ЖК Эксплаза',
          routeName: '10',
        );

        expect(spoken.last, contains('не удалось однозначно подтвердить'));
        expect(spoken.last, contains('автобус 18'));
        expect(spoken.last, isNot(contains('не найден')));
      },
    );

    test(
      'prefers platform level stop over aggregate station for exact stop name',
      () async {
        transitService = _FakeTransitService(
          stops: const <TransitStopCandidate>[
            TransitStopCandidate(
              id: 'station_university',
              stationId: 'station_university',
              platformIds: <String>['platform_university'],
              title: 'Университет',
              subtitle: 'Астана',
              point: NavPoint(latitude: 51.1300, longitude: 71.4300),
              routes: <TransitRouteSummary>[],
            ),
            TransitStopCandidate(
              id: 'platform_university',
              stationId: 'station_university',
              platformIds: <String>['platform_university'],
              title: 'Университет',
              subtitle: 'Астана',
              point: NavPoint(latitude: 51.1302, longitude: 71.4301),
              routes: <TransitRouteSummary>[],
              isPlatformLevel: true,
            ),
          ],
          routesByStop: const <String, List<TransitRouteSummary>>{
            'station_university': <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_station',
                displayName: '99',
                transportType: 'bus',
              ),
            ],
            'platform_university': <TransitRouteSummary>[
              TransitRouteSummary(
                routeId: 'route_platform',
                displayName: '10',
                transportType: 'bus',
              ),
            ],
          },
        );
        await controller.dispose();
        controller = BusModeController(
          speak: (text) async => spoken.add(text),
          transitService: transitService,
          locationProvider: locationProvider,
        );

        await controller.enterMode(speak: false);
        await controller.speakStopRoutes('Университет');

        expect(transitService.lastRoutesStopId, 'platform_university');
        expect(spoken.last, contains('автобус 10'));
        expect(spoken.last, isNot(contains('автобус 99')));
      },
    );

    test('asks user to choose when there is no exact stop match', () async {
      transitService = _FakeTransitService(
        stops: const <TransitStopCandidate>[
          TransitStopCandidate(
            id: 'stop_university',
            stationId: 'stop_university_station',
            platformIds: <String>['stop_university'],
            title: 'Университет',
            subtitle: 'Астана',
            point: NavPoint(latitude: 51.1300, longitude: 71.4300),
            routes: <TransitRouteSummary>[],
            isPlatformLevel: true,
          ),
          TransitStopCandidate(
            id: 'stop_university_street',
            stationId: 'stop_university_street_station',
            platformIds: <String>['stop_university_street'],
            title: 'Университетская',
            subtitle: 'Астана',
            point: NavPoint(latitude: 51.1310, longitude: 71.4310),
            routes: <TransitRouteSummary>[],
            isPlatformLevel: true,
          ),
        ],
      );
      await controller.dispose();
      controller = BusModeController(
        speak: (text) async => spoken.add(text),
        transitService: transitService,
        locationProvider: locationProvider,
      );

      await controller.enterMode(speak: false);
      await controller.speakStopRoutes('универ');

      expect(controller.state.value.status, BusModeStatus.awaitingChoice);
      expect(controller.state.value.candidates, hasLength(2));
      expect(spoken.last, contains('Университет'));
      expect(spoken.last, contains('Университетская'));
    });

    test('speaks in kazakh when language is kk', () async {
      final kkSpoken = <String>[];
      final kkController = BusModeController(
        speak: (text) async => kkSpoken.add(text),
        transitService: transitService,
        locationProvider: locationProvider,
        language: AppLanguage.kk,
      );

      await kkController.enterMode();

      expect(kkSpoken.last, contains('Автобус режимі қосылды'));

      await kkController.dispose();
    });
  });
}
