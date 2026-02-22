import 'package:geolocator/geolocator.dart';

import '../models/navigation_mode_state.dart';

abstract class NavigationLocationProvider {
  Future<bool> ensurePermission();
  Future<NavPoint> getCurrentLocation();
  Stream<NavPoint> positionStream();
}

class GeolocatorNavigationLocationProvider
    implements NavigationLocationProvider {
  const GeolocatorNavigationLocationProvider();

  @override
  Future<bool> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  @override
  Future<NavPoint> getCurrentLocation() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
      ),
    );
    return NavPoint(latitude: position.latitude, longitude: position.longitude);
  }

  @override
  Stream<NavPoint> positionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 4,
      ),
    ).map((position) {
      return NavPoint(
        latitude: position.latitude,
        longitude: position.longitude,
      );
    });
  }
}
