import 'dart:math' as math;

import '../models/navigation_mode_state.dart';

const _earthRadiusMeters = 6371000.0;

double toRadians(double degrees) => degrees * math.pi / 180.0;
double toDegrees(double radians) => radians * 180.0 / math.pi;

double normalizeDeltaDegrees(double degrees) {
  var result = degrees;
  while (result > 180) {
    result -= 360;
  }
  while (result < -180) {
    result += 360;
  }
  return result;
}

double distanceMeters(NavPoint a, NavPoint b) {
  final lat1 = toRadians(a.latitude);
  final lat2 = toRadians(b.latitude);
  final dLat = lat2 - lat1;
  final dLon = toRadians(b.longitude - a.longitude);

  final sinLat = math.sin(dLat / 2);
  final sinLon = math.sin(dLon / 2);
  final h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon;
  final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  return _earthRadiusMeters * c;
}

double bearingDegrees(NavPoint from, NavPoint to) {
  final lat1 = toRadians(from.latitude);
  final lat2 = toRadians(to.latitude);
  final dLon = toRadians(to.longitude - from.longitude);

  final y = math.sin(dLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  final bearing = toDegrees(math.atan2(y, x));
  return (bearing + 360) % 360;
}

double distanceToPolylineMeters(NavPoint point, List<NavPoint> polyline) {
  if (polyline.isEmpty) return double.infinity;
  if (polyline.length == 1) return distanceMeters(point, polyline.first);

  var minDistance = double.infinity;
  for (var i = 0; i < polyline.length - 1; i++) {
    final distance = _distancePointToSegmentMeters(
      point,
      polyline[i],
      polyline[i + 1],
    );
    if (distance < minDistance) {
      minDistance = distance;
    }
  }
  return minDistance;
}

double _distancePointToSegmentMeters(NavPoint p, NavPoint a, NavPoint b) {
  final latRef = toRadians(p.latitude);
  final x = _lonToMeters(p.longitude, latRef);
  final y = _latToMeters(p.latitude);
  final x1 = _lonToMeters(a.longitude, latRef);
  final y1 = _latToMeters(a.latitude);
  final x2 = _lonToMeters(b.longitude, latRef);
  final y2 = _latToMeters(b.latitude);

  final dx = x2 - x1;
  final dy = y2 - y1;
  if (dx == 0 && dy == 0) {
    return math.sqrt((x - x1) * (x - x1) + (y - y1) * (y - y1));
  }

  final t = (((x - x1) * dx) + ((y - y1) * dy)) / (dx * dx + dy * dy);
  final clampedT = t.clamp(0.0, 1.0);
  final projX = x1 + clampedT * dx;
  final projY = y1 + clampedT * dy;

  final px = x - projX;
  final py = y - projY;
  return math.sqrt(px * px + py * py);
}

double _latToMeters(double latitude) =>
    toRadians(latitude) * _earthRadiusMeters;

double _lonToMeters(double longitude, double latRefRad) {
  return toRadians(longitude) * _earthRadiusMeters * math.cos(latRefRad);
}
