import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../runtime/app_log.dart';

enum WakeWordStatus { armed, listening, enrolling, error }

enum WakeRecallMode { balanced, maxRecall }

class WakeWordState {
  final WakeWordStatus status;
  final String? lastError;
  final String keywordMode;
  final String keywordLabel;
  final bool hasOwnerProfile;

  const WakeWordState({
    required this.status,
    required this.keywordMode,
    required this.keywordLabel,
    required this.hasOwnerProfile,
    this.lastError,
  });

  bool get isListening => status == WakeWordStatus.listening;
}

class WakeWordDebugState {
  const WakeWordDebugState({
    this.rmsDb,
    this.snrDb,
    this.vadActive = false,
    this.stage1Score,
    this.stage2Score,
    this.speakerSimilarity,
    this.wakeTemplateSimilarity,
    this.templateThreshold,
    this.minSpeechRatio,
    this.requiredStrictHits = 0,
    this.repeatRequiredStrictHits = 0,
    this.templateVerificationEnabled = false,
    this.stage2VerificationEnabled = false,
    this.ownerVerificationEnabled = false,
    this.cooldownRemainingMs = 0,
    this.reason = '',
    this.accepted = false,
  });

  final double? rmsDb;
  final double? snrDb;
  final bool vadActive;
  final double? stage1Score;
  final double? stage2Score;
  final double? speakerSimilarity;
  final double? wakeTemplateSimilarity;
  final double? templateThreshold;
  final double? minSpeechRatio;
  final int requiredStrictHits;
  final int repeatRequiredStrictHits;
  final bool templateVerificationEnabled;
  final bool stage2VerificationEnabled;
  final bool ownerVerificationEnabled;
  final int cooldownRemainingMs;
  final String reason;
  final bool accepted;
}

class WakeEnrollmentState {
  const WakeEnrollmentState({
    this.state = 'idle',
    this.current = 0,
    this.total = 0,
  });

  final String state;
  final int current;
  final int total;

  bool get isActive => state == 'started' || state == 'progress';
}

class WakeWordService {
  WakeWordService({required this.onWakeWordDetected});

  final VoidCallback onWakeWordDetected;

  static const MethodChannel _channel = MethodChannel('janarym/wake_word');
  static const EventChannel _events = EventChannel('janarym/wake_word/events');
  static const List<String> _defaultCustomKeywordAssets = <String>[
    'assets/keywords/zhan-a-rym_en_android_v4_0_0.ppn',
    'assets/keywords/janarym.ppn',
    'assets/keywords/zhanarym.ppn',
    'assets/keywords/janarim.ppn',
    'assets/keywords/zhanarim.ppn',
    'assets/keywords/zhanarum.ppn',
  ];

  final ValueNotifier<WakeWordState> state = ValueNotifier(
    const WakeWordState(
      status: WakeWordStatus.armed,
      keywordMode: 'custom',
      keywordLabel: 'janarym',
      hasOwnerProfile: false,
    ),
  );
  final ValueNotifier<WakeWordDebugState> debugState = ValueNotifier(
    const WakeWordDebugState(),
  );
  final ValueNotifier<WakeEnrollmentState> enrollmentState = ValueNotifier(
    const WakeEnrollmentState(),
  );

  StreamSubscription<dynamic>? _eventsSub;
  bool _initializing = false;
  bool _initialized = false;
  String _configFingerprint = '';
  List<String> _activeKeywordLabels = const <String>[];

  Future<void> start() async {
    await _ensureInitialized();
    if (!_initialized) return;
    if (state.value.status == WakeWordStatus.listening) return;
    try {
      await _channel.invokeMethod<bool>('start');
      _setState(status: WakeWordStatus.listening, clearError: true);
    } catch (e) {
      _setError('Native wake start failed: $e');
    }
  }

