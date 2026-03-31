import '../runtime/mode_orchestrator.dart';

class VisionPromptContextBuilder {
  const VisionPromptContextBuilder._();

  static bool shouldExposeHazardContext(ModePerceptionFilter perception) {
    return perception.reflexPriority || perception.safetyMax;
  }

  static Map<String, Object?> buildPerceptionSnapshot({
    required ModeDescriptor descriptor,
    required String modeSubState,
    required bool cameraStreaming,
    required DateTime? frameAt,
    required String latestHazardHint,
    required String safetyLevel,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final includeHazardContext = shouldExposeHazardContext(
      descriptor.perception,
    );
    final hazardHint = latestHazardHint.trim();
    return <String, Object?>{
      'mode': descriptor.contextKey,
      'mode_sub_state': modeSubState,
      'camera_streaming': cameraStreaming,
      'frame_age_ms': frameAt == null
          ? null
          : effectiveNow.difference(frameAt).inMilliseconds,
      'hazard_hint': includeHazardContext && hazardHint.isNotEmpty
          ? hazardHint
          : null,
      'safety_level': safetyLevel,
      'perception_filters': _buildPerceptionFilters(
        descriptor.perception,
        includeHazardContext: includeHazardContext,
      ),
    };
  }

  static String buildSceneSummary({
    required ModeDescriptor descriptor,
    required String modeSubState,
    required bool cameraStreaming,
    required DateTime? frameAt,
    required String latestHazardHint,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final includeHazardContext = shouldExposeHazardContext(
      descriptor.perception,
    );
    final focus = _buildFocus(
      descriptor.perception,
      includeHazardContext: includeHazardContext,
    );
    final hazardHint = latestHazardHint.trim();
    final frameAgeMs = frameAt == null
        ? 'unknown'
        : effectiveNow.difference(frameAt).inMilliseconds.toString();
    final parts = <String>[
      'mode=${descriptor.contextKey}',
      'sub_state=$modeSubState',
      'camera=${cameraStreaming ? 'on' : 'off'}',
      'frame_age_ms=$frameAgeMs',
      if (includeHazardContext && hazardHint.isNotEmpty) 'hazard=$hazardHint',
      if (focus.isNotEmpty) 'focus=${focus.join(',')}',
    ];
    return parts.join(', ');
  }

  static Map<String, Object?> _buildPerceptionFilters(
    ModePerceptionFilter perception, {
    required bool includeHazardContext,
  }) {
    return <String, Object?>{
      'live_camera': perception.requiresLiveCamera,
      'scene_description': perception.prefersSceneDescription,
      'navigation_guidance': perception.prefersNavigationGuidance,
      'reflex_priority': perception.reflexPriority,
      'safety_max': perception.safetyMax,
      'auto_text_reader': perception.enableAutoTextReader,
      'ocr': perception.enableOcr,
      'weather': perception.enableWeatherContext,
      'shopping': perception.enableShoppingList,
      'cooking': perception.enableCookingGuidance,
      'currency_check': perception.enableCurrencyCheck,
      'scene_memory': perception.enableSceneMemory,
      'object_search': perception.enableObjectSearch,
      'hazard_overlay': perception.showHazardOverlay,
      'hazard_voice': perception.allowHazardVoice,
      'hazard_focus': includeHazardContext
          ? perception.hazardLabelsOfInterest.toList(growable: false)
          : const <String>[],
      'ocr_focus': perception.ocrFocus.toList(growable: false),
    };
  }

  static List<String> _buildFocus(
    ModePerceptionFilter perception, {
    required bool includeHazardContext,
  }) {
    final result = <String>[];
    if (includeHazardContext) {
      result.addAll(perception.hazardLabelsOfInterest);
    }
    result.addAll(perception.ocrFocus);
    return result;
  }
}
