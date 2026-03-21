import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/navigation/models/navigation_mode_state.dart';
import 'package:janarym_app2/navigation/services/dgis_transit_service.dart';

void main() {
  const stop = TransitStopCandidate(
    id: 'stop_university',
    stationId: 'station_university',
    platformIds: <String>['platform_1'],
    title: 'Остановка Университет',
    subtitle: 'Астана',
    point: NavPoint(latitude: 51.1284, longitude: 71.4304),
    routes: <TransitRouteSummary>[
      TransitRouteSummary(
        routeId: 'route_10',
        displayName: '10',
        transportType: 'bus',
        directionLabels: <String>['Вокзал'],
      ),
    ],
  );

  setUp(() {
    dotenv.clean();
  });

  group('DgisTransitService', () {
    test('searchStops parses stop candidates and routes', () async {
      late Uri requestedUri;
      dotenv.loadFromString(envString: 'DGIS_API_KEY=test-key');
      final client = MockClient((request) async {
        requestedUri = request.url;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'result': <String, dynamic>{
                'items': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'stop_university',
                    'type': 'station',
                    'name': 'Остановка Университет',
                    'full_address_name': 'Астана',
                    'point': <String, double>{'lat': 51.1284, 'lon': 71.4304},
                    'station_id': 'station_university',
                    'platforms': <Map<String, dynamic>>[
                      <String, dynamic>{'id': 'platform_1'},
                    ],
                    'directions': <String>['Вокзал'],
                    'routes': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'id': 'route_10',
                        'name': '10',
                        'type': 'bus',
                      },
                      <String, dynamic>{
                        'id': 'route_12',
                        'name': '12',
                        'type': 'bus',
                      },
                    ],
                  },
                ],
              },
            }),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });
      final service = DgisTransitService(httpClient: client);

      final stops = await service.searchStops(
        query: 'университет',
        nearLocation: const NavPoint(latitude: 51.129, longitude: 71.431),
      );

      expect(requestedUri.host, 'catalog.api.2gis.com');
      expect(requestedUri.path, '/3.0/items');
      expect(requestedUri.queryParameters['type'], 'station,station_platform');
      expect(stops, hasLength(1));
      expect(stops.first.id, 'stop_university');
      expect(stops.first.platformIds, contains('platform_1'));
      expect(stops.first.routes.map((route) => route.displayName), [
        '10',
        '12',
      ]);

      service.dispose();
    });

    test('getStopRoutes returns cached routes when present', () async {
      dotenv.loadFromString(envString: 'DGIS_API_KEY=test-key');
      final service = DgisTransitService(
        httpClient: MockClient((request) async {
          fail('unexpected network call: ${request.url}');
        }),
      );

      final routes = await service.getStopRoutes(stop: stop);

      expect(routes, hasLength(1));
      expect(routes.first.displayName, '10');
      service.dispose();
    });

    test(
      'getScheduledArrivals parses exact times from public transport API',
      () async {
        dotenv.loadFromString(envString: 'DGIS_API_KEY=test-key');
        late Uri requestedUri;
        final service = DgisTransitService(
          httpClient: MockClient((request) async {
            if (request.url.host == 'routing.api.2gis.com') {
              requestedUri = request.url;
              return http.Response.bytes(
                utf8.encode(
                  jsonEncode(<Map<String, dynamic>>[
                    <String, dynamic>{
                      'waypoints': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'routes_names': <String>['10'],
                          'subtype': 'bus',
                        },
                      ],
                      'schedules': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'type': 'precise',
                          'precise_time': '17:36',
                          'period': 4294967295,
                        },
                        <String, dynamic>{
                          'type': 'precise',
                          'precise_time': '17:42',
                          'period': 4294967295,
                        },
                      ],
                    },
                  ]),
                ),
                200,
                headers: const <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                },
              );
            }
            return http.Response('[]', 200);
          }),
        );

        final entries = await service.getScheduledArrivals(
          stop: stop,
          routeName: '10',
          nearLocation: const NavPoint(latitude: 51.13, longitude: 71.45),
        );

        expect(requestedUri.host, 'routing.api.2gis.com');
        expect(requestedUri.path, '/public_transport/2.0');
        expect(entries, hasLength(1));
        expect(entries.first.sourceType, TransitScheduleSourceType.precise);
        expect(entries.first.exactTimes, ['17:36', '17:42']);
        expect(entries.first.destinationLabel, 'Вокзал');

        service.dispose();
      },
    );

    test('getScheduledArrivals parses periodic schedule', () async {
      dotenv.loadFromString(envString: 'DGIS_API_KEY=test-key');
      final service = DgisTransitService(
        httpClient: MockClient((request) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<Map<String, dynamic>>[
                <String, dynamic>{
                  'waypoints': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'routes_names': <String>['10'],
                      'subtype': 'bus',
                    },
                  ],
                  'schedules': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'type': 'periodic',
                      'period': 6,
                      'precise_time': '',
                    },
                  ],
                },
              ]),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );

      final entries = await service.getScheduledArrivals(
        stop: stop,
        routeName: '10',
        nearLocation: const NavPoint(latitude: 51.13, longitude: 71.45),
      );

      expect(entries, hasLength(1));
      expect(entries.first.sourceType, TransitScheduleSourceType.periodic);
      expect(entries.first.intervalMinutes, 6);
      expect(entries.first.exactTimes, isEmpty);
      service.dispose();
    });

    test('missing API key is treated as soft unavailability', () async {
      final service = DgisTransitService(
        httpClient: MockClient((request) async => http.Response('[]', 200)),
        language: AppLanguage.ru,
      );

      expect(
        () => service.searchStops(
          query: 'университет',
          nearLocation: const NavPoint(latitude: 51.1284, longitude: 71.4304),
        ),
        throwsA(isA<TransitServiceUnavailable>()),
      );

      service.dispose();
    });
  });
}
