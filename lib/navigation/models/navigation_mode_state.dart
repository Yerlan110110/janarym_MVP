enum NavigationStatus {
  idle,
  resolvingDestination,
  awaitingChoice,
  buildingRoute,
  navigating,
  rerouting,
  completed,
  error,
}

class NavPoint {
  final double latitude;
  final double longitude;

  const NavPoint({required this.latitude, required this.longitude});

  @override
  String toString() => '($latitude,$longitude)';
}

class DestinationCandidate {
  final String title;
  final String subtitle;
  final NavPoint point;

  const DestinationCandidate({
    required this.title,
    required this.subtitle,
    required this.point,
  });

  String get displayLabel => subtitle.trim().isEmpty ? title : subtitle;
}

enum NavManeuverType { straight, turnLeft, turnRight, uTurn, arrive }

class NavStep {
  final int index;
  final int polylineIndex;
  final NavManeuverType maneuverType;
  final String instruction;
  final double distanceFromRouteStartMeters;

  const NavStep({
    required this.index,
    required this.polylineIndex,
    required this.maneuverType,
    required this.instruction,
    required this.distanceFromRouteStartMeters,
  });
}

class ActiveRoute {
  final DestinationCandidate destination;
  final List<NavPoint> polyline;
  final List<NavStep> steps;
  final double totalDistanceMeters;
  final Duration estimatedDuration;
  final int currentStepIndex;
  final int? announcedStepIndex;

  const ActiveRoute({
    required this.destination,
    required this.polyline,
    required this.steps,
    required this.totalDistanceMeters,
    required this.estimatedDuration,
    this.currentStepIndex = 0,
    this.announcedStepIndex,
  });

  ActiveRoute copyWith({
    DestinationCandidate? destination,
    List<NavPoint>? polyline,
    List<NavStep>? steps,
    double? totalDistanceMeters,
    Duration? estimatedDuration,
    int? currentStepIndex,
    int? announcedStepIndex,
  }) {
    return ActiveRoute(
      destination: destination ?? this.destination,
      polyline: polyline ?? this.polyline,
      steps: steps ?? this.steps,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
      announcedStepIndex: announcedStepIndex ?? this.announcedStepIndex,
    );
  }
}

class NavigationModeState {
  final bool modeEnabled;
  final NavigationStatus navStatus;
  final ActiveRoute? activeRoute;
  final List<DestinationCandidate> candidates;
  final String? lastInstruction;
  final String? error;
  final NavPoint? currentLocation;

  const NavigationModeState({
    required this.modeEnabled,
    required this.navStatus,
    this.activeRoute,
    this.candidates = const [],
    this.lastInstruction,
    this.error,
    this.currentLocation,
  });

  static const initial = NavigationModeState(
    modeEnabled: false,
    navStatus: NavigationStatus.idle,
  );

  NavigationModeState copyWith({
    bool? modeEnabled,
    NavigationStatus? navStatus,
    ActiveRoute? activeRoute,
    bool clearActiveRoute = false,
    List<DestinationCandidate>? candidates,
    String? lastInstruction,
    bool clearLastInstruction = false,
    String? error,
    bool clearError = false,
    NavPoint? currentLocation,
    bool clearCurrentLocation = false,
  }) {
    return NavigationModeState(
      modeEnabled: modeEnabled ?? this.modeEnabled,
      navStatus: navStatus ?? this.navStatus,
      activeRoute: clearActiveRoute ? null : (activeRoute ?? this.activeRoute),
      candidates: candidates ?? this.candidates,
      lastInstruction: clearLastInstruction
          ? null
          : (lastInstruction ?? this.lastInstruction),
      error: clearError ? null : (error ?? this.error),
      currentLocation: clearCurrentLocation
          ? null
          : (currentLocation ?? this.currentLocation),
    );
  }
}
