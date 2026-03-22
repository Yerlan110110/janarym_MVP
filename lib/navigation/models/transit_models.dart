enum TransitScheduleSourceType { precise, periodic }

class NavPoint {
  final double latitude;
  final double longitude;

  const NavPoint({required this.latitude, required this.longitude});

  @override
  String toString() => '($latitude,$longitude)';
}

class TransitRouteSummary {
  const TransitRouteSummary({
    required this.routeId,
    required this.displayName,
    this.transportType = '',
    this.directionLabels = const [],
  });

  final String routeId;
  final String displayName;
  final String transportType;
  final List<String> directionLabels;
}

class TransitScheduleEntry {
  const TransitScheduleEntry({
    required this.routeName,
    required this.destinationLabel,
    required this.exactTimes,
    required this.intervalMinutes,
    required this.sourceType,
  });

  final String routeName;
  final String destinationLabel;
  final List<String> exactTimes;
  final int? intervalMinutes;
  final TransitScheduleSourceType sourceType;
}

class TransitStopCandidate {
  const TransitStopCandidate({
    required this.id,
    this.stationId,
    required this.platformIds,
    required this.title,
    required this.subtitle,
    required this.point,
    required this.routes,
    this.isPlatformLevel = false,
  });

  final String id;
  final String? stationId;
  final List<String> platformIds;
  final String title;
  final String subtitle;
  final NavPoint point;
  final List<TransitRouteSummary> routes;
  final bool isPlatformLevel;
}
