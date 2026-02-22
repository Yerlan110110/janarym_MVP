import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/navigation/models/navigation_mode_state.dart';
import 'package:janarym_app2/navigation/navigation_mode_controller.dart';
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
  _FakeRouteService(this.destination);

  final DestinationCandidate destination;

  @override
  void setLanguage(AppLanguage language) {}

  @override
  Future<RouteBuildResult> buildPedestrianRoute({
    required NavPoint origin,
    required NavPoint destination,
  }) async {
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
  }) async {
    return [destination];
  }
}

void main() {
  group('NavigationModeController', () {
    late _FakeLocationProvider locationProvider;
    late List<String> spoken;
    late NavigationModeController controller;

    setUp(() {
      spoken = [];
      locationProvider = _FakeLocationProvider();
      controller = NavigationModeController(
        speak: (text) async => spoken.add(text),
        routeService: _FakeRouteService(
          const DestinationCandidate(
            title: 'Абая 10',
            subtitle: 'Абая 10, Алматы',
            point: NavPoint(latitude: 43.2400, longitude: 76.9000),
          ),
        ),
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
  });
}