  Future<void> stop() async {
    if (!_initialized) return;
    if (state.value.status == WakeWordStatus.armed) return;
    try {
      await _channel.invokeMethod<bool>('stop');
      _setState(status: WakeWordStatus.armed, clearError: true);
    } catch (e) {
      _setError('Native wake stop failed: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<bool>('dispose');
    } catch (_) {}
    await _eventsSub?.cancel();
    _eventsSub = null;
    enrollmentState.dispose();
    debugState.dispose();
    state.dispose();
  }

  Future<bool> hasOwnerProfile() async {
    try {
      final hasProfile = await _channel.invokeMethod<bool>('hasOwnerProfile');
      return hasProfile ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> startEnrollment({int sampleCount = 8}) async {
    await _ensureInitialized();
    if (!_initialized) return;
    await _channel.invokeMethod<bool>('startEnrollment', <String, Object?>{
      'sampleCount': sampleCount.clamp(8, 12),
    });
    enrollmentState.value = WakeEnrollmentState(
      state: 'started',
      current: 0,
      total: sampleCount.clamp(8, 12),
    );
    _setState(status: WakeWordStatus.enrolling);
  }

  Future<void> cancelEnrollment() async {
    if (!_initialized) return;
    await _channel.invokeMethod<bool>('cancelEnrollment');
    enrollmentState.value = const WakeEnrollmentState(state: 'cancelled');
    _setState(status: WakeWordStatus.armed);
  }

  Future<void> clearOwnerProfile() async {
    if (!_initialized) return;
    await _channel.invokeMethod<bool>('clearOwnerProfile');
    enrollmentState.value = const WakeEnrollmentState();
    _setState(hasOwnerProfile: false);
  }

  Future<bool> recover({bool restartListening = true}) async {
    try {
      try {
        await _channel.invokeMethod<bool>('stop');
      } catch (_) {}
      _initialized = false;
      await _ensureInitialized();
      if (!_initialized) return false;
      if (restartListening) {
        await _channel.invokeMethod<bool>('start');
        _setState(status: WakeWordStatus.listening, clearError: true);
      }
      return true;
    } on PlatformException catch (e) {
      _initialized = false;
      final message = e.message?.trim();
      _setError(
        message != null && message.isNotEmpty
            ? message
            : 'Native wake recover failed',
      );
      appLog('[Wake] recover failed: ${e.message ?? e}');
      return false;
    } catch (e) {
      _initialized = false;
      _setError('Native wake recover failed: $e');
      appLog('[Wake] recover failed: $e');
      return false;
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initializing) return;
    final payload = await _buildConfigPayload();
    if (payload == null) return;
    final fingerprint = _fingerprintForPayload(payload);
    if (_initialized && fingerprint == _configFingerprint) {
      return;
    }
    _initializing = true;
    try {
      await _attachEventsIfNeeded();
      await _channel.invokeMethod<bool>('initialize', payload);
      _initialized = true;
      _configFingerprint = fingerprint;
      final hasProfile = await hasOwnerProfile();
      _setState(
        status: WakeWordStatus.armed,
        keywordMode: 'custom',
        keywordLabel: _activeKeywordLabels.join(', '),
        hasOwnerProfile: hasProfile,
        clearError: true,
      );
    } on PlatformException catch (e) {
      _initialized = false;
      final message = e.message?.trim();
      _setError(
        message != null && message.isNotEmpty
            ? message
            : 'Native wake init failed',
      );
    } catch (e) {
      _initialized = false;
      _setError('Native wake init failed: $e');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _attachEventsIfNeeded() async {
    if (_eventsSub != null) return;
    _eventsSub = _events.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error) {
        _setError('Native wake stream failed: $error');
      },
    );
  }

  Future<Map<String, Object?>?> _buildConfigPayload() async {
    final recallMode = _readWakeRecallMode();
    final maxRecall = recallMode == WakeRecallMode.maxRecall;
    final accessKey = (dotenv.env['PICOVOICE_ACCESS_KEY'] ?? '').trim();
    if (accessKey.isEmpty) {
      _setError('PICOVOICE_ACCESS_KEY is empty');
      return null;
    }

    final configuredAssets = _readCustomKeywordAssets();
    final availableAssets = <String>[];
    for (final assetPath in configuredAssets) {
      if (await _assetExists(assetPath)) {
        availableAssets.add(assetPath);
      }
    }
    if (availableAssets.isEmpty) {
      _setError(
        'Custom keyword not found. Expected one of: ${configuredAssets.join(', ')}',
      );
      return null;
    }

    _activeKeywordLabels = availableAssets
        .map(_keywordLabelFromAssetPath)
        .toList(growable: false);

    return <String, Object?>{
      'accessKey': accessKey,
      'keywordPaths': availableAssets,
      'keywordLabels': _activeKeywordLabels,
      'broadSensitivity': _parseSensitivity(
        dotenv.env['WAKE_SENSITIVITY'],
        fallback: maxRecall ? 0.76 : 0.68,
        min: 0.35,
        max: 0.82,
      ),
      'strictSensitivity': _parseSensitivity(
        dotenv.env['WAKE_STAGE2_SENSITIVITY'],
        fallback: maxRecall ? 0.58 : 0.50,
        min: 0.20,
        max: 0.78,
      ),
      'recallMode': recallMode.name,
      'enableOwnerVerification': _readBoolEnv(
        'OWNER_VOICE_PROFILE_ENABLED',
        fallback: !maxRecall,
      ),
      'enableStage2Verification': _readBoolEnv(
        'WAKE_STAGE2_VERIFICATION_ENABLED',
        fallback: !maxRecall,
      ),
      'acceptOnStage1': _readBoolEnv(
        'WAKE_ACCEPT_ON_STAGE1',
        fallback: maxRecall,
      ),
      'gatePorcupineWithVad': _readBoolEnv(
        'WAKE_VAD_GATE_ENABLED',
        fallback: !maxRecall,
      ),
      'enableWakeTemplateVerification': _readBoolEnv(
        'WAKE_TEMPLATE_VERIFICATION_ENABLED',
        fallback: !maxRecall,
      ),
      'speakerSimilarityThreshold': _readDoubleEnv(
        'WAKE_SPEAKER_SIMILARITY_THRESHOLD',
        fallback: 0.70,
      ).clamp(0.58, 0.90),
      'wakeTemplateThreshold': _readDoubleEnv(
        'WAKE_TEMPLATE_SIMILARITY_THRESHOLD',
        fallback: 0.62,
      ).clamp(0.48, 0.90),
      'verifyWindowMs': _readIntEnv(
        'WAKE_VOICE_VERIFY_MS',
        fallback: 380,
      ).clamp(260, 800),
      'minSpeechRatio': _readDoubleEnv(
        'WAKE_STAGE2_MIN_SPEECH_RATIO',
        fallback: maxRecall ? 0.42 : 0.55,
      ).clamp(0.25, 0.75),
      'requiredStrictHits': _readIntEnv(
        'WAKE_STAGE2_REQUIRED_STRICT_HITS',
        fallback: 1,
      ).clamp(1, 4),
      'repeatRequiredStrictHits': _readIntEnv(
        'WAKE_STAGE2_REPEAT_REQUIRED_STRICT_HITS',
        fallback: maxRecall ? 1 : 2,
      ).clamp(1, 4),
      'stage2WindowMs': _readIntEnv(
        'WAKE_STAGE2_WINDOW_MS',
        fallback: maxRecall ? 680 : 560,
      ).clamp(360, 900),
      'stage2PrerollMs': _readIntEnv(
        'WAKE_STAGE2_PREROLL_MS',
        fallback: maxRecall ? 220 : 180,
      ).clamp(80, 500),
      'cooldownMs': _readIntEnv(
        'WAKE_DEBOUNCE_MS',
        fallback: maxRecall ? 1200 : 1800,
      ).clamp(800, 8000),
      'repeatedTriggerWindowMs': _readIntEnv(
        'WAKE_REPEAT_WINDOW_MS',
        fallback: maxRecall ? 2200 : 3200,
      ).clamp(1200, 12000),
      'highNoiseDb': _readDoubleEnv('WAKE_HIGH_NOISE_DB', fallback: -26.0),
      'lowNoiseDb': _readDoubleEnv('WAKE_LOW_NOISE_DB', fallback: -40.0),
      'debugLogging':
          !kReleaseMode &&
          _readBoolEnv('WAKE_DEBUG_LOGS', fallback: kDebugMode),
    };
  }

  String _fingerprintForPayload(Map<String, Object?> payload) {
    return payload.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('|');
  }

  Future<bool> _assetExists(String assetPath) async {
    try {
      await rootBundle.load(assetPath);
      return true;
    } catch (_) {
      return false;
    }
  }

  List<String> _readCustomKeywordAssets() {
    final raw = (dotenv.env['KEYWORD_CUSTOM_PATHS'] ?? '').trim();
    final sourceAssets = raw.isEmpty
        ? _defaultCustomKeywordAssets
        : raw
              .split(RegExp(r'[,\n;]'))
              .map((token) => token.trim())
              .where((token) => token.isNotEmpty)
              .map((token) {
                final noQuotes = token.replaceAll('"', '').replaceAll("'", '');
                if (noQuotes.startsWith('assets/')) {
                  return noQuotes;
                }
                return 'assets/keywords/$noQuotes';
              })
              .map((token) {
                if (token.toLowerCase().endsWith('.ppn')) return token;
                return '$token.ppn';
              })
              .toList(growable: false);

    final deduped = <String>[];
    for (final token in sourceAssets) {
      if (!deduped.contains(token)) {
        deduped.add(token);
      }
    }
    return deduped;
  }

  String _keywordLabelFromAssetPath(String assetPath) {
    final fileName = assetPath.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex <= 0) return fileName;
    return fileName.substring(0, dotIndex);
  }

  double _parseSensitivity(
    String? rawValue, {
    required double fallback,
    required double min,
    required double max,
  }) {
    final parsed =
        double.tryParse((rawValue ?? '$fallback').trim()) ?? fallback;
    final normalized = parsed > 1.0 ? parsed / 100.0 : parsed;
    return normalized.clamp(min, max).toDouble();
  }

  WakeRecallMode _readWakeRecallMode() {
    final raw = (dotenv.env['WAKE_RECALL_MODE'] ?? '').trim().toLowerCase();
    switch (raw) {
      case 'balanced':
        return WakeRecallMode.balanced;
      case 'max_recall':
      case 'maxrecall':
      case 'recall':
      default:
        return WakeRecallMode.maxRecall;
    }
  }

  bool _readBoolEnv(String key, {required bool fallback}) {
    final raw = dotenv.env[key];
    if (raw == null || raw.trim().isEmpty) return fallback;
    switch (raw.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
        return false;
      default:
        return fallback;
    }
  }

  int _readIntEnv(String key, {required int fallback}) {
    final parsed = int.tryParse((dotenv.env[key] ?? '').trim());
    return parsed ?? fallback;
  }

  double _readDoubleEnv(String key, {required double fallback}) {
    final parsed = double.tryParse((dotenv.env[key] ?? '').trim());
    return parsed ?? fallback;
  }

  void _handleNativeEvent(dynamic rawEvent) {
    if (rawEvent is! Map) return;
    final event = rawEvent.map((key, value) => MapEntry(key.toString(), value));
    switch (event['type']) {
      case 'state':
        _setState(
          status: _statusFromNative(event['status']?.toString()),
          lastError: event['lastError']?.toString(),
          keywordLabel: _activeKeywordLabels.join(', '),
          clearError: event['lastError'] == null,
        );
        break;
      case 'wake':
        appLog(
          '[Wake] native accepted '
          'keyword=${event['keywordLabel']} '
          'stage2=${event['stage2Score']} '
          'speaker=${event['speakerSimilarity']}',
        );
        onWakeWordDetected();
        break;
      case 'debug':
        debugState.value = WakeWordDebugState(
          rmsDb: (event['rmsDb'] as num?)?.toDouble(),
          snrDb: (event['snrDb'] as num?)?.toDouble(),
          vadActive: event['vadActive'] as bool? ?? false,
          stage1Score: (event['stage1Score'] as num?)?.toDouble(),
          stage2Score: (event['stage2Score'] as num?)?.toDouble(),
          speakerSimilarity: (event['speakerSimilarity'] as num?)?.toDouble(),
          wakeTemplateSimilarity: (event['wakeTemplateSimilarity'] as num?)
              ?.toDouble(),
          templateThreshold: (event['templateThreshold'] as num?)?.toDouble(),
          minSpeechRatio: (event['minSpeechRatio'] as num?)?.toDouble(),
          requiredStrictHits:
              (event['requiredStrictHits'] as num?)?.toInt() ?? 0,
          repeatRequiredStrictHits:
              (event['repeatRequiredStrictHits'] as num?)?.toInt() ?? 0,
          templateVerificationEnabled:
              event['templateVerificationEnabled'] as bool? ?? false,
          stage2VerificationEnabled:
              event['stage2VerificationEnabled'] as bool? ?? false,
          ownerVerificationEnabled:
              event['ownerVerificationEnabled'] as bool? ?? false,
          cooldownRemainingMs:
              (event['cooldownRemainingMs'] as num?)?.toInt() ?? 0,
          reason: event['reason']?.toString() ?? '',
          accepted: event['accepted'] as bool? ?? false,
        );
        break;
      case 'profile':
        _setState(hasOwnerProfile: event['hasProfile'] as bool? ?? false);
        break;
      case 'enrollment':
        final enrollmentState = event['state']?.toString() ?? '';
        this.enrollmentState.value = WakeEnrollmentState(
          state: enrollmentState,
          current: (event['current'] as num?)?.toInt() ?? 0,
          total: (event['total'] as num?)?.toInt() ?? 0,
        );
        if (enrollmentState == 'completed' || enrollmentState == 'cancelled') {
          _setState(status: WakeWordStatus.armed);
        } else if (enrollmentState == 'started') {
          _setState(status: WakeWordStatus.enrolling);
        }
        break;
      default:
        break;
    }
  }

  WakeWordStatus _statusFromNative(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'listening':
        return WakeWordStatus.listening;
      case 'enrolling':
        return WakeWordStatus.enrolling;
      case 'error':
        return WakeWordStatus.error;
      default:
        return WakeWordStatus.armed;
    }
  }

  void _setError(String message) {
    _setState(
      status: WakeWordStatus.error,
      lastError: message,
      keywordMode: 'custom',
      keywordLabel: _activeKeywordLabels.isEmpty
          ? 'janarym'
          : _activeKeywordLabels.join(', '),
    );
  }

  void _setState({
    WakeWordStatus? status,
    String? keywordMode,
    String? keywordLabel,
    String? lastError,
    bool? hasOwnerProfile,
    bool clearError = false,
  }) {
    final current = state.value;
    state.value = WakeWordState(
      status: status ?? current.status,
      keywordMode: keywordMode ?? current.keywordMode,
      keywordLabel: keywordLabel ?? current.keywordLabel,
      hasOwnerProfile: hasOwnerProfile ?? current.hasOwnerProfile,
      lastError: clearError ? null : (lastError ?? current.lastError),
    );
  }
}
