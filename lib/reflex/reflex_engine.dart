import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../runtime/app_log.dart';
import '../runtime/perception_event_bus.dart';
import '../services/camera_frame_service.dart';

typedef ReflexCaptureFrame = Future<CameraFrameSnapshot?> Function();
typedef ReflexOverlayListener = void Function(List<ReflexDetection> detections);
typedef ReflexAlertHandler = Future<void> Function(ReflexAlert alert);

enum ReflexSeverity { safe, medium, high }

enum ReflexSafetyLevel { normal, max }

class ReflexRuntimeMetrics {
  const ReflexRuntimeMetrics({
    required this.detections,
    required this.inferenceLatencyMs,
  });

  final int detections;
  final int inferenceLatencyMs;
}

class ReflexDetection {
  const ReflexDetection({
    required this.trackId,
    required this.hazardLabel,
    required this.sourceLabel,
    required this.bbox,
    required this.confidence,
    required this.distanceM,
    required this.severity,
    required this.growthRate,
    required this.direction,
    required this.recommendedAction,
  });

  final int trackId;
  final String hazardLabel;
  final String sourceLabel;
  final BoundingBox bbox;
  final double confidence;
  final double distanceM;
  final ReflexSeverity severity;
  final double growthRate;
  final String direction;
  final String recommendedAction;
}

class ReflexAlert {
  const ReflexAlert({
    required this.trackId,
    required this.hazardLabel,
    required this.direction,
    required this.recommendedAction,
    required this.distanceM,
    required this.severity,
  });

  final int trackId;
  final String hazardLabel;
  final String direction;
  final String recommendedAction;
  final double distanceM;
  final ReflexSeverity severity;
}

class ReflexEngine {
  ReflexEngine({
    required PerceptionEventBus eventBus,
    required ReflexCaptureFrame captureLatestFrame,
    required ReflexOverlayListener onOverlayChanged,
    required ReflexAlertHandler onAlert,
    this.onMetrics,
    bool enabled = true,
    Duration interval = const Duration(milliseconds: 500),
    int alertCooldownMs = 2000,
  }) : _eventBus = eventBus,
       _captureLatestFrame = captureLatestFrame,
       _onOverlayChanged = onOverlayChanged,
       _onAlert = onAlert,
       _enabled = enabled,
       _normalInterval = interval,
       _alertCooldownMs = alertCooldownMs;

  static const MethodChannel _channel = MethodChannel(
    'janarym/reflex_detector',
  );
  static const int _trackRetentionMs = 1800;

  final PerceptionEventBus _eventBus;
  final ReflexCaptureFrame _captureLatestFrame;
  final ReflexOverlayListener _onOverlayChanged;
  final ReflexAlertHandler _onAlert;
  final ValueChanged<ReflexRuntimeMetrics>? onMetrics;
  final bool _enabled;
  final Duration _normalInterval;
  final int _alertCooldownMs;
  final Duration _maxInterval = const Duration(milliseconds: 400);
  final Duration _voicePriorityInterval = const Duration(milliseconds: 1400);

  final Map<int, _ReflexTrack> _tracks = <int, _ReflexTrack>{};

  Timer? _timer;
  bool _initialized = false;
  bool _running = false;
  bool _busy = false;
  int _nextTrackId = 1;
  ReflexSafetyLevel _safetyLevel = ReflexSafetyLevel.normal;
  bool _voicePriority = false;

  Future<void> initialize() async {
    if (_initialized || !_enabled) return;
    await _channel.invokeMethod<bool>('initialize', <String, Object?>{
      'scoreThreshold': 0.22,
      'maxResults': 8,
    });
    _initialized = true;
  }

  Future<void> start() async {
    if (!_enabled || _running) return;
    await initialize();
    _running = true;
    _restartTimer();
    unawaited(_processTick());
  }

  Future<void> setSafetyLevel(ReflexSafetyLevel level) async {
    if (_safetyLevel == level) return;
    _safetyLevel = level;
    if (_running) {
      _restartTimer();
      unawaited(_processTick());
    }
  }

