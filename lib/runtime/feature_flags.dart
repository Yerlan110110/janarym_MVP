import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class RuntimeFeatureFlags {
  RuntimeFeatureFlags._({
    required this.alwaysDialogMode,
    required this.requireWakeWord,
    required this.wakeReplyEnabled,
    required this.aggressiveBackgroundCamera,
    required this.reflexEnabled,
    required this.fullAuto,
    required this.mostlySilentNarration,
    required this.safetyEnabled,
    required this.navigationEnabled,
    required this.shoppingEnabled,
    required this.cookingEnabled,
    required this.dressCodeEnabled,
    required this.antiFraudEnabled,
    required this.textReaderEnabled,
    required this.memoryEnabled,
    required this.findEnabled,
    required this.sceneMemoryEnabled,
    required this.contextTurns,
    required this.releaseStage,
    required this.developerDiagnosticsEnabled,
  });

  final bool alwaysDialogMode;
  final bool requireWakeWord;
  final bool wakeReplyEnabled;
  final bool aggressiveBackgroundCamera;
  final bool reflexEnabled;
  final bool fullAuto;
  final bool mostlySilentNarration;
  final bool safetyEnabled;
  final bool navigationEnabled;
  final bool shoppingEnabled;
  final bool cookingEnabled;
  final bool dressCodeEnabled;
  final bool antiFraudEnabled;
  final bool textReaderEnabled;
  final bool memoryEnabled;
  final bool findEnabled;
  final bool sceneMemoryEnabled;
  final int contextTurns;
  final String releaseStage;
  final bool developerDiagnosticsEnabled;

  static RuntimeFeatureFlags fromEnv() {
    return RuntimeFeatureFlags._(
      alwaysDialogMode: _readBool('ALWAYS_DIALOG_MODE', fallback: true),
      requireWakeWord: _readBool('ASSISTANT_REQUIRE_WAKE_WORD', fallback: true),
      wakeReplyEnabled: _readBool(
        'ASSISTANT_WAKE_REPLY_ENABLED',
        fallback: true,
      ),
      aggressiveBackgroundCamera:
          !kReleaseMode &&
          _readBool('AGGRESSIVE_BACKGROUND_CAMERA', fallback: false),
      reflexEnabled: _readBool('REFLEX_ENABLED', fallback: true),
      fullAuto: _readBool('JANARYM_FULL_AUTO', fallback: true),
      mostlySilentNarration: _readBool(
        'NARRATION_MOSTLY_SILENT',
        fallback: true,
      ),
      safetyEnabled: _readBool('MODE_SAFETY_ENABLED', fallback: true),
      navigationEnabled: _readBool('MODE_NAVIGATION_ENABLED', fallback: true),
      shoppingEnabled: _readBool('MODE_SHOPPING_ENABLED', fallback: false),
      cookingEnabled: _readBool('MODE_COOKING_ENABLED', fallback: false),
      dressCodeEnabled: _readBool('MODE_DRESS_CODE_ENABLED', fallback: false),
      antiFraudEnabled: _readBool('MODE_ANTI_FRAUD_ENABLED', fallback: false),
      textReaderEnabled: _readBool('MODE_TEXT_READER_ENABLED', fallback: true),
      memoryEnabled: _readBool('MODE_MEMORY_ENABLED', fallback: true),
      findEnabled: _readBool('MODE_FIND_ENABLED', fallback: true),
      sceneMemoryEnabled: _readBool('SCENE_MEMORY_ENABLED', fallback: true),
      contextTurns: _readInt(
        'DIALOG_CONTEXT_TURNS',
        fallback: 6,
        min: 0,
        max: 20,
      ),
      releaseStage: _readString(
        'JANARYM_RELEASE_STAGE',
        fallback: 'R1',
      ).toUpperCase(),
      developerDiagnosticsEnabled:
          !kReleaseMode &&
          _readBool('DEV_DIAGNOSTICS_ENABLED', fallback: kDebugMode),
    );
  }

  List<String> enabledModes() {
    final result = <String>['home'];
    if (navigationEnabled) result.add('navigation');
    if (shoppingEnabled) result.add('shopping');
    if (cookingEnabled) result.add('cooking');
    if (dressCodeEnabled) result.add('dress_code');
    if (antiFraudEnabled) result.add('anti_fraud');
    if (textReaderEnabled) result.add('text_reader');
    if (memoryEnabled) result.add('memory');
    if (findEnabled) result.add('find');
    return result;
  }

  static bool _readBool(String key, {required bool fallback}) {
    final raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    if (raw.isEmpty) return fallback;
    if (raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on') return true;
    if (raw == '0' || raw == 'false' || raw == 'no' || raw == 'off') {
      return false;
    }
    return fallback;
  }

  static int _readInt(String key, {required int fallback, int? min, int? max}) {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null) return fallback;
    var result = parsed;
    if (min != null && result < min) result = min;
    if (max != null && result > max) result = max;
    return result;
  }

  static String _readString(String key, {required String fallback}) {
    final raw = (dotenv.env[key] ?? '').trim();
    return raw.isEmpty ? fallback : raw;
  }
}
