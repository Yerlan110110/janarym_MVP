import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/runtime/mode_orchestrator.dart';
import 'package:janarym_app2/services/vision_prompt_context.dart';

ModeDescriptor _descriptor({
  required String contextKey,
  required ModePerceptionFilter perception,
}) {
  return ModeDescriptor(
    mode: JanarymMode.home,
    contextKey: contextKey,
    ui: const ModeUiIndicator(
      labelRu: 'Тест',
      labelKk: 'Тест',
      shortRu: 'Тест',
      shortKk: 'Тест',
      icon: Icons.home_rounded,
      accentColor: Colors.blue,
    ),
    perception: perception,
    prompts: const ModePromptProfile(
      blindRu: 'blind',
      blindKk: 'blind',
      visionRu: 'vision',
      visionKk: 'vision',
    ),
  );
}

void main() {
  group('VisionPromptContextBuilder', () {
    final now = DateTime(2026, 3, 30, 12, 0, 0);
    final frameAt = now.subtract(const Duration(milliseconds: 420));

    test('hides noisy hazard hints in home scene descriptions', () {
      final descriptor = _descriptor(
        contextKey: 'home',
        perception: const ModePerceptionFilter(
          prefersSceneDescription: true,
          hazardLabelsOfInterest: <String>{'car', 'bike'},
        ),
      );

      final snapshot = VisionPromptContextBuilder.buildPerceptionSnapshot(
        descriptor: descriptor,
        modeSubState: 'idle',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        safetyLevel: 'normal',
        now: now,
      );
      final filters = snapshot['perception_filters']! as Map<String, Object?>;
      final summary = VisionPromptContextBuilder.buildSceneSummary(
        descriptor: descriptor,
        modeSubState: 'idle',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        now: now,
      );

      expect(snapshot['hazard_hint'], isNull);
      expect(filters['hazard_focus'], isEmpty);
      expect(summary, isNot(contains('hazard=машина')));
      expect(summary, isNot(contains('car')));
      expect(summary, isNot(contains('bike')));
    });

    test('keeps hazard context in safety-critical modes', () {
      final descriptor = _descriptor(
        contextKey: 'safety',
        perception: const ModePerceptionFilter(
          reflexPriority: true,
          safetyMax: true,
          hazardLabelsOfInterest: <String>{'car', 'bike'},
        ),
      );

      final snapshot = VisionPromptContextBuilder.buildPerceptionSnapshot(
        descriptor: descriptor,
        modeSubState: 'active',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        safetyLevel: 'max',
        now: now,
      );
      final filters = snapshot['perception_filters']! as Map<String, Object?>;
      final summary = VisionPromptContextBuilder.buildSceneSummary(
        descriptor: descriptor,
        modeSubState: 'active',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        now: now,
      );

      expect(snapshot['hazard_hint'], 'машина');
      expect(filters['hazard_focus'], containsAll(<String>['car', 'bike']));
      expect(summary, contains('hazard=машина'));
      expect(summary, contains('car'));
      expect(summary, contains('bike'));
    });

    test('preserves OCR focus without leaking hazard labels', () {
      final descriptor = _descriptor(
        contextKey: 'text_reader',
        perception: const ModePerceptionFilter(
          enableOcr: true,
          ocrFocus: <String>{'price', 'full_text'},
          hazardLabelsOfInterest: <String>{'car'},
        ),
      );

      final snapshot = VisionPromptContextBuilder.buildPerceptionSnapshot(
        descriptor: descriptor,
        modeSubState: 'idle',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        safetyLevel: 'normal',
        now: now,
      );
      final filters = snapshot['perception_filters']! as Map<String, Object?>;
      final summary = VisionPromptContextBuilder.buildSceneSummary(
        descriptor: descriptor,
        modeSubState: 'idle',
        cameraStreaming: true,
        frameAt: frameAt,
        latestHazardHint: 'машина',
        now: now,
      );

      expect(snapshot['hazard_hint'], isNull);
      expect(filters['hazard_focus'], isEmpty);
      expect(filters['ocr_focus'], containsAll(<String>['price', 'full_text']));
      expect(summary, contains('price'));
      expect(summary, contains('full_text'));
      expect(summary, isNot(contains('car')));
    });
  });
}