  Future<void> setVoicePriority(bool enabled) async {
    if (_voicePriority == enabled) return;
    _voicePriority = enabled;
    if (_running) {
      _restartTimer();
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _tracks.clear();
    _onOverlayChanged(const <ReflexDetection>[]);
  }

  Future<void> dispose() async {
    await stop();
    if (_initialized) {
      try {
        await _channel.invokeMethod<bool>('dispose');
      } catch (_) {}
    }
    _initialized = false;
  }

  Future<void> _processTick() async {
    if (!_running || _busy) return;
    _busy = true;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      final frame = await _captureLatestFrame();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (frame == null || frame.nv21Bytes.isEmpty) {
        _pruneTracks(now);
        if (_tracks.isEmpty) {
          _onOverlayChanged(const <ReflexDetection>[]);
        }
        return;
      }

      final nativeRaw = await _detectNative(frame);
      final candidates = _mapNativeCandidates(nativeRaw);
      appLog('[Reflex] detections=${candidates.length}');

      final detections = _trackAndScore(candidates, now);
      _onOverlayChanged(detections);
      onMetrics?.call(
        ReflexRuntimeMetrics(
          detections: detections.length,
          inferenceLatencyMs: DateTime.now().millisecondsSinceEpoch - startedAt,
        ),
      );
      await _emitAlerts(detections, now);
    } finally {
      _busy = false;
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_effectiveInterval, (_) {
      unawaited(_processTick());
    });
  }

  Duration get _effectiveInterval => _voicePriority
      ? _voicePriorityInterval
      : (_safetyLevel == ReflexSafetyLevel.max
            ? _maxInterval
            : _normalInterval);

