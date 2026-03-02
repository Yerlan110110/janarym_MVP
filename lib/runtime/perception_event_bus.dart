import 'dart:async';

class BoundingBox {
  const BoundingBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

enum PerceptionEventType {
  detection,
  hazard,
  handGuidance,
  store,
  textRead,
  system,
}

class PerceptionEvent {
  const PerceptionEvent({
    required this.id,
    required this.type,
    required this.timestampMs,
    required this.confidence,
    this.bbox,
    this.label,
    this.distanceM,
    this.meta = const <String, Object?>{},
  });

  final String id;
  final PerceptionEventType type;
  final int timestampMs;
  final double confidence;
  final BoundingBox? bbox;
  final String? label;
  final double? distanceM;
  final Map<String, Object?> meta;
}

class HazardAssessment {
  const HazardAssessment({
    required this.hazardType,
    required this.severity,
    required this.direction,
    required this.distanceM,
    required this.recommendedAction,
  });

  final String hazardType;
  final String severity;
  final String direction;
  final double distanceM;
  final String recommendedAction;
}

class HandGuidanceEvent {
  const HandGuidanceEvent({
    required this.stepId,
    required this.instruction,
    required this.handOffsetCm,
    this.safetyNotes,
  });

  final String stepId;
  final String instruction;
  final double handOffsetCm;
  final String? safetyNotes;
}

class StoreEvent {
  const StoreEvent({
    required this.storeId,
    required this.action,
    this.payload = const <String, Object?>{},
  });

  final String storeId;
  final String action;
  final Map<String, Object?> payload;
}

class TextReadEvent {
  const TextReadEvent({
    required this.kind,
    required this.text,
    this.price,
    this.calories,
  });

  final String kind;
  final String text;
  final double? price;
  final int? calories;
}

class PerceptionEventBus {
  final StreamController<PerceptionEvent> _controller =
      StreamController<PerceptionEvent>.broadcast();

  Stream<PerceptionEvent> get stream => _controller.stream;

  Stream<PerceptionEvent> byType(PerceptionEventType type) {
    return _controller.stream.where((event) => event.type == type);
  }

  void publish(PerceptionEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
