import 'dart:convert';

import 'package:http/http.dart' as http;

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.temperatureC,
    required this.windSpeedKmh,
    required this.weatherCode,
  });

  final double temperatureC;
  final double windSpeedKmh;
  final int weatherCode;

  String describeRu() {
    final weather = _weatherCodeRu(weatherCode);
    return '$weather, ${temperatureC.toStringAsFixed(0)}°C, ветер ${windSpeedKmh.toStringAsFixed(0)} км/ч';
  }

  String describeKk() {
    final weather = _weatherCodeKk(weatherCode);
    return '$weather, ${temperatureC.toStringAsFixed(0)}°C, жел ${windSpeedKmh.toStringAsFixed(0)} км/сағ';
  }

  static String _weatherCodeRu(int code) {
    if (code == 0) return 'ясно';
    if (code == 1 || code == 2) return 'переменная облачность';
    if (code == 3) return 'пасмурно';
    if (code == 45 || code == 48) return 'туман';
    if (code >= 51 && code <= 67) return 'дождь';
    if (code >= 71 && code <= 77) return 'снег';
    if (code >= 80 && code <= 82) return 'ливень';
    if (code >= 95) return 'гроза';
    return 'погода';
  }

  static String _weatherCodeKk(int code) {
    if (code == 0) return 'ашық';
    if (code == 1 || code == 2) return 'ала бұлт';
    if (code == 3) return 'бұлтты';
    if (code == 45 || code == 48) return 'тұман';
    if (code >= 51 && code <= 67) return 'жаңбыр';
    if (code >= 71 && code <= 77) return 'қар';
    if (code >= 80 && code <= 82) return 'нөсер';
    if (code >= 95) return 'найзағай';
    return 'ауа райы';
  }
}

class OpenMeteoService {
  OpenMeteoService({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;

  Future<WeatherSnapshot?> fetchCurrent({
    required double latitude,
    required double longitude,
  }) async {
    final uri =
        Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
          'latitude': latitude.toString(),
          'longitude': longitude.toString(),
          'current': 'temperature_2m,wind_speed_10m,weather_code',
          'timezone': 'auto',
        });
    final response = await _httpClient
        .get(uri)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final current = json['current'] as Map<String, dynamic>?;
    if (current == null) return null;
    return WeatherSnapshot(
      temperatureC: (current['temperature_2m'] as num?)?.toDouble() ?? 0,
      windSpeedKmh: (current['wind_speed_10m'] as num?)?.toDouble() ?? 0,
      weatherCode: (current['weather_code'] as num?)?.toInt() ?? -1,
    );
  }

  void dispose() {
    _httpClient.close();
  }
}