  Future<List<dynamic>> _detectNative(CameraFrameSnapshot frame) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'detect',
      <String, Object?>{
        'nv21Bytes': frame.nv21Bytes,
        'width': frame.width,
        'height': frame.height,
      },
    );
    return raw ?? const <dynamic>[];
  }

  List<_NativeDetection> _mapNativeCandidates(List<dynamic> raw) {
    final result = <_NativeDetection>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final sourceLabel = (item['label'] as String? ?? '').trim().toLowerCase();
      if (sourceLabel.isEmpty) continue;
      final hazardLabel = _normalizeHazardLabel(sourceLabel) ?? sourceLabel;
      final score = _readDouble(item['score']);
      if (!_passesClassThreshold(hazardLabel, score)) continue;
      final bbox = BoundingBox(
        left: _readDouble(item['left']).clamp(0, 1),
        top: _readDouble(item['top']).clamp(0, 1),
        width: _readDouble(item['width']).clamp(0, 1),
        height: _readDouble(item['height']).clamp(0, 1),
      );
      if (bbox.width <= 0.02 || bbox.height <= 0.02) continue;
      result.add(
        _NativeDetection(
          hazardLabel: hazardLabel,
          sourceLabel: sourceLabel,
          score: score,
          bbox: bbox,
        ),
      );
    }
    return result;
  }

  List<ReflexDetection> _trackAndScore(
    List<_NativeDetection> candidates,
    int now,
  ) {
    final result = <ReflexDetection>[];
    final matchedTrackIds = <int>{};

    for (final candidate in candidates) {
      final trackId = _matchOrCreateTrack(candidate, now);
      matchedTrackIds.add(trackId);
      final track = _tracks[trackId]!;
      final smoothedBox = _smoothBoundingBox(track.bbox, candidate.bbox);
      final area = smoothedBox.width * smoothedBox.height;
      final previousArea = track.lastArea <= 0 ? area : track.lastArea;
      final dtMs = math.max(120, now - track.lastSeenAtMs);
      final growthRate =
          ((area - previousArea) / math.max(previousArea, 0.0001)) /
          (dtMs / 1000.0);
      final distanceM = _estimateDistanceMeters(
        candidate.hazardLabel,
        smoothedBox,
      );
      final direction = _directionFromBox(smoothedBox);
      final recommendedAction = _recommendedAction(direction);
      final severity = _severityForDetection(
        label: candidate.hazardLabel,
        distanceM: distanceM,
        growthRate: growthRate,
        direction: direction,
      );

      track
        ..bbox = smoothedBox
        ..lastArea = area
        ..lastSeenAtMs = now
        ..confidence = candidate.score
        ..hazardLabel = candidate.hazardLabel
        ..sourceLabel = candidate.sourceLabel
        ..distanceM = distanceM
        ..growthRate = growthRate
        ..severity = severity
        ..direction = direction
        ..recommendedAction = recommendedAction;

      result.add(
        ReflexDetection(
          trackId: trackId,
          hazardLabel: candidate.hazardLabel,
          sourceLabel: candidate.sourceLabel,
          bbox: smoothedBox,
          confidence: candidate.score,
          distanceM: distanceM,
          severity: severity,
          growthRate: growthRate,
          direction: direction,
          recommendedAction: recommendedAction,
        ),
      );
    }

    _pruneTracks(now, keepIds: matchedTrackIds);
    result.sort((a, b) {
      final severityOrder =
          _severityWeight(b.severity) - _severityWeight(a.severity);
      if (severityOrder != 0) return severityOrder;
      return b.confidence.compareTo(a.confidence);
    });
    return result;
  }

  int _matchOrCreateTrack(_NativeDetection candidate, int now) {
    int? bestTrackId;
    double bestIou = 0;
    for (final entry in _tracks.entries) {
      final track = entry.value;
      if (track.hazardLabel != candidate.hazardLabel) continue;
      if (now - track.lastSeenAtMs > _trackRetentionMs) continue;
      final iou = _bboxIou(track.bbox, candidate.bbox);
      if (iou > 0.2 && iou > bestIou) {
        bestIou = iou;
        bestTrackId = entry.key;
      }
    }
    if (bestTrackId != null) {
      return bestTrackId;
    }
    final trackId = _nextTrackId++;
    _tracks[trackId] = _ReflexTrack(
      bbox: candidate.bbox,
      lastArea: candidate.bbox.width * candidate.bbox.height,
      lastSeenAtMs: now,
      confidence: candidate.score,
      hazardLabel: candidate.hazardLabel,
      sourceLabel: candidate.sourceLabel,
    );
    return trackId;
  }

  Future<void> _emitAlerts(List<ReflexDetection> detections, int now) async {
    ReflexDetection? topAlert;
    for (final detection in detections) {
      if (detection.severity != ReflexSeverity.high) continue;
      final track = _tracks[detection.trackId];
      if (track == null) continue;
      if (now - track.lastAlertAtMs < _alertCooldownMs) continue;
      topAlert = detection;
      track.lastAlertAtMs = now;
      break;
    }
    if (topAlert == null) return;

    _eventBus.publish(
      PerceptionEvent(
        id: 'reflex_${topAlert.trackId}_$now',
        type: PerceptionEventType.hazard,
        timestampMs: now,
        confidence: topAlert.confidence,
        label: topAlert.hazardLabel,
        distanceM: topAlert.distanceM,
        bbox: topAlert.bbox,
        meta: <String, Object?>{
          'source': 'reflex_engine',
          'severity': topAlert.severity.name,
          'direction': topAlert.direction,
          'recommended_action': topAlert.recommendedAction,
          'track_id': topAlert.trackId,
          'growth_rate': double.parse(topAlert.growthRate.toStringAsFixed(3)),
        },
      ),
    );
    await _onAlert(
      ReflexAlert(
        trackId: topAlert.trackId,
        hazardLabel: topAlert.hazardLabel,
        direction: topAlert.direction,
        recommendedAction: topAlert.recommendedAction,
        distanceM: topAlert.distanceM,
        severity: topAlert.severity,
      ),
    );
  }

  void _pruneTracks(int now, {Set<int> keepIds = const <int>{}}) {
    final staleIds = <int>[];
    for (final entry in _tracks.entries) {
      if (keepIds.contains(entry.key)) continue;
      if (now - entry.value.lastSeenAtMs > _trackRetentionMs) {
        staleIds.add(entry.key);
      }
    }
    for (final id in staleIds) {
      _tracks.remove(id);
    }
  }

  BoundingBox _smoothBoundingBox(BoundingBox previous, BoundingBox next) {
    const alpha = 0.38;
    return BoundingBox(
      left: previous.left + (next.left - previous.left) * alpha,
      top: previous.top + (next.top - previous.top) * alpha,
      width: previous.width + (next.width - previous.width) * alpha,
      height: previous.height + (next.height - previous.height) * alpha,
    );
  }

  double _estimateDistanceMeters(String label, BoundingBox bbox) {
    final scale = math.max(
      bbox.height,
      math.sqrt((bbox.width * bbox.height).clamp(0.0001, 1.0)),
    );
    const calibration = <String, double>{
      'car': 0.90,
      'bike': 0.78,
      'hot_surface': 0.70,
      'sharp_object': 0.18,
    };
    final k = calibration[label] ?? 0.75;
    return (k / scale.clamp(0.08, 1.0)).clamp(0.25, 8.0);
  }

  ReflexSeverity _severityForDetection({
    required String label,
    required double distanceM,
    required double growthRate,
    required String direction,
  }) {
    if (!_isHazardLabel(label)) {
      return ReflexSeverity.safe;
    }
    final critical = <String, double>{
      'car': 1.4,
      'bike': 1.1,
      'hot_surface': 0.9,
      'sharp_object': 0.45,
    };
    final close = <String, double>{
      'car': 2.2,
      'bike': 1.8,
      'hot_surface': 1.3,
      'sharp_object': 0.75,
    };
    final warn = <String, double>{
      'car': 3.6,
      'bike': 3.0,
      'hot_surface': 2.0,
      'sharp_object': 1.2,
    };
    final fastGrowth = <String, double>{
      'car': 0.40,
      'bike': 0.34,
      'hot_surface': 0.16,
      'sharp_object': 0.08,
    };
    final distanceBoost = _safetyLevel == ReflexSafetyLevel.max ? 1.18 : 1.0;
    final growthRelax = _safetyLevel == ReflexSafetyLevel.max ? 0.82 : 1.0;
    if (distanceM <= ((critical[label] ?? 0.9) * distanceBoost)) {
      return ReflexSeverity.high;
    }
    if (distanceM <= ((close[label] ?? 1.4) * distanceBoost) &&
        (growthRate >= ((fastGrowth[label] ?? 0.2) * growthRelax) ||
            direction == 'center')) {
      return ReflexSeverity.high;
    }
    if (distanceM <= ((warn[label] ?? 2.0) * distanceBoost) ||
        growthRate >= ((fastGrowth[label] ?? 0.2) * 0.75 * growthRelax)) {
      return ReflexSeverity.medium;
    }
    return ReflexSeverity.safe;
  }

  String _directionFromBox(BoundingBox bbox) {
    final centerX = bbox.left + bbox.width / 2;
    if (centerX < 0.38) return 'left';
    if (centerX > 0.62) return 'right';
    return 'center';
  }

  String _recommendedAction(String direction) {
    switch (direction) {
      case 'left':
        return 'step_right';
      case 'right':
        return 'step_left';
      case 'center':
      default:
        return 'step_back';
    }
  }

  int _severityWeight(ReflexSeverity severity) {
    switch (severity) {
      case ReflexSeverity.high:
        return 3;
      case ReflexSeverity.medium:
        return 2;
      case ReflexSeverity.safe:
        return 1;
    }
  }

  String? _normalizeHazardLabel(String rawLabel) {
    switch (rawLabel) {
      case 'car':
      case 'truck':
      case 'bus':
        return 'car';
      case 'bicycle':
      case 'motorcycle':
        return 'bike';
      case 'oven':
      case 'toaster':
        return 'hot_surface';
      case 'knife':
      case 'scissors':
        return 'sharp_object';
      default:
        return null;
    }
  }

  bool _isHazardLabel(String label) {
    switch (label) {
      case 'car':
      case 'bike':
      case 'hot_surface':
      case 'sharp_object':
      case 'stairs_edge':
        return true;
      default:
        return false;
    }
  }

  bool _passesClassThreshold(String label, double score) {
    final thresholds = <String, double>{
      'car': 0.42,
      'bike': 0.34,
      'hot_surface': 0.28,
      'sharp_object': 0.24,
    };
    return score >= (thresholds[label] ?? 0.20);
  }

  double _bboxIou(BoundingBox a, BoundingBox b) {
    final left = math.max(a.left, b.left);
    final top = math.max(a.top, b.top);
    final right = math.min(a.left + a.width, b.left + b.width);
    final bottom = math.min(a.top + a.height, b.top + b.height);
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return 0;
    final intersection = width * height;
    final union = a.width * a.height + b.width * b.height - intersection;
    if (union <= 0) return 0;
    return intersection / union;
  }

  double _readDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _NativeDetection {
  const _NativeDetection({
    required this.hazardLabel,
    required this.sourceLabel,
    required this.score,
    required this.bbox,
  });

  final String hazardLabel;
  final String sourceLabel;
  final double score;
  final BoundingBox bbox;
}

class _ReflexTrack {
  _ReflexTrack({
    required this.bbox,
    required this.lastArea,
    required this.lastSeenAtMs,
    required this.confidence,
    required this.hazardLabel,
    required this.sourceLabel,
  });

  BoundingBox bbox;
  double lastArea;
  int lastSeenAtMs;
  int lastAlertAtMs = 0;
  double confidence;
  String hazardLabel;
  String sourceLabel;
  double distanceM = 0;
  double growthRate = 0;
  ReflexSeverity severity = ReflexSeverity.safe;
  String direction = 'center';
  String recommendedAction = 'step_back';
}
