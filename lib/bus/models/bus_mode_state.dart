import '../../navigation/models/transit_models.dart';

enum BusModeStatus { idle, awaitingChoice, error }

class BusModeState {
  const BusModeState({
    required this.modeEnabled,
    required this.status,
    this.candidates = const [],
    this.lastInstruction,
    this.error,
    this.currentLocation,
  });

  final bool modeEnabled;
  final BusModeStatus status;
  final List<TransitStopCandidate> candidates;
  final String? lastInstruction;
  final String? error;
  final NavPoint? currentLocation;

  static const initial = BusModeState(
    modeEnabled: false,
    status: BusModeStatus.idle,
  );

  BusModeState copyWith({
    bool? modeEnabled,
    BusModeStatus? status,
    List<TransitStopCandidate>? candidates,
    String? lastInstruction,
    bool clearLastInstruction = false,
    String? error,
    bool clearError = false,
    NavPoint? currentLocation,
    bool clearCurrentLocation = false,
  }) {
    return BusModeState(
      modeEnabled: modeEnabled ?? this.modeEnabled,
      status: status ?? this.status,
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
