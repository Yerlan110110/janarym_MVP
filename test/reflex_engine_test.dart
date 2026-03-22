import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/reflex/reflex_engine.dart';
import 'package:janarym_app2/runtime/perception_event_bus.dart';

void main() {
  ReflexDetection detection({
    required String label,
    required double confidence,
    required double distanceM,
  }) {
    return ReflexDetection(
      trackId: 1,
      hazardLabel: label,
      sourceLabel: label,
      bbox: const BoundingBox(left: 0.3, top: 0.2, width: 0.3, height: 0.4),
      confidence: confidence,
      distanceM: distanceM,
      severity: ReflexSeverity.high,
      growthRate: 0.4,
      direction: 'center',
      recommendedAction: 'step_back',
    );
  }

  group('ReflexEngine.shouldEmitVoiceAlert', () {
    test('requires three high-confidence frames in normal mode', () {
      final candidate = detection(
        label: 'car',
        confidence: 0.8,
        distanceM: 1.9,
      );

      expect(
        ReflexEngine.shouldEmitVoiceAlert(
          detection: candidate,
          consecutiveHighFrames: 2,
          safetyLevel: ReflexSafetyLevel.normal,
        ),
        isFalse,
      );
      expect(
        ReflexEngine.shouldEmitVoiceAlert(
          detection: candidate,
          consecutiveHighFrames: 3,
          safetyLevel: ReflexSafetyLevel.normal,
        ),
        isTrue,
      );
    });

    test('allows faster confirmation in max safety mode', () {
      final candidate = detection(
        label: 'bike',
        confidence: 0.7,
        distanceM: 1.8,
      );

      expect(
        ReflexEngine.shouldEmitVoiceAlert(
          detection: candidate,
          consecutiveHighFrames: 2,
          safetyLevel: ReflexSafetyLevel.max,
        ),
        isTrue,
      );
    });

    test('blocks low-confidence alerts even after confirmation', () {
      final candidate = detection(
        label: 'car',
        confidence: 0.5,
        distanceM: 1.6,
      );

      expect(
        ReflexEngine.shouldEmitVoiceAlert(
          detection: candidate,
          consecutiveHighFrames: 4,
          safetyLevel: ReflexSafetyLevel.normal,
        ),
        isFalse,
      );
    });

    test('blocks alerts that are still too far away', () {
      final candidate = detection(
        label: 'car',
        confidence: 0.85,
        distanceM: 3.4,
      );

      expect(
        ReflexEngine.shouldEmitVoiceAlert(
          detection: candidate,
          consecutiveHighFrames: 4,
          safetyLevel: ReflexSafetyLevel.normal,
        ),
        isFalse,
      );
    });
  });
}
