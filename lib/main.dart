import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation, rootBundle;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:yandex_mapkit/yandex_mapkit.dart' hide BoundingBox;

import 'l10n/app_locale_controller.dart';
import 'l10n/app_localizations.dart';
import 'logic/command_router.dart';
import 'navigation/navigation_mode_controller.dart';
import 'navigation/models/navigation_mode_state.dart';
import 'openai_client.dart';
import 'personalization/data/personalization_database.dart';
import 'personalization/data/secure_payload_codec.dart';
import 'personalization/models/personalization_models.dart';
import 'personalization/personalization_controller.dart';
import 'personalization/personalization_repository.dart';
import 'reflex/reflex_engine.dart';
import 'runtime/android_runtime_service.dart';
import 'runtime/app_log.dart';
import 'runtime/feature_flags.dart';
import 'runtime/mode_orchestrator.dart';
import 'runtime/perception_event_bus.dart';
import 'services/camera_frame_service.dart';
import 'services/on_device_text_reader_service.dart';
import 'services/open_meteo_service.dart';
import 'services/scene_memory_service.dart';
import 'services/shopping_mode_service.dart';
import 'services/text_reader_decision_helper.dart';
import 'services/text_reading_normalizer.dart';
import 'text_reader/text_reader_controller.dart';
import 'text_reader/text_reader_engine.dart';
import 'text_reader/text_reader_types.dart';
import 'widgets/bbox_painter.dart';
import 'voice/android_stt_wake_service.dart';
import 'voice/command_stt_service.dart';
import 'voice/mic_cue_policy.dart';
import 'voice/spoken_language_detector.dart';
import 'voice/wake_cue_service.dart';
import 'voice/wake_engine_mode.dart';
import 'voice/wake_phrase_matcher.dart';
import 'voice/wake_word_service.dart';

bool _readEnvBool(String key, {required bool fallback}) {
  try {
    final raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    if (raw.isEmpty) return fallback;
    if (raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on') {
      return true;
    }
    if (raw == '0' || raw == 'false' || raw == 'no' || raw == 'off') {
      return false;
    }
    return fallback;
  } catch (_) {
    return fallback;
  }
}

int _readEnvInt(String key, {required int fallback, int? min, int? max}) {
  try {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null) return fallback;
    var result = value;
    if (min != null && result < min) result = min;
    if (max != null && result > max) result = max;
    return result;
  } catch (_) {
    return fallback;
  }
}

double _readEnvDouble(
  String key, {
  required double fallback,
  double? min,
  double? max,
}) {
  try {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    final value = double.tryParse(raw.replaceAll(',', '.'));
    if (value == null || value.isNaN || value.isInfinite) return fallback;
    var result = value;
    if (min != null && result < min) result = min;
    if (max != null && result > max) result = max;
    return result;
  } catch (_) {
    return fallback;
  }
}

String _readEnvString(String key, {String fallback = ''}) {
  try {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    return raw;
  } catch (_) {
    return fallback;
  }
}

Future<void> _loadRuntimeEnv() async {
  Future<String> loadOptionalAsset(String assetPath) async {
    try {
      return await rootBundle.loadString(assetPath);
    } catch (_) {
      return '';
    }
  }

  final defaults = await loadOptionalAsset('.env.example');
  final runtime = await loadOptionalAsset('assets/runtime/env.runtime');

  dotenv.loadFromString(
    envString: defaults,
    overrideWith: runtime.isEmpty ? const [] : [runtime],
    isOptional: true,
  );

  final openAiKeyLoaded =
      (dotenv.maybeGet('OPENAI_API_KEY') ?? dotenv.maybeGet('OPENAI_KEY') ?? '')
          .trim()
          .isNotEmpty;
  debugPrint(
    '[Env] defaults_loaded=${defaults.isNotEmpty} '
    'runtime_loaded=${runtime.isNotEmpty} '
    'openai_key_loaded=$openAiKeyLoaded',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadRuntimeEnv();
  runApp(const JanarymApp());
}

class JanarymApp extends StatefulWidget {
  const JanarymApp({super.key});

  @override
  State<JanarymApp> createState() => _JanarymAppState();
}

class _JanarymAppState extends State<JanarymApp> {
  final AppLocaleController _localeController = AppLocaleController();

  @override
  void initState() {
    super.initState();
    unawaited(_localeController.init());
  }

  @override
  void dispose() {
    _localeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _localeController,
      builder: (context, _) {
        return MaterialApp(
          title: 'Janarym',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          locale: _localeController.locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: JanarymHome(
            appLanguage: _localeController.language,
            onLanguageChanged: _localeController.setLanguage,
          ),
        );
      },
    );
  }
}

enum GptStatus { idle, loading, ok, error }

enum CircleState { idle, wake, listening, thinking, speaking, end }

enum AssistantMode {
  general,
  navigation,
  safety,
  shopping,
  cooking,
  dressCode,
  antiFraud,
  textReader,
  memory,
  find,
}

enum _OnboardingTurnResult { advanced, retry, paused, completed }

enum _DialogBrevityMode { auto, short, detailed }

enum _TextReaderReadSource { voice, tap, auto }

enum _TextReaderSessionState { idle, scanning, speaking, paused, failed }

class _LabelCorrectionDraft {
  const _LabelCorrectionDraft({this.labelName, this.addressText});

  final String? labelName;
  final String? addressText;

  bool get hasAny =>
      (labelName != null && labelName!.trim().isNotEmpty) ||
      (addressText != null && addressText!.trim().isNotEmpty);
}

class _DialogStyleDirectiveResult {
  const _DialogStyleDirectiveResult({
    required this.cleanedText,
    required this.onlyDirective,
  });

  final String cleanedText;
  final bool onlyDirective;
}

class _DialogTurn {
  const _DialogTurn({required this.userText, required this.assistantText});

  final String userText;
  final String assistantText;
}

class _ModeMenuEntry {
  const _ModeMenuEntry({
    required this.label,
    required this.icon,
    this.mode,
    this.actionId,
  });

  final String label;
  final IconData icon;
  final AssistantMode? mode;
  final String? actionId;

  bool get isMode => mode != null;
}

class JanarymHome extends StatefulWidget {
  const JanarymHome({
    super.key,
    required this.appLanguage,
    required this.onLanguageChanged,
  });

  final AppLanguage appLanguage;
  final Future<void> Function(AppLanguage language) onLanguageChanged;

  @override
  State<JanarymHome> createState() => _JanarymHomeState();
}

class _JanarymHomeState extends State<JanarymHome>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _sfxPlayer = AudioPlayer();
  final WakeCueService _wakeCueService = WakeCueService();
  final CommandRouter _router = CommandRouter();
  final OpenAiClient _openAi = OpenAiClient();
  final PersonalizationDatabase _personalizationDatabase =
      PersonalizationDatabase();
  final SecurePayloadCodec _securePayloadCodec = SecurePayloadCodec();
  final CameraFrameStore _cameraFrameStore = CameraFrameStore();
  late final PersonalizationRepository _personalizationRepository;
  late final PersonalizationController _personalizationController;
  late AppLocalizations _l10n;
  late AppLanguage _interactionLanguage;
  late final NavigationModeController _navigationController;
  late final CommandSttService _sttService;
  late final WakeWordService _wakeService;
  late final WakeEngineMode _wakeEngineMode;
  late final AndroidSttWakeService _sttWakeService;
  late final RuntimeFeatureFlags _featureFlags;
  late final ModeOrchestrator _modeOrchestrator;
  late final PerceptionEventBus _perceptionEventBus;
  late final ReflexEngine _reflexEngine;
  late final OnDeviceTextReaderService _textReaderService;
  late final TextReaderEngine _textReaderEngine;
  late final TextReaderController _textReaderController;
  late final OpenMeteoService _openMeteoService;
  late final SceneMemoryService _sceneMemoryService;
  late final ShoppingModeService _shoppingModeService;
  YandexMapController? _yandexMapController;

  DateTime? _lastWakeAt;
  bool _micGranted = false;
  String _micMessage = '';
  CameraController? _cameraController;
  bool _cameraGranted = false;
  bool _cameraStreaming = false;
  bool _modePickerOpen = false;
  bool _cameraInitInProgress = false;
  bool _cameraStartInProgress = false;
  String _cameraMessage = '';
  String _cameraError = '';
  bool _runtimeServiceRunning = false;
  int _lastPerceptionEventMs = 0;
  String _latestHazardHint = '';
  List<BBoxOverlayEntry> _reflexBBoxes = const <BBoxOverlayEntry>[];
  List<ReflexDetection> _latestReflexDetections = const <ReflexDetection>[];
  List<CameraDescription>? _cachedCameras;
  DateTime? _lastFrameAt;
  CameraFrameSnapshot? _lastFrame;
  int _lastFrameMs = 0;
  int _cameraProcessedFrames = 0;
  int _cameraDroppedFrames = 0;
  int _cameraPreviewFps = 0;
  int _cameraFpsWindowStartedMs = 0;
  int _reflexInferenceLatencyMs = 0;
  int _reflexDetectionsCount = 0;
  bool _voicePriorityWindowActive = false;
  bool _interactionLanguagePinned = false;
  DateTime? _interactionLanguageUpdatedAt;
  DateTime? _wakeErrorSince;
  int _lastWakeDetectedMs = 0;
  int _lastWakeAckDoneMs = 0;
  int _lastWakeSttOpenedMs = 0;
  GptStatus _gptStatus = GptStatus.idle;
  String _gptError = '';
  String _lastAnswer = '';

  bool _commandInFlight = false;
  String _lastLoggedFinal = '';
  String _lastLoggedWakeSignature = '';
  bool _personalizationReady = false;
  bool _showOnboardingOverlay = true;
  bool _onboardingDialogInProgress = false;
  Timer? _onboardingReminderTimer;
  static const int _maxFrameAgeMs = 8000;
  static const double _manualTextReadAcceptScore = 35.0;
  static const double _manualTextReadAggressiveAcceptScore = 24.0;
  static const int _manualTextReadAttempts = 3;
  static const int _manualTextReadFirstTimeoutMs = 850;
  static const int _manualTextReadRetryTimeoutMs = 550;
  static const int _manualTextReadInterAttemptDelayMs = 90;
  bool _followUpActive = false;
  bool _followUpPending = false;
  bool _wakeHandling = false;
  bool _thinkingSoundPlayed = false;
  bool _vibrationAvailable = false;
  bool _isSpeaking = false;
  int _requestId = 0;
  DateTime? _llmRateLimitedUntil;
  late final AnimationController _circleController;
  late final Animation<double> _circlePulse;
  late final AnimationController _modeFabController;
  late final Animation<double> _modeFabPulse;
  CircleState _circleState = CircleState.idle;
  Timer? _cameraKeepAliveTimer;
  Timer? _modePickerAutoCloseTimer;
  Timer? _textReaderLoopTimer;
  Timer? _wakeFallbackEscalationTimer;
  Timer? _wakeRecoveryTimer;
  bool _wakeFallbackActive = false;
  bool _wakeFallbackLoopRunning = false;
  bool _wakeFallbackStopRequested = false;
  bool _wakeRecoveryInProgress = false;
  bool _wakeWordOnlyMode = false;
  int _wakeRecoveryAttempts = 0;
  bool _sttWakeArmed = false;
  bool _sttWakeUnavailable = false;
  bool _sttWakeInitialized = false;
  bool _sttWakeAcceptInFlight = false;
  DateTime? _sttWakeFatalErrorWindowStartedAt;
  DateTime? _sttWakeUnavailableSince;
  DateTime? _sttWakeLastEventAt;
  String? _sttWakeLanguageOverride;
  int _sttWakeFatalErrors = 0;
  String _lastSttWakeMatch = 'none';
  String _lastSttWakeReason = 'idle';
  StreamSubscription<SttWakeEvent>? _sttWakeSubscription;
  Timer? _sttWakeWatchdogTimer;
  Future<void> _permissionRequestTail = Future<void>.value();
  bool _textReaderLoopBusy = false;
  bool _manualTextReadInProgress = false;
  final Set<String> _recentReadSegments = <String>{};
  DateTime _lastReadClearTime = DateTime.now();
  bool _textReaderAutoPaused = false;
  bool _textReaderSessionCancelRequested = false;
  AssistantMode _assistantMode = AssistantMode.general;
  _TextReaderSessionState _textReaderSessionState =
      _TextReaderSessionState.idle;
  String _lastTextReaderFailureReason = '';
  _DialogBrevityMode _dialogBrevityMode = _DialogBrevityMode.auto;
  final List<_DialogTurn> _dialogHistory = <_DialogTurn>[];
  NavPoint? _lastNavCameraTarget;
  final bool _alwaysDialogMode = _readEnvBool(
    'ALWAYS_DIALOG_MODE',
    fallback: true,
  );
  final bool _sttWakeEnabled = _readEnvBool('STT_WAKE_ENABLED', fallback: true);
  final String _sttWakeLanguage = _readEnvString(
    'STT_WAKE_LANGUAGE',
    fallback: 'ru-RU',
  );
  final bool _sttWakePartialResultsEnabled = _readEnvBool(
    'STT_WAKE_PARTIAL_RESULTS_ENABLED',
    fallback: true,
  );
  final int _sttWakeRestartDelayMs = _readEnvInt(
    'STT_WAKE_RESTART_DELAY_MS',
    fallback: 120,
    min: 50,
    max: 2000,
  );
  final int _sttWakeFatalErrorThreshold = _readEnvInt(
    'STT_WAKE_FATAL_ERROR_THRESHOLD',
    fallback: 5,
    min: 1,
    max: 20,
  );
  final int _sttWakeFatalErrorWindowMs = _readEnvInt(
    'STT_WAKE_FATAL_ERROR_WINDOW_MS',
    fallback: 20000,
    min: 1000,
    max: 120000,
  );
  final bool _sttWakeLegacyFallbackEnabled = _readEnvBool(
    'STT_WAKE_LEGACY_FALLBACK_ENABLED',
    fallback: true,
  );
  final bool _sttWakeDebugLogs = _readEnvBool(
    'STT_WAKE_DEBUG_LOGS',
    fallback: true,
  );
  final bool _sttWakePreferOffline = _readEnvBool(
    'STT_WAKE_PREFER_OFFLINE',
    fallback: false,
  );
  final int _sttWakeWatchdogMaxSilenceMs = _readEnvInt(
    'STT_WAKE_WATCHDOG_MAX_SILENCE_MS',
    fallback: 12000,
    min: 3000,
    max: 60000,
  );
  final int _sttWakeUnavailableRetryMs = _readEnvInt(
    'STT_WAKE_UNAVAILABLE_RETRY_MS',
    fallback: 20000,
    min: 2000,
    max: 180000,
  );
  final bool _requireWakeWord = _readEnvBool(
    'ASSISTANT_REQUIRE_WAKE_WORD',
    fallback: true,
  );
  final bool _wakeReplyEnabled = _readEnvBool(
    'ASSISTANT_WAKE_REPLY_ENABLED',
    fallback: false,
  );
  final int _dialogContextTurns = _readEnvInt(
    'DIALOG_CONTEXT_TURNS',
    fallback: 6,
    min: 0,
    max: 12,
  );
  final String _dialogBrevityDefaultRaw = _readEnvString(
    'DIALOG_BREVITY_DEFAULT',
    fallback: 'auto',
  );
  final double _ttsSpeechRate = _readEnvDouble(
    'TTS_SPEECH_RATE',
    fallback: 0.50,
    min: 0.30,
    max: 0.70,
  );
  final double _ttsPitch = _readEnvDouble(
    'TTS_PITCH',
    fallback: 1.02,
    min: 0.8,
    max: 1.3,
  );
  final String _ttsPreferredVoiceRu = _readEnvString('TTS_PREFERRED_VOICE_RU');
  AppLanguage _ttsConfiguredLanguage = AppLanguage.ru;
  String _ttsConfiguredLocaleCode = 'ru-RU';
  final String _wakeAckTextRu = _readEnvString(
    'WAKE_ACK_TEXT_RU',
    fallback: 'Что нужно?',
  );
  final String _wakeAckTextKk = _readEnvString(
    'WAKE_ACK_TEXT_KK',
    fallback: 'Не қалайсыз?',
  );
  final String _wakeRecallModeRaw = _readEnvString(
    'WAKE_RECALL_MODE',
    fallback: 'max_recall',
  ).toLowerCase();
  final bool _wakeTemplateVerificationEnabled = _readEnvBool(
    'WAKE_TEMPLATE_VERIFICATION_ENABLED',
    fallback: false,
  );
  final bool _wakeStage2VerificationEnabled = _readEnvBool(
    'WAKE_STAGE2_VERIFICATION_ENABLED',
    fallback: false,
  );
  final bool _ownerVerificationEnabled = _readEnvBool(
    'OWNER_VOICE_PROFILE_ENABLED',
    fallback: false,
  );
  final double _wakeAckSpeechRate = _readEnvDouble(
    'WAKE_ACK_SPEECH_RATE',
    fallback: 0.62,
    min: 0.45,
    max: 0.85,
  );
  final bool _embeddedMapEnabled = _readEnvBool(
    'NAV_EMBEDDED_MAP_ENABLED',
    fallback: false,
  );
  final bool _audioCuesEnabled = _readEnvBool(
    'AUDIO_CUES_ENABLED',
    fallback: false,
  );
  final bool _wakeCueEnabled = _readEnvBool('WAKE_CUE_ENABLED', fallback: true);
  final int _frameCaptureThrottleMs = _readEnvInt(
    'FRAME_CAPTURE_THROTTLE_MS',
    fallback: 400,
    min: 300,
    max: 500,
  );
  final int _textReaderFrameIntervalMs = _readEnvInt(
    'TEXT_READER_FRAME_INTERVAL_MS',
    fallback: 320,
    min: 300,
    max: 900,
  );
  final int _textReaderSpeechCooldownMs = _readEnvInt(
    'TEXT_READER_SPEECH_COOLDOWN_MS',
    fallback: 1500,
    min: 700,
    max: 5000,
  );
  final int _textReaderVisionCooldownMs = _readEnvInt(
    'TEXT_READER_GPT_COOLDOWN_MS',
    fallback: 2200,
    min: 1200,
    max: 10000,
  );
  final int _textReaderVisionTimeoutMs = _readEnvInt(
    'TEXT_READER_GPT_TIMEOUT_MS',
    fallback: 4500,
    min: 2500,
    max: 12000,
  );
  final int _textReaderStableFramesRequired = _readEnvInt(
    'TEXT_READER_STABLE_FRAMES',
    fallback: 3,
    min: 2,
    max: 5,
  );
  String _lastAutoTextReaderSignature = '';
  int _lastAutoTextReaderSpeakMs = 0;
  String _lastAutoTextReaderExactSignature = '';
  int _lastAutoTextReaderExactMs = 0;
  String _pendingAutoTextReaderSignature = '';
  int _pendingAutoTextReaderSeenCount = 0;
  String _lastTextReaderVisionSignature = '';
  int _lastTextReaderVisionMs = 0;
  bool _textReaderVisionRequestInFlight = false;
  bool get _wakeDebugOverlayEnabled =>
      _featureFlags.developerDiagnosticsEnabled &&
      _readEnvBool('WAKE_DEBUG_OVERLAY', fallback: true);
  static const Duration _wakeFallbackIdleWait = Duration(milliseconds: 520);
  static const Duration _wakeFallbackAfterListenWait = Duration(
    milliseconds: 520,
  );
  static const Duration _wakeFallbackNoSpeechWait = Duration(
    milliseconds: 1200,
  );
  static const Duration _wakeFallbackErrorGrace = Duration(milliseconds: 1200);
  static const Duration _wakeRecoveryRetryCooldown = Duration(
    milliseconds: 240,
  );
  static const int _wakeRecoveryMaxAttempts = 2;
  static const int _textReaderAutoExactCooldownMs = 6000;
  DateTime? _lastWakeRecoveryAttemptAt;

  bool get _useSttWakeEngine =>
      // SpeechRecognizer may still show system mic UX/audio on some Android
      // devices. The app only suppresses its own cues outside wake accept.
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _wakeEngineMode == WakeEngineMode.sttAndroid &&
      _sttWakeEnabled;

  @override
  void initState() {
    super.initState();
    _l10n = lookupAppLocalizations(widget.appLanguage.locale);
    _interactionLanguage = widget.appLanguage;
    _featureFlags = RuntimeFeatureFlags.fromEnv();
    _modeOrchestrator = ModeOrchestrator(flags: _featureFlags);
    _perceptionEventBus = PerceptionEventBus();
    _reflexEngine = ReflexEngine(
      eventBus: _perceptionEventBus,
      captureLatestFrame: _captureLatestFrameForReflex,
      onOverlayChanged: _handleReflexOverlayChanged,
      onAlert: _handleReflexAlert,
      onMetrics: _handleReflexMetrics,
      enabled: _featureFlags.reflexEnabled,
    );
    _textReaderService = OnDeviceTextReaderService();
    _textReaderEngine = const TextReaderEngine();
    _textReaderController = TextReaderController(
      engine: _textReaderEngine,
      readOnDevice: ({required bool force, required Duration timeout}) =>
          _readTextFromCurrentFrame(force: force, timeout: timeout),
      readVisionFallback:
          ({
            required bool autoRead,
            required String reason,
            required int timeoutMs,
            required int maxAttempts,
          }) => _tryTextReaderVisionFallback(
            fastMode: true,
            autoRead: autoRead,
            reason: reason,
            timeoutMs: timeoutMs,
            maxAttempts: maxAttempts,
          ),
      autoGptCooldownMs: _textReaderVisionCooldownMs,
      autoGptTimeoutMs: 2500,
      manualGptTimeoutMs: 3500,
      tapBurstCount: 3,
    );
    _openMeteoService = OpenMeteoService();
    _sceneMemoryService = SceneMemoryService(
      database: _personalizationDatabase,
      codec: _securePayloadCodec,
    );
    _shoppingModeService = ShoppingModeService(
      database: _personalizationDatabase,
      codec: _securePayloadCodec,
    );
    WidgetsBinding.instance.addObserver(this);
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _circlePulse = Tween<double>(begin: 0.95, end: 1.15).animate(
      CurvedAnimation(parent: _circleController, curve: Curves.easeInOutQuad),
    );
    _modeFabController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    )..repeat(reverse: true);
    _modeFabPulse = Tween<double>(begin: 0.95, end: 1.03).animate(
      CurvedAnimation(parent: _modeFabController, curve: Curves.easeInOut),
    );
    _personalizationRepository = PersonalizationRepository(
      database: _personalizationDatabase,
    );
    _personalizationController = PersonalizationController(
      repository: _personalizationRepository,
    );
    _navigationController = NavigationModeController(
      speak: _speak,
      log: appLog,
      language: _interactionLanguage,
      instructionAdapter: _adaptNavigationInstruction,
      onRouteBuilt: _handleRouteBuilt,
    );
    _wakeEngineMode = readWakeEngineModeFromEnv();
    _sttService = CommandSttService(language: _interactionLanguage);
    _wakeService = WakeWordService(onWakeWordDetected: _handleWakeDetected);
    _sttWakeService = AndroidSttWakeService(debugLogs: _sttWakeDebugLogs);
    unawaited(_wakeCueService.preload());
    _openAi.setLanguage(_interactionLanguage);
    _dialogBrevityMode = _parseInitialBrevityMode(_dialogBrevityDefaultRaw);
    _micMessage = _l10n.checkingMic;
    _cameraMessage = _l10n.checkingCamera;
    _navigationController.state.addListener(_handleNavigationStateChange);
    _sttService.state.addListener(_handleSttStateChange);
    _wakeService.state.addListener(_handleWakeStateChange);
    _sttWakeSubscription = _sttWakeService.events.listen(
      (event) => unawaited(_handleSttWakeEvent(event)),
    );
    _modeOrchestrator.addListener(_handleModeOrchestratorChange);
    _personalizationController.addListener(_handlePersonalizationChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapRuntime());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = AppLocalizations.of(context);
  }

  @override
  void didUpdateWidget(covariant JanarymHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appLanguage != widget.appLanguage) {
      _l10n = lookupAppLocalizations(widget.appLanguage.locale);
      if (!_interactionLanguagePinned) {
        _applyInteractionLanguage(
          widget.appLanguage,
          reason: 'ui_language_changed',
        );
        unawaited(_configureTtsForLanguage(_interactionLanguage));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWakeFallbackLoop();
    _navigationController.state.removeListener(_handleNavigationStateChange);
    _sttService.state.removeListener(_handleSttStateChange);
    _wakeService.state.removeListener(_handleWakeStateChange);
    _sttWakeSubscription?.cancel();
    _sttWakeSubscription = null;
    _modeOrchestrator.removeListener(_handleModeOrchestratorChange);
    _personalizationController.removeListener(_handlePersonalizationChange);
    unawaited(_navigationController.dispose());
    unawaited(_personalizationRepository.close());
    _personalizationController.dispose();
    _sttService.dispose();
    _wakeService.dispose();
    unawaited(_sttWakeService.dispose());
    unawaited(_textReaderService.dispose());
    _openMeteoService.dispose();
    _modeOrchestrator.dispose();
    unawaited(_reflexEngine.dispose());
    unawaited(_perceptionEventBus.dispose());
    _openAi.dispose();
    _cameraKeepAliveTimer?.cancel();
    _cameraKeepAliveTimer = null;
    _modePickerAutoCloseTimer?.cancel();
    _modePickerAutoCloseTimer = null;
    _textReaderLoopTimer?.cancel();
    _textReaderLoopTimer = null;
    _onboardingReminderTimer?.cancel();
    _onboardingReminderTimer = null;
    _wakeFallbackEscalationTimer?.cancel();
    _wakeFallbackEscalationTimer = null;
    _wakeRecoveryTimer?.cancel();
    _wakeRecoveryTimer = null;
    _sttWakeWatchdogTimer?.cancel();
    _sttWakeWatchdogTimer = null;
    _disposeCamera();
    _sfxPlayer.dispose();
    _tts.stop();
    _modeFabController.dispose();
    _circleController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapRuntime() async {
    await _initTts();
    await _initVibration();
    await _initMicAndWake();
    if (!mounted) return;
    _startCameraKeepAlive();
    if (_featureFlags.aggressiveBackgroundCamera ||
        _modeNeedsLiveCamera(_assistantMode)) {
      await _initCameraLive();
    }
    await _syncHeavyServices();
    await _initPersonalization();
    if (!mounted) return;
  }

  AppLocalizations get _voiceL10n =>
      lookupAppLocalizations(_interactionLanguage.locale);
  AppLanguage get _voiceLanguage => _interactionLanguage;
  bool get _voiceIsKazakh => _voiceLanguage == AppLanguage.kk;

  String _voiceText({required String ru, required String kk}) {
    return _voiceIsKazakh ? kk : ru;
  }

  void _markSttWakeUnavailable(String reason) {
    _sttWakeUnavailable = true;
    _sttWakeUnavailableSince ??= DateTime.now();
    _sttWakeInitialized = false;
    _sttWakeArmed = false;
    _stopSttWakeWatchdog();
    appLog('[STTWake] unavailable reason=$reason');
  }

  void _markSttWakeRecovered(String reason) {
    if (!_sttWakeUnavailable &&
        _sttWakeUnavailableSince == null &&
        _sttWakeInitialized) {
      return;
    }
    _sttWakeUnavailable = false;
    _sttWakeUnavailableSince = null;
    _sttWakeFatalErrorWindowStartedAt = null;
    _sttWakeFatalErrors = 0;
    _sttWakeInitialized = true;
    if (_sttWakeDebugLogs) {
      appLog('[STTWake] recovered reason=$reason');
    }
  }

  void _startSttWakeWatchdog() {
    if (!_useSttWakeEngine) return;
    _sttWakeWatchdogTimer?.cancel();
    final periodMs = (_sttWakeWatchdogMaxSilenceMs ~/ 3).clamp(1000, 5000);
    _sttWakeWatchdogTimer = Timer.periodic(Duration(milliseconds: periodMs), (
      _,
    ) {
      unawaited(_checkSttWakeWatchdog());
    });
  }

  void _stopSttWakeWatchdog() {
    _sttWakeWatchdogTimer?.cancel();
    _sttWakeWatchdogTimer = null;
  }

  String get _effectiveSttWakeLanguage {
    final override = _sttWakeLanguageOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    final configured = _sttWakeLanguage.trim();
    if (configured.isNotEmpty) return configured;
    return 'ru-RU';
  }

  String? _fallbackSttWakeLanguageFor(String currentLanguage) {
    final normalizedCurrent = currentLanguage.trim().toLowerCase();
    final candidates = <String>[
      _sttWakeLanguage.trim(),
      'ru-RU',
      'ru',
      'en-US',
    ];
    for (final candidate in candidates) {
      final value = candidate.trim();
      if (value.isEmpty) continue;
      if (value.toLowerCase() == normalizedCurrent) continue;
      return value;
    }
    return null;
  }

  Future<T> _runSerializedPermissionRequest<T>(
    Future<T> Function() action,
  ) async {
    final previous = _permissionRequestTail;
    final completer = Completer<void>();
    _permissionRequestTail = completer.future;
    await previous;
    try {
      return await action();
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _checkSttWakeWatchdog() async {
    if (!_useSttWakeEngine || !mounted) return;
    if (!_sttWakeArmed ||
        _sttWakeUnavailable ||
        _commandInFlight ||
        _followUpActive ||
        _wakeHandling ||
        _isSpeaking ||
        _onboardingDialogInProgress ||
        _sttService.isListening) {
      return;
    }
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final last = _sttWakeLastEventAt;
    if (last == null) return;
    final staleMs = DateTime.now().difference(last).inMilliseconds;
    if (staleMs < _sttWakeWatchdogMaxSilenceMs) return;
    appLog('[STTWake] watchdog restart stale_ms=$staleMs');
    _sttWakeArmed = false;
    _sttWakeInitialized = false;
    try {
      await _sttWakeService.cancel();
    } catch (_) {}
    await _syncPrimaryWakeMode();
  }

  Future<void> _initializeSttWakeIfNeeded({bool force = false}) async {
    if (!_useSttWakeEngine) return;
    if (_sttWakeInitialized && !force) return;
    final language = _effectiveSttWakeLanguage;
    try {
      await _sttWakeService.initialize(
        language: language,
        partialResults: _sttWakePartialResultsEnabled,
        preferOffline: _sttWakePreferOffline,
      );
      final available = await _sttWakeService.isAvailable();
      if (!available) {
        _markSttWakeUnavailable('not_available');
        return;
      }
      _markSttWakeRecovered('initialize');
      if (_sttWakeDebugLogs) {
        appLog(
          '[STTWake] initialize language=$language '
          'partials=$_sttWakePartialResultsEnabled '
          'offline=$_sttWakePreferOffline',
        );
      }
    } catch (error) {
      _markSttWakeUnavailable('initialize_failed');
      appLog('[STTWake] initialize failed: $error');
    }
  }

  Future<bool> _startSttWake({required String reason}) async {
    if (!_useSttWakeEngine || _sttWakeUnavailable) return false;
    if (_sttWakeArmed) return true;
    try {
      final status = await _sttWakeService.status();
      if ((status['status']?.toString() ?? '') == 'listening') {
        _sttWakeArmed = true;
        _sttWakeAcceptInFlight = false;
        _sttWakeLastEventAt = DateTime.now();
        _startSttWakeWatchdog();
        if (_sttWakeDebugLogs) {
          appLog('[STTWake] start skipped already_listening reason=$reason');
        }
        return true;
      }
      await _sttWakeService.start();
      _sttWakeArmed = true;
      _sttWakeAcceptInFlight = false;
      _sttWakeLastEventAt = DateTime.now();
      _startSttWakeWatchdog();
      if (_sttWakeDebugLogs) {
        appLog('[STTWake] start reason=$reason');
      }
      return true;
    } catch (error) {
      _sttWakeArmed = false;
      _sttWakeInitialized = false;
      _markSttWakeUnavailable('start_failed');
      appLog('[STTWake] start failed reason=$reason error=$error');
      return false;
    }
  }

  Future<void> _stopSttWake({
    required String reason,
    bool cancel = false,
  }) async {
    if (!_useSttWakeEngine) return;
    if (!_sttWakeArmed && !_sttWakeUnavailable && !cancel) return;
    try {
      if (cancel) {
        await _sttWakeService.cancel();
      } else {
        await _sttWakeService.stop();
      }
    } catch (_) {}
    _sttWakeArmed = false;
    _stopSttWakeWatchdog();
    if (_sttWakeDebugLogs) {
      appLog('[STTWake] stop reason=$reason');
    }
  }

  Future<bool> _startLegacyNativeWake({required String reason}) async {
    try {
      await _wakeService.start();
      appLog('[Wake] native rollback start reason=$reason');
      return true;
    } catch (error) {
      appLog('[Wake] native rollback failed reason=$reason error=$error');
      return false;
    }
  }

  Future<void> _stopLegacyNativeWake({required String reason}) async {
    try {
      await _wakeService.stop();
      appLog('[Wake] native rollback stop reason=$reason');
    } catch (_) {}
  }

  Future<void> _stopPrimaryWake({required String reason}) async {
    if (_useSttWakeEngine) {
      await _stopSttWake(reason: reason, cancel: true);
      return;
    }
    await _wakeService.stop();
  }

  bool _isFatalSttWakeEvent(SttWakeEvent event) {
    return event.reason == 'fatal' ||
        event.errorName == 'ERROR_INSUFFICIENT_PERMISSIONS';
  }

  bool _isUnsupportedSttWakeLanguageEvent(SttWakeEvent event) {
    return event.errorCode == 12 ||
        event.errorCode == 13 ||
        event.errorName == 'ERROR_LANGUAGE_NOT_SUPPORTED' ||
        event.errorName == 'ERROR_LANGUAGE_UNAVAILABLE';
  }

  void _recordSttWakeFatalError() {
    final now = DateTime.now();
    final startedAt = _sttWakeFatalErrorWindowStartedAt;
    if (startedAt == null ||
        now.difference(startedAt).inMilliseconds > _sttWakeFatalErrorWindowMs) {
      _sttWakeFatalErrorWindowStartedAt = now;
      _sttWakeFatalErrors = 1;
      return;
    }
    _sttWakeFatalErrors += 1;
    if (_sttWakeFatalErrors >= _sttWakeFatalErrorThreshold) {
      _markSttWakeUnavailable('fatal_error_window');
    }
  }

  Future<void> _handleSttWakeEvent(SttWakeEvent event) async {
    if (!_useSttWakeEngine || !mounted) return;
    _sttWakeLastEventAt = DateTime.now();
    switch (event.status) {
      case 'ready':
      case 'listening':
        _sttWakeArmed = true;
        _lastSttWakeReason = event.status;
        _startSttWakeWatchdog();
        return;
      case 'partial':
      case 'final':
        if (_sttWakeAcceptInFlight) return;
        final text = (event.text ?? '').trim();
        if (text.isEmpty) return;
        final match = WakePhraseMatcher.match(
          text,
          isPartial: event.status == 'partial',
        );
        if (_sttWakeDebugLogs) {
          appLog(
            '[STTWake] ${event.status}="${_truncateForLog(text)}" '
            'match=${match.strength.name} reason=${match.reason} '
            'candidate="${match.normalized}"',
          );
        }
        _lastSttWakeMatch = match.strength.name;
        _lastSttWakeReason = match.reason;
        final accepted = WakePhraseMatcher.isAccepted(match);
        if (!accepted) {
          return;
        }
        appLog(
          '[STTWake] accepted ${event.status} '
          'match=${match.strength.name} reason=${match.reason} '
          'candidate="${match.normalized}"',
        );
        _sttWakeAcceptInFlight = true;
        await _stopSttWake(reason: 'accepted_${event.status}', cancel: true);
        await _handleWakeDetected();
        return;
      case 'error':
        _sttWakeArmed = false;
        _stopSttWakeWatchdog();
        final reason = event.reason ?? 'error';
        if (reason != 'no_match' && reason != 'timeout') {
          _sttWakeInitialized = false;
        }
        _lastSttWakeReason = event.reason ?? 'error';
        appLog(
          '[STTWake] error code=${event.errorCode ?? '-'} '
          'name=${event.errorName ?? '-'} reason=${event.reason ?? '-'}',
        );
        if (_isUnsupportedSttWakeLanguageEvent(event)) {
          final currentLanguage = (event.locale ?? _effectiveSttWakeLanguage)
              .trim();
          final fallbackLanguage = _fallbackSttWakeLanguageFor(currentLanguage);
          if (fallbackLanguage != null) {
            _sttWakeLanguageOverride = fallbackLanguage;
            appLog(
              '[STTWake] language fallback '
              '$currentLanguage -> $fallbackLanguage',
            );
            Future<void>.delayed(
              Duration(milliseconds: _sttWakeRestartDelayMs),
              () async {
                if (!mounted || !_useSttWakeEngine) return;
                await _syncPrimaryWakeMode();
              },
            );
            return;
          }
          _markSttWakeUnavailable('language_unsupported');
          await _syncPrimaryWakeMode();
          return;
        }
        if (_isFatalSttWakeEvent(event)) {
          _recordSttWakeFatalError();
          if (_sttWakeUnavailable) {
            await _syncPrimaryWakeMode();
            return;
          }
        }
        Future<void>.delayed(
          Duration(milliseconds: _sttWakeRestartDelayMs),
          () async {
            if (!mounted || !_useSttWakeEngine) return;
            await _syncPrimaryWakeMode();
          },
        );
        return;
      case 'stopped':
        _sttWakeArmed = false;
        _stopSttWakeWatchdog();
        _lastSttWakeReason = event.reason ?? 'stopped';
        if (!_commandInFlight && !_wakeHandling) {
          _sttWakeAcceptInFlight = false;
        }
        return;
      default:
        return;
    }
  }

  Future<void> _syncPrimaryWakeMode() async {
    if (!_useSttWakeEngine) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final shouldRun =
        mounted &&
        lifecycle == AppLifecycleState.resumed &&
        _requireWakeWord &&
        _micGranted &&
        !_commandInFlight &&
        !_followUpActive &&
        !_wakeHandling &&
        !_isSpeaking &&
        !_onboardingDialogInProgress &&
        !_sttService.isListening &&
        !_manualTextReadInProgress;
    if (shouldRun) {
      if (_sttWakeUnavailable && _sttWakeUnavailableSince != null) {
        final cooldownMs = DateTime.now()
            .difference(_sttWakeUnavailableSince!)
            .inMilliseconds;
        if (cooldownMs >= _sttWakeUnavailableRetryMs) {
          _sttWakeUnavailable = false;
          _sttWakeUnavailableSince = null;
          _sttWakeInitialized = false;
          appLog('[STTWake] retry_unavailable cooldown_ms=$cooldownMs');
        }
      }
      await _initializeSttWakeIfNeeded();
      if (!_sttWakeUnavailable) {
        _stopWakeFallbackLoop();
        await _stopLegacyNativeWake(reason: 'stt_primary');
        _setCircleState(CircleState.wake);
        final started = await _startSttWake(reason: 'sync');
        if (started) {
          return;
        }
      }
      await _stopSttWake(reason: 'stt_unavailable', cancel: true);
      _setCircleState(CircleState.wake);
      final nativeStarted = await _startLegacyNativeWake(
        reason: 'stt_unavailable',
      );
      if (nativeStarted) {
        _stopWakeFallbackLoop();
        return;
      }
      if (_sttWakeLegacyFallbackEnabled &&
          _micGranted &&
          lifecycle == AppLifecycleState.resumed &&
          !_onboardingDialogInProgress) {
        _startWakeFallbackLoop();
      } else {
        _stopWakeFallbackLoop();
      }
      return;
    }
    await _stopSttWake(reason: 'sync_blocked', cancel: true);
    await _stopLegacyNativeWake(reason: 'sync_blocked');
    if (_sttWakeUnavailable &&
        _sttWakeLegacyFallbackEnabled &&
        _micGranted &&
        lifecycle == AppLifecycleState.resumed &&
        !_onboardingDialogInProgress) {
      _startWakeFallbackLoop();
    } else {
      _stopWakeFallbackLoop();
    }
  }

  void _applyInteractionLanguage(
    AppLanguage language, {
    required String reason,
  }) {
    if (_interactionLanguage == language) {
      _openAi.setLanguage(language);
      _sttService.setLanguage(language);
      _navigationController.setLanguage(language);
      return;
    }
    _interactionLanguage = language;
    _interactionLanguageUpdatedAt = DateTime.now();
    _openAi.setLanguage(language);
    _sttService.setLanguage(language);
    _navigationController.setLanguage(language);
    appLog('[OpenAI] interaction_language=${language.name}');
    appLog('[VoiceLang] pinned=${language.name} reason=$reason');
    if (mounted) {
      unawaited(_configureTtsForLanguage(language));
    }
  }

  void _applyDetectedInteractionLanguage(
    SpokenLanguageDetectionResult result,
    String transcript, {
    required bool forDialogSession,
  }) {
    appLog('[VoiceLang] transcript="${_truncateForLog(transcript)}"');
    appLog(
      '[VoiceLang] detected=${result.language.name} '
      'confidence=${result.confidence.name} reason=${result.reason}',
    );

    var shouldApply = false;
    switch (result.confidence) {
      case SpokenLanguageConfidence.high:
        shouldApply = true;
        break;
      case SpokenLanguageConfidence.medium:
        shouldApply =
            result.language == _interactionLanguage ||
            _router.route(transcript).modeIntent !=
                AssistantModeIntent.unknown ||
            _detectModeSwitchByText(transcript) != null;
        break;
      case SpokenLanguageConfidence.low:
        shouldApply = false;
        break;
    }

    if (!shouldApply && !result.explicitSwitch) {
      return;
    }

    if (forDialogSession) {
      _interactionLanguagePinned = true;
    }
    _applyInteractionLanguage(
      result.language,
      reason: result.explicitSwitch ? 'explicit_switch' : result.reason,
    );
  }

  String _voiceLanguageSwitchAck() {
    return _voiceText(
      ru: 'Хорошо, буду отвечать по-русски.',
      kk: 'Жақсы, қазақша жауап беремін.',
    );
  }

  Future<void> _initTts() async {
    await _configureTtsForLanguage(_interactionLanguage);
    await _tts.setSpeechRate(_ttsSpeechRate);
    await _tts.setPitch(_ttsPitch);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _configureTtsForLanguage(AppLanguage language) async {
    final localeCode = language == AppLanguage.kk ? 'kk-KZ' : 'ru-RU';
    await _configureTtsForLocaleCode(localeCode);
  }

  Future<void> _configureTtsForLocaleCode(String localeCode) async {
    final appliedLocale = await _applyTtsLocaleCode(localeCode);
    await _applyPreferredVoiceForLocaleCode(appliedLocale);
  }

  Future<String> _applyTtsLocaleCode(String localeCode) async {
    const fallback = 'ru-RU';
    final preferred = localeCode.trim().isEmpty ? fallback : localeCode.trim();
    try {
      final rawLanguages = await _tts.getLanguages;
      final available = <String>{};
      if (rawLanguages is List) {
        for (final item in rawLanguages) {
          final value = item?.toString().trim();
          if (value != null && value.isNotEmpty) {
            available.add(value.toLowerCase());
          }
        }
      }
      final preferredLower = preferred.toLowerCase();
      final preferredPrefix = preferredLower.split(RegExp('[-_]')).first;
      String applied = fallback;
      if (available.isEmpty) {
        applied = preferred;
      } else if (available.contains(preferredLower)) {
        applied = preferred;
      } else {
        final prefixMatch = available.cast<String?>().firstWhere(
          (value) => value != null && value.startsWith(preferredPrefix),
          orElse: () => null,
        );
        if (prefixMatch != null) {
          applied = prefixMatch;
        }
      }
      await _tts.setLanguage(applied);
      _ttsConfiguredLocaleCode = applied;
      _ttsConfiguredLanguage = applied.toLowerCase().startsWith('kk')
          ? AppLanguage.kk
          : AppLanguage.ru;
      return applied;
    } catch (_) {
      try {
        await _tts.setLanguage(fallback);
        _ttsConfiguredLanguage = AppLanguage.ru;
        _ttsConfiguredLocaleCode = fallback;
      } catch (_) {}
      return fallback;
    }
  }

  Future<void> _applyPreferredVoiceForLocaleCode(String localeCode) async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List || raw.isEmpty) return;
      final voices = <Map<String, String>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final name = item['name']?.toString().trim() ?? '';
        final locale = item['locale']?.toString().trim() ?? '';
        if (name.isEmpty || locale.isEmpty) continue;
        voices.add({'name': name, 'locale': locale});
      }
      if (voices.isEmpty) return;

      final selected = _selectBestVoiceForLocaleCode(voices, localeCode);
      if (selected == null) return;
      await _tts.setVoice(selected);
      appLog(
        '[TTS] voice selected: ${selected['name']} (${selected['locale']})',
      );
    } catch (_) {}
  }

  Future<void> _ensureTtsLocaleForCurrentMode({bool force = false}) async {
    final desiredLocaleCode =
        _assistantMode == AssistantMode.textReader &&
            _voiceLanguage == AppLanguage.ru
        ? 'ru-RU'
        : (_voiceLanguage == AppLanguage.kk ? 'kk-KZ' : 'ru-RU');
    if (!force &&
        _ttsConfiguredLocaleCode.toLowerCase() ==
            desiredLocaleCode.toLowerCase()) {
      return;
    }
    await _configureTtsForLocaleCode(desiredLocaleCode);
    if (_voiceLanguage == AppLanguage.kk &&
        !_ttsConfiguredLocaleCode.toLowerCase().startsWith('kk')) {
      appLog('[TTS] kk fallback -> ru');
    }
    appLog('[TTS] locale ensured: ${desiredLocaleCode.split('-').first}');
  }

  Future<void> _ensureTtsLocaleForReadResult(
    OnDeviceTextReadResult result, {
    required bool autoRead,
  }) async {
    final resolvedText = _resolveManualSpeechText(result);
    await _ensureTtsLocaleForSpokenText(resolvedText, autoRead: autoRead);
  }

  Future<void> _ensureTtsLocaleForSpokenText(
    String spokenText, {
    required bool autoRead,
  }) async {
    // In Text Reader mode, we want natural pronunciation for English even in auto-tick path
    final inTextReaderMode = _assistantMode == AssistantMode.textReader;
    final useEnglishTts =
        (!autoRead || inTextReaderMode) &&
        TextReadingNormalizer.shouldUseEnglishTts(spokenText);

    if (useEnglishTts) {
      await _configureTtsForLocaleCode('en-US');
      appLog('[TTS] locale ensured: en');
      return;
    }
    await _ensureTtsLocaleForCurrentMode(force: true);
  }

  Map<String, String>? _selectBestVoiceForLocaleCode(
    List<Map<String, String>> voices,
    String localeCode,
  ) {
    final localePrefix = localeCode.toLowerCase().split(RegExp('[-_]')).first;
    if (localePrefix == 'ru' || localePrefix == 'kk') {
      return _selectBestVoice(
        voices,
        localePrefix == 'kk' ? AppLanguage.kk : AppLanguage.ru,
      );
    }

    Map<String, String>? best;
    var bestScore = -1 << 20;
    for (final voice in voices) {
      final locale = (voice['locale'] ?? '').toLowerCase();
      final name = (voice['name'] ?? '').toLowerCase();
      if (locale.isEmpty || name.isEmpty) continue;

      var score = 0;
      if (locale.startsWith(localePrefix)) score += 160;
      if (locale == localeCode.toLowerCase()) score += 40;
      if (_looksLikeFemaleVoiceName(name)) score += 12;

      // Prioritize modern high-quality voices to avoid "robotic" sound
      if (name.contains('neural') || name.contains('natural')) score += 60;
      if (name.contains('premium') || name.contains('enhanced')) score += 40;
      if (name.contains('multilingual')) score += 20;
      if (name.contains('network')) score += 10;

      if (score > bestScore) {
        bestScore = score;
        best = voice;
      }
    }
    return best;
  }

  Map<String, String>? _selectBestVoice(
    List<Map<String, String>> voices,
    AppLanguage language,
  ) {
    final preferredName = _ttsPreferredVoiceRu.trim().toLowerCase();
    final localePrefix = language == AppLanguage.kk ? 'kk' : 'ru';
    Map<String, String>? best;
    var bestScore = -1 << 20;

    for (final voice in voices) {
      final locale = (voice['locale'] ?? '').toLowerCase();
      final name = (voice['name'] ?? '').toLowerCase();
      if (locale.isEmpty || name.isEmpty) continue;

      var score = 0;
      if (locale.startsWith('$localePrefix-')) {
        score += 200;
      } else if (locale.startsWith(localePrefix)) {
        score += 160;
      } else if (locale.startsWith('ru')) {
        score += 60;
      }

      if (preferredName.isNotEmpty && name.contains(preferredName)) {
        score += 900;
      }

      if (_looksLikeFemaleVoiceName(name)) score += 90;
      if (_looksLikeMaleVoiceName(name)) score -= 90;
      if (name.contains('neural') || name.contains('natural')) score += 60;
      if (name.contains('premium') || name.contains('enhanced')) score += 40;
      if (name.contains('multilingual')) score += 20;
      if (name.contains('network')) score += 10;

      if (score > bestScore) {
        bestScore = score;
        best = voice;
      }
    }

    return best;
  }

  bool _looksLikeFemaleVoiceName(String value) {
    const femaleHints = <String>[
      'female',
      'woman',
      'alena',
      'alyona',
      'anna',
      'daria',
      'elena',
      'irina',
      'ksenia',
      'olga',
      'sofia',
      'svetlana',
      'жан',
    ];
    for (final hint in femaleHints) {
      if (value.contains(hint)) return true;
    }
    return false;
  }

  bool _looksLikeMaleVoiceName(String value) {
    const maleHints = <String>[
      'male',
      'man',
      'alexander',
      'anton',
      'maxim',
      'dmitry',
      'иван',
      'sergey',
      'yuri',
    ];
    for (final hint in maleHints) {
      if (value.contains(hint)) return true;
    }
    return false;
  }

  Future<void> _initVibration() async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      _vibrationAvailable = hasVibrator;
    } catch (_) {
      _vibrationAvailable = false;
    }
  }

  Future<void> _vibrateStart() async {
    if (!_vibrationAvailable) return;
    // мягкий короткий двойной импульс
    try {
      await Vibration.vibrate(pattern: [0, 40, 60, 40], amplitude: 64);
    } catch (_) {}
  }

  Future<void> _vibrateThinking() async {
    if (!_vibrationAvailable) return;
    // мягкий одиночный импульс
    try {
      await Vibration.vibrate(duration: 35, amplitude: 50);
    } catch (_) {}
  }

  Future<void> _vibrateEnd() async {
    if (!_vibrationAvailable) return;
    // мягкий “затухающий” двойной импульс
    try {
      await Vibration.vibrate(pattern: [0, 60, 80, 30], amplitude: 40);
    } catch (_) {}
  }

  Future<void> _playWakeCue() async {
    if (!_wakeCueEnabled) return;
    await _wakeCueService.play();
  }

  Future<void> _playThinkingCue() async {
    if (!_audioCuesEnabled) return;
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/thinking.wav'), volume: 0.6);
    } catch (_) {}
  }

  void _setCircleState(CircleState state) {
    if (_circleState == state) return;
    setState(() => _circleState = state);
    switch (state) {
      case CircleState.wake:
        _modeOrchestrator.setSubState('wake');
        break;
      case CircleState.listening:
        _modeOrchestrator.setSubState('listening');
        break;
      case CircleState.thinking:
        _modeOrchestrator.setSubState('thinking');
        break;
      case CircleState.speaking:
        _modeOrchestrator.setSubState('speaking');
        break;
      case CircleState.end:
      case CircleState.idle:
        _modeOrchestrator.setSubState('idle');
        break;
    }
  }

  void _restoreWakeStateIfIdle() {
    if (!mounted) return;
    if (!_micGranted) {
      _setCircleState(CircleState.idle);
      return;
    }
    if (_commandInFlight ||
        _followUpActive ||
        _wakeHandling ||
        _isSpeaking ||
        _sttService.isListening ||
        _gptStatus == GptStatus.loading) {
      return;
    }
    _interactionLanguagePinned = false;
    _setCircleState(CircleState.wake);
    _maybeStartOnboardingDialog();
    if (_useSttWakeEngine && !_onboardingDialogInProgress) {
      unawaited(_syncPrimaryWakeMode());
    }
  }

  bool get _canPromptOnboardingNow =>
      mounted &&
      _micGranted &&
      !_commandInFlight &&
      !_followUpActive &&
      !_wakeHandling &&
      !_isSpeaking &&
      !_sttService.isListening &&
      !_manualTextReadInProgress &&
      _gptStatus != GptStatus.loading &&
      !_onboardingDialogInProgress;

  void _syncOnboardingReminderTimer() {
    _onboardingReminderTimer?.cancel();
    _onboardingReminderTimer = null;
    if (!_personalizationReady ||
        !_personalizationController.onboardingRequired) {
      return;
    }
    final until = _personalizationController
        .snapshot
        .profile
        .onboardingDeferredUntilEpochMs;
    if (until == null) return;
    final delayMs = until - DateTime.now().millisecondsSinceEpoch;
    if (delayMs <= 0) {
      unawaited(_resumeDeferredOnboardingIfReady());
      return;
    }
    _onboardingReminderTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_resumeDeferredOnboardingIfReady());
    });
  }

  Future<void> _resumeDeferredOnboardingIfReady() async {
    if (!mounted ||
        !_personalizationReady ||
        !_personalizationController.onboardingRequired) {
      return;
    }
    await _personalizationController.startOrResumeOnboarding();
    if (!mounted) return;
    _syncOnboardingReminderTimer();
    if (_personalizationController.onboardingActive) {
      if (!_showOnboardingOverlay) {
        setState(() {
          _showOnboardingOverlay = true;
        });
      }
      if (_canPromptOnboardingNow) {
        _maybeStartOnboardingDialog();
      }
    }
  }

  Future<void> _deferOnboarding(
    OnboardingReminderRequest request, {
    bool speakAck = true,
  }) async {
    await _personalizationController.deferOnboarding(request.delay);
    if (!mounted) return;
    _syncOnboardingReminderTimer();
    setState(() {
      _showOnboardingOverlay = false;
    });
    if (!speakAck) return;
    await _speakOnboardingLine(
      _voiceText(
        ru: 'Хорошо, напомню ${request.labelRu}.',
        kk: 'Жақсы, ${request.labelKk} қайта еске саламын.',
      ),
    );
  }

  Future<bool> _ensureNotificationPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      var status = await Permission.notification.status;
      if (status.isGranted || status.isLimited) return true;
      status = await _runSerializedPermissionRequest(
        () => Permission.notification.request(),
      );
      return status.isGranted || status.isLimited;
    } catch (e) {
      appLog('[Perm] notification request failed: $e');
      return false;
    }
  }

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<bool> _ensureMicPermission() async {
    try {
      var status = await Permission.microphone.status;
      if (!mounted) return false;
      if (!status.isGranted) {
        status = await _runSerializedPermissionRequest(
          () => Permission.microphone.request(),
        );
      }
      if (!mounted) return false;

      if (status.isGranted) {
        setState(() {
          _micGranted = true;
          _micMessage = _l10n.micAvailable;
        });
        return true;
      }

      setState(() {
        _micGranted = false;
        _micMessage = status.isPermanentlyDenied
            ? _l10n.micAccessDenied
            : _l10n.micAccessRequired;
      });
      return false;
    } catch (e) {
      appLog('[Perm] microphone request failed: $e');
      if (!mounted) return false;
      setState(() {
        _micGranted = false;
        _micMessage = _l10n.micAccessRequired;
      });
      return false;
    }
  }

  Future<void> _initMicAndWake() async {
    PermissionStatus status;
    try {
      status = await _runSerializedPermissionRequest(
        () => Permission.microphone.request(),
      );
    } catch (e) {
      appLog('[Perm] initial microphone request failed: $e');
      if (!mounted) return;
      setState(() {
        _micGranted = false;
        _micMessage = _l10n.micAccessRequired;
      });
      return;
    }
    if (!mounted) return;

    if (status.isGranted) {
      unawaited(_ensureNotificationPermission());
      setState(() {
        _micGranted = true;
        _micMessage = _l10n.micAvailable;
      });
      if (_requireWakeWord) {
        _wakeWordOnlyMode = true;
        _stopWakeFallbackLoop();
        _setCircleState(CircleState.wake);
        if (_useSttWakeEngine) {
          await _initializeSttWakeIfNeeded();
          await _syncPrimaryWakeMode();
        } else {
          await _wakeService.start();
        }
      } else if (_alwaysDialogMode) {
        await _stopPrimaryWake(reason: 'always_dialog_init');
        _startWakeFallbackLoop();
      } else {
        _setCircleState(CircleState.wake);
        if (_useSttWakeEngine) {
          await _initializeSttWakeIfNeeded();
          await _syncPrimaryWakeMode();
        } else {
          await _wakeService.start();
        }
      }
      _maybeStartOnboardingDialog();
    } else if (status.isPermanentlyDenied) {
      setState(() {
        _micGranted = false;
        _micMessage = _l10n.micAccessDenied;
      });
    } else {
      setState(() {
        _micGranted = false;
        _micMessage = _l10n.micAccessRequired;
      });
    }
  }

  Future<void> _initCameraLive() async {
    if (!_modeNeedsLiveCamera(_assistantMode)) {
      await _stopCameraStream(reason: 'mode_without_camera');
      return;
    }
    if (_cameraInitInProgress) return;
    _cameraInitInProgress = true;
    try {
      var status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await _runSerializedPermissionRequest(
          () => Permission.camera.request(),
        );
      }
      if (!mounted) return;
      if (status.isGranted) {
        setState(() {
          _cameraGranted = true;
          _cameraMessage = _l10n.cameraAvailable;
          _cameraError = '';
        });
        await _startCameraStream(reason: 'init_camera_live');
      } else if (status.isPermanentlyDenied) {
        setState(() {
          _cameraGranted = false;
          _cameraMessage = _l10n.cameraAccessDenied;
        });
      } else {
        setState(() {
          _cameraGranted = false;
          _cameraMessage = _l10n.cameraAccessRequired;
        });
      }
    } catch (e) {
      appLog('[Perm] camera request failed: $e');
      if (!mounted) return;
      setState(() {
        _cameraGranted = false;
        _cameraMessage = _l10n.cameraAccessRequired;
      });
    } finally {
      _cameraInitInProgress = false;
    }
  }

  Future<List<CameraDescription>> _getAvailableCameras() async {
    final cached = _cachedCameras;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    final cameras = await availableCameras();
    if (cameras.isNotEmpty) {
      _cachedCameras = cameras;
    }
    return cameras;
  }

  Future<void> _startCameraStream({String reason = 'unspecified'}) async {
    if (_cameraStartInProgress) return;
    _cameraStartInProgress = true;
    CameraController? createdController;
    try {
      final existing = _cameraController;
      if (existing != null) {
        if (existing.value.isInitialized && existing.value.isStreamingImages) {
          if (!mounted) return;
          setState(() {
            _cameraStreaming = true;
            _cameraMessage = _l10n.cameraLiveOn;
            _cameraError = '';
          });
          appLog('[Camera] stream already running (reason=$reason)');
          unawaited(_syncHeavyServices());
          return;
        }
        if (existing.value.isInitialized) {
          try {
            await existing.startImageStream(_onCameraImage);
            if (!mounted) return;
            setState(() {
              _cameraStreaming = true;
              _cameraMessage = _l10n.cameraLiveOn;
              _cameraError = '';
            });
            appLog(
              '[Camera] stream started on existing controller (reason=$reason)',
            );
            unawaited(_syncHeavyServices());
            return;
          } catch (e) {
            appLog(
              '[Camera] existing controller start failed; recreating '
              '(reason=$reason): $e',
            );
          }
        } else {
          appLog(
            '[Camera] existing controller not initialized; recreating '
            '(reason=$reason)',
          );
        }

        try {
          if (existing.value.isStreamingImages) {
            await existing.stopImageStream();
          }
        } catch (_) {}
        try {
          await existing.dispose();
        } catch (_) {}
        if (identical(_cameraController, existing)) {
          _cameraController = null;
        }
      }

      var cameras = await _getAvailableCameras();
      if (cameras.isEmpty) {
        cameras = await availableCameras();
        if (cameras.isNotEmpty) {
          _cachedCameras = cameras;
        }
      }
      if (cameras.isEmpty) {
        setState(() {
          _cameraError = _l10n.cameraNotFound;
        });
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _lastFrame = null;
      _lastFrameAt = null;
      _lastFrameMs = 0;
      _cameraProcessedFrames = 0;
      _cameraDroppedFrames = 0;
      _cameraPreviewFps = 0;
      _cameraFpsWindowStartedMs = 0;
      createdController = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        fps: 30,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await createdController.initialize();
      await createdController.startImageStream(_onCameraImage);
      _cameraController = createdController;
      createdController = null;

      if (!mounted) return;
      setState(() {
        _cameraStreaming = true;
        _cameraMessage = _l10n.cameraLiveOn;
        _cameraError = '';
      });
      appLog('[Camera] stream started on new controller (reason=$reason)');
      unawaited(_syncHeavyServices());
    } catch (e) {
      final stale = createdController;
      if (stale != null) {
        try {
          if (stale.value.isStreamingImages) {
            await stale.stopImageStream();
          }
        } catch (_) {}
        try {
          await stale.dispose();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _cameraStreaming = false;
        _cameraError = _l10n.cameraStartFailed('$e');
        _cameraMessage = _l10n.cameraLiveOff;
      });
      appLog('[Camera] stream start failed (reason=$reason): $e');
      unawaited(_syncHeavyServices());
    } finally {
      _cameraStartInProgress = false;
    }
  }

  Future<void> _stopCameraStream({String reason = 'unspecified'}) async {
    final controller = _cameraController;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      appLog('[Camera] stream stopped (reason=$reason)');
    } catch (e) {
      appLog('[Camera] stream stop error (reason=$reason): $e');
    }
    if (mounted) {
      setState(() {
        _cameraStreaming = false;
        _cameraMessage = _l10n.cameraLiveOff;
      });
    }
    unawaited(_syncHeavyServices());
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    _cameraStreaming = false;
    _cameraStartInProgress = false;
    _lastFrame = null;
    _lastFrameAt = null;
    _lastFrameMs = 0;
    _cameraProcessedFrames = 0;
    _cameraDroppedFrames = 0;
    _cameraPreviewFps = 0;
    _cameraFpsWindowStartedMs = 0;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
    unawaited(_syncHeavyServices());
  }

  void _startCameraKeepAlive() {
    _cameraKeepAliveTimer?.cancel();
    _cameraKeepAliveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      if (!_modeNeedsLiveCamera(_assistantMode)) return;
      if (!_cameraGranted) return;
      if (_cameraStreaming || _cameraStartInProgress || _cameraInitInProgress) {
        return;
      }
      unawaited(_startCameraStream(reason: 'keep_alive'));
    });
  }

  void _onCameraImage(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (image.planes.length < 3) return;
    if (now - _lastFrameMs < _frameCaptureThrottleMs) {
      if (_featureFlags.developerDiagnosticsEnabled) {
        _cameraDroppedFrames++;
      }
      return;
    }
    _lastFrameMs = now;
    _lastFrame = _cameraFrameStore.update(
      image,
      rotationDegrees: _cameraImageRotationDegrees(),
    );
    if (_lastFrame == null) return;
    _lastFrameAt = DateTime.now();
    if (_featureFlags.developerDiagnosticsEnabled) {
      _cameraProcessedFrames++;
      if (_cameraFpsWindowStartedMs == 0) {
        _cameraFpsWindowStartedMs = now;
      }
      final elapsed = now - _cameraFpsWindowStartedMs;
      if (elapsed >= 1000) {
        if (mounted) {
          setState(() {
            _cameraPreviewFps = ((_cameraProcessedFrames * 1000) / elapsed)
                .round();
          });
        } else {
          _cameraPreviewFps = ((_cameraProcessedFrames * 1000) / elapsed)
              .round();
        }
        _cameraProcessedFrames = 0;
        _cameraFpsWindowStartedMs = now;
      }
    }

    if (now - _lastPerceptionEventMs >= 900) {
      _lastPerceptionEventMs = now;
      _perceptionEventBus.publish(
        PerceptionEvent(
          id: 'frame_$now',
          type: PerceptionEventType.detection,
          timestampMs: now,
          confidence: 1,
          label: 'live_frame',
          meta: <String, Object?>{
            'mode': _assistantMode.name,
            'width': image.width,
            'height': image.height,
          },
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncHeavyServices());
      unawaited(_resumeDeferredOnboardingIfReady());
      if (_micGranted) {
        if (_useSttWakeEngine) {
          unawaited(_syncPrimaryWakeMode());
        } else if (_requireWakeWord &&
            _wakeService.state.value.status != WakeWordStatus.error) {
          unawaited(_wakeService.start());
          _stopWakeFallbackLoop();
        } else if (_wakeService.state.value.status == WakeWordStatus.error) {
          _scheduleWakeRecoveryIfNeeded(_wakeService.state.value);
          _syncWakeFallbackMode(_wakeService.state.value);
        } else if (_alwaysDialogMode) {
          _startWakeFallbackLoop();
        }
      }
      if (_featureFlags.aggressiveBackgroundCamera ||
          _modeNeedsLiveCamera(_assistantMode)) {
        unawaited(_initCameraLive());
      }
      if (_featureFlags.aggressiveBackgroundCamera) {
        unawaited(_startRuntimeServiceBestEffort(reason: 'lifecycle_resumed'));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_stopCameraStream(reason: 'lifecycle_${state.name}'));
      unawaited(_stopSttWake(reason: 'lifecycle_${state.name}'));
      _sttWakeInitialized = false;
      _stopWakeFallbackLoop();
      _wakeRecoveryTimer?.cancel();
      _wakeRecoveryTimer = null;
      if (_featureFlags.aggressiveBackgroundCamera) {
        unawaited(
          _startRuntimeServiceBestEffort(reason: 'lifecycle_${state.name}'),
        );
      } else {
        unawaited(
          _stopRuntimeServiceBestEffort(reason: 'lifecycle_${state.name}'),
        );
      }
    } else if (state == AppLifecycleState.inactive) {
      _textReaderLoopTimer?.cancel();
      _textReaderLoopTimer = null;
      unawaited(_syncReflexLoop());
      unawaited(_stopSttWake(reason: 'lifecycle_${state.name}'));
      _sttWakeInitialized = false;
      _stopWakeFallbackLoop();
    }
  }

  void _handleSttStateChange() {
    final current = _sttService.state.value;
    if (current.finalWords.isNotEmpty &&
        current.finalWords != _lastLoggedFinal) {
      _lastLoggedFinal = current.finalWords;
      appLog('[STT] final: ${current.finalWords}');
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleWakeStateChange() {
    if (_useSttWakeEngine) {
      if (mounted) {
        setState(() {});
      }
      return;
    }
    final wake = _wakeService.state.value;
    if (wake.status == WakeWordStatus.error) {
      _wakeErrorSince ??= DateTime.now();
      _scheduleWakeRecoveryIfNeeded(wake);
      _wakeFallbackEscalationTimer ??= Timer(_wakeFallbackErrorGrace, () {
        _wakeFallbackEscalationTimer = null;
        if (!mounted) return;
        _syncWakeFallbackMode(_wakeService.state.value);
      });
    } else {
      _wakeErrorSince = null;
      _wakeFallbackEscalationTimer?.cancel();
      _wakeFallbackEscalationTimer = null;
      _wakeRecoveryAttempts = 0;
      _lastWakeRecoveryAttemptAt = null;
    }
    final signature =
        '${wake.status}|${wake.keywordMode}|${wake.keywordLabel}|${wake.lastError ?? ''}';
    if (signature != _lastLoggedWakeSignature) {
      _lastLoggedWakeSignature = signature;
      appLog(
        '[Wake] state=${wake.status.name} mode=${wake.keywordMode} '
        'keywords=${wake.keywordLabel} error=${wake.lastError ?? '-'}',
      );
    }
    _syncWakeFallbackMode(wake);
    if (mounted) {
      setState(() {});
    }
  }

  bool _shouldPreferWakeRecovery(WakeWordState wake) {
    if (!_micGranted || _onboardingDialogInProgress) return false;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return false;
    }
    if (wake.status != WakeWordStatus.error) return false;
    return _requireWakeWord || _wakeWordOnlyMode;
  }

  void _scheduleWakeRecoveryIfNeeded(WakeWordState wake) {
    if (!_shouldPreferWakeRecovery(wake)) return;
    if (_wakeRecoveryInProgress || _wakeRecoveryTimer != null) return;
    if (_wakeRecoveryAttempts >= _wakeRecoveryMaxAttempts) return;
    if (_lastWakeRecoveryAttemptAt != null &&
        DateTime.now().difference(_lastWakeRecoveryAttemptAt!) <
            _wakeRecoveryRetryCooldown) {
      return;
    }
    appLog(
      '[WakeRecovery] scheduled attempt=${_wakeRecoveryAttempts + 1} '
      'in=${_wakeRecoveryRetryCooldown.inMilliseconds}ms',
    );
    _wakeRecoveryTimer = Timer(_wakeRecoveryRetryCooldown, () {
      _wakeRecoveryTimer = null;
      unawaited(_attemptWakeRecovery());
    });
  }

  Future<void> _attemptWakeRecovery() async {
    if (_wakeRecoveryInProgress || !mounted) return;
    final wake = _wakeService.state.value;
    if (!_shouldPreferWakeRecovery(wake)) return;
    if (_wakeRecoveryAttempts >= _wakeRecoveryMaxAttempts) {
      _syncWakeFallbackMode(wake);
      return;
    }
    _wakeRecoveryInProgress = true;
    _wakeRecoveryAttempts += 1;
    _lastWakeRecoveryAttemptAt = DateTime.now();
    final restartListening =
        !_wakeHandling &&
        !_commandInFlight &&
        !_followUpActive &&
        !_sttService.isListening;
    appLog(
      '[WakeRecovery] attempt=$_wakeRecoveryAttempts '
      'restart=$restartListening',
    );
    try {
      final recovered = await _wakeService.recover(
        restartListening: restartListening,
      );
      if (!mounted) return;
      if (recovered) {
        _wakeErrorSince = null;
        _wakeFallbackEscalationTimer?.cancel();
        _wakeFallbackEscalationTimer = null;
        _wakeRecoveryAttempts = 0;
        _lastWakeRecoveryAttemptAt = null;
        appLog('[WakeRecovery] recovered');
        if ((_requireWakeWord || _wakeWordOnlyMode) &&
            !_sttService.isListening) {
          _setCircleState(CircleState.wake);
        }
        _stopWakeFallbackLoop();
        return;
      }
      appLog('[WakeRecovery] failed attempt=$_wakeRecoveryAttempts');
      final currentWake = _wakeService.state.value;
      if (currentWake.status == WakeWordStatus.error &&
          _wakeRecoveryAttempts < _wakeRecoveryMaxAttempts) {
        _scheduleWakeRecoveryIfNeeded(currentWake);
      }
      _syncWakeFallbackMode(currentWake);
    } finally {
      _wakeRecoveryInProgress = false;
    }
  }

  void _handleModeOrchestratorChange() {
    if (!mounted) return;
    setState(() {});
    unawaited(_syncHeavyServices());
  }

  Future<void> _syncHeavyServices() async {
    await _reflexEngine.setVoicePriority(_voicePriorityWindowActive);
    _syncTextReaderLoop();
    await _syncReflexLoop();
  }

  void _enterVoicePriorityWindow({required String reason}) {
    if (_voicePriorityWindowActive) return;
    _voicePriorityWindowActive = true;
    appLog('[VoicePriority] enter reason=$reason');
    unawaited(_syncHeavyServices());
    if (_useSttWakeEngine) {
      unawaited(_syncPrimaryWakeMode());
    }
  }

  void _exitVoicePriorityWindow({required String reason}) {
    if (!_voicePriorityWindowActive) return;
    _voicePriorityWindowActive = false;
    appLog('[VoicePriority] exit reason=$reason');
    unawaited(_syncHeavyServices());
    if (_useSttWakeEngine) {
      unawaited(_syncPrimaryWakeMode());
    }
  }

  Future<void> _syncReflexLoop() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final shouldRun =
        lifecycle == AppLifecycleState.resumed &&
        _featureFlags.reflexEnabled &&
        _featureFlags.safetyEnabled &&
        _cameraGranted &&
        _cameraStreaming;
    if (shouldRun) {
      await _reflexEngine.setSafetyLevel(_currentReflexSafetyLevel());
      await _reflexEngine.start();
    } else {
      await _reflexEngine.stop();
    }
  }

  void _handleReflexOverlayChanged(List<ReflexDetection> detections) {
    if (!mounted) return;
    final entries = detections
        .map(
          (detection) => BBoxOverlayEntry(
            bbox: detection.bbox,
            label: _reflexDisplayLabel(detection.hazardLabel),
            confidence: detection.confidence,
            severity: switch (detection.severity) {
              ReflexSeverity.high => BBoxSeverity.danger,
              ReflexSeverity.medium => BBoxSeverity.medium,
              ReflexSeverity.safe => BBoxSeverity.safe,
            },
            distanceM: detection.distanceM,
          ),
        )
        .toList(growable: false);
    ReflexDetection? latestHazard;
    for (final detection in detections) {
      if (detection.severity != ReflexSeverity.safe) {
        latestHazard = detection;
        break;
      }
    }
    setState(() {
      _latestReflexDetections = detections;
      _reflexBBoxes = entries;
      _latestHazardHint = latestHazard == null
          ? ''
          : _reflexDisplayLabel(latestHazard.hazardLabel);
    });
  }

  Future<void> _handleReflexAlert(ReflexAlert alert) async {
    if (_voicePriorityWindowActive ||
        _wakeHandling ||
        _commandInFlight ||
        _followUpActive ||
        _isSpeaking) {
      return;
    }
    final hazard = _reflexDisplayLabel(alert.hazardLabel).toLowerCase();
    final direction = switch (alert.direction) {
      'left' => _voiceText(ru: 'слева', kk: 'сол жақта'),
      'right' => _voiceText(ru: 'справа', kk: 'оң жақта'),
      _ => _voiceText(ru: 'прямо перед вами', kk: 'тура алдында'),
    };
    final action = switch (alert.recommendedAction) {
      'step_right' => _voiceText(ru: 'шаг вправо', kk: 'оңға қадам жасаңыз'),
      'step_left' => _voiceText(ru: 'шаг влево', kk: 'солға қадам жасаңыз'),
      _ => _voiceText(ru: 'шаг назад', kk: 'артқа шегініңіз'),
    };
    final line = _voiceText(
      ru: 'Опасность $direction, $action.',
      kk: 'Қауіп $direction, $action.',
    );
    _latestHazardHint = hazard;
    await _speak(line);
  }

  void _handleReflexMetrics(ReflexRuntimeMetrics metrics) {
    if (!_featureFlags.developerDiagnosticsEnabled || !mounted) return;
    setState(() {
      _reflexInferenceLatencyMs = metrics.inferenceLatencyMs;
      _reflexDetectionsCount = metrics.detections;
    });
  }

  ReflexSafetyLevel _currentReflexSafetyLevel() {
    final perception = _currentModeDescriptor().perception;
    return perception.safetyMax
        ? ReflexSafetyLevel.max
        : ReflexSafetyLevel.normal;
  }

  String _reflexDisplayLabel(String hazardLabel) {
    switch (hazardLabel) {
      case 'car':
        return _voiceText(ru: 'машина', kk: 'көлік');
      case 'bike':
        return _voiceText(ru: 'велосипед', kk: 'велосипед');
      case 'hot_surface':
        return _voiceText(ru: 'плита', kk: 'пеш');
      case 'sharp_object':
        return _voiceText(ru: 'острый предмет', kk: 'өткір зат');
      case 'stairs_edge':
        return _voiceText(ru: 'край лестницы', kk: 'баспалдақ жиегі');
      default:
        return hazardLabel.replaceAll('_', ' ');
    }
  }

  Future<CameraFrameSnapshot?> _captureLatestFrameForReflex() async {
    final frame = _lastFrame;
    final frameAt = _lastFrameAt;
    if (!_cameraStreaming || frame == null || frameAt == null) return null;
    final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
    if (ageMs > 900) return null;
    return frame;
  }

  Future<void> _startRuntimeServiceBestEffort({required String reason}) async {
    await _ensureNotificationPermission();
    final started = await AndroidRuntimeService.start(reason: reason);
    if (!mounted) return;
    _runtimeServiceRunning = started || _runtimeServiceRunning;
    if (started) {
      appLog('[RuntimeService] started (reason=$reason)');
    }
  }

  Future<void> _stopRuntimeServiceBestEffort({required String reason}) async {
    final stopped = await AndroidRuntimeService.stop(reason: reason);
    if (!mounted) return;
    if (stopped) {
      _runtimeServiceRunning = false;
      appLog('[RuntimeService] stopped (reason=$reason)');
    }
  }

  Future<void> _initPersonalization() async {
    try {
      await _personalizationController.init();
      if (!mounted) return;
      setState(() {
        _personalizationReady = true;
        _showOnboardingOverlay =
            _personalizationController.onboardingRequired &&
            !_personalizationController.onboardingDeferred;
      });
      if (_personalizationController.onboardingRequired) {
        await _personalizationController.startOrResumeOnboarding();
        if (!mounted) return;
        setState(() {
          _showOnboardingOverlay =
              _personalizationController.onboardingRequired &&
              !_personalizationController.onboardingDeferred;
        });
      }
      _syncOnboardingReminderTimer();
      _maybeStartOnboardingDialog();
    } catch (e) {
      appLog('[Personalization] init error: $e');
    }
  }

  void _handlePersonalizationChange() {
    if (!mounted) return;
    _syncOnboardingReminderTimer();
    setState(() {
      if (!_personalizationController.onboardingRequired ||
          _personalizationController.onboardingDeferred) {
        _showOnboardingOverlay = false;
      } else if (_personalizationController.onboardingActive) {
        _showOnboardingOverlay = true;
      }
    });
    if (_canPromptOnboardingNow) {
      _maybeStartOnboardingDialog();
    }
  }

  Future<void> _handleRouteBuilt(NavigationRouteBuiltEvent event) async {
    try {
      await _personalizationRepository.recordRouteUsage(
        RouteHistoryEntry(
          queryText: event.queryText,
          queryNorm: normalizeText(event.queryText),
          resolvedAddress: event.resolvedAddress,
          destLat: event.destination.latitude,
          destLon: event.destination.longitude,
          source: event.source,
          startedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
          completed: true,
        ),
      );
    } catch (e) {
      appLog('[Personalization] route record error: $e');
    }
  }

  String _adaptNavigationInstruction(String text) {
    if (!_personalizationReady) return text;
    final snapshot = _personalizationController.snapshot;
    final fears = snapshot.activeFearTexts;
    if (fears.isEmpty) return text;

    final intensity = snapshot.profile.warningIntensity;
    final firstFear = fears.first;
    if (intensity >= 3) {
      return _voiceText(
        ru: 'Внимание, учитываю ваш риск "$firstFear": $text',
        kk: 'Абай болыңыз, $firstFear қа байланысты: $text',
      );
    }
    return _voiceText(ru: 'Предупреждение: $text', kk: 'Ескерту: $text');
  }

  void _handleNavigationStateChange() {
    final navState = _navigationController.state.value;
    if (_assistantMode == AssistantMode.navigation && !navState.modeEnabled) {
      _assistantMode = AssistantMode.general;
      _modeOrchestrator.transitionTo(
        _toJanarymMode(_assistantMode),
        subState: 'active',
        autoTriggeredBy: 'nav_mode_disabled',
      );
      unawaited(_initCameraLive());
    }
    _syncNavigationCamera(navState);
    if (mounted) {
      setState(() {});
    }
  }

  void _syncNavigationCamera(NavigationModeState navState) {
    if (!_embeddedMapEnabled) return;
    final controller = _yandexMapController;
    if (controller == null) return;
    if (_assistantMode != AssistantMode.navigation) return;

    final target =
        navState.currentLocation ?? navState.activeRoute?.destination.point;
    if (target == null) return;

    final last = _lastNavCameraTarget;
    if (last != null) {
      final moved =
          (last.latitude - target.latitude).abs() +
          (last.longitude - target.longitude).abs();
      if (moved < 0.00018) {
        return;
      }
    }
    _lastNavCameraTarget = target;

    unawaited(
      controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _toYandexPoint(target), zoom: 16),
        ),
      ),
    );
  }

  void _syncWakeFallbackMode(WakeWordState wake) {
    if (_useSttWakeEngine) {
      if (_sttWakeUnavailable &&
          _sttWakeLegacyFallbackEnabled &&
          _micGranted &&
          !_onboardingDialogInProgress) {
        _startWakeFallbackLoop();
      } else {
        _stopWakeFallbackLoop();
      }
      return;
    }
    if (_onboardingDialogInProgress) {
      _stopWakeFallbackLoop();
      return;
    }
    if (!_micGranted) {
      _stopWakeFallbackLoop();
      return;
    }
    if (_wakeWordOnlyMode) {
      if (wake.status == WakeWordStatus.error) {
        _wakeWordOnlyMode = false;
        _startWakeFallbackLoop();
      } else {
        _stopWakeFallbackLoop();
      }
      return;
    }
    if (_alwaysDialogMode || wake.status == WakeWordStatus.error) {
      _startWakeFallbackLoop();
      return;
    }
    _stopWakeFallbackLoop();
  }

  void _startWakeFallbackLoop() {
    if (_useSttWakeEngine && !_sttWakeUnavailable) {
      return;
    }
    if (_wakeFallbackActive || !_micGranted) {
      return;
    }
    _wakeFallbackActive = true;
    _wakeFallbackStopRequested = false;
    _setCircleState(CircleState.wake);
    appLog('[WakeFallback] start');
    unawaited(_runWakeFallbackLoop());
  }

  void _stopWakeFallbackLoop() {
    if (!_wakeFallbackActive && !_wakeFallbackLoopRunning) return;
    _wakeFallbackActive = false;
    _wakeFallbackStopRequested = true;
    appLog('[WakeFallback] stop');
  }

  Future<void> _runWakeFallbackLoop() async {
    if (_wakeFallbackLoopRunning) return;
    _wakeFallbackLoopRunning = true;
    try {
      while (mounted && !_wakeFallbackStopRequested) {
        if (!_micGranted ||
            _commandInFlight ||
            _followUpActive ||
            _wakeHandling ||
            _onboardingDialogInProgress ||
            _isSpeaking ||
            _sttService.isListening) {
          await Future.delayed(_wakeFallbackIdleWait);
          continue;
        }
        _setCircleState(CircleState.wake);

        final fallbackWakeOnly = _requireWakeWord || _wakeWordOnlyMode;
        final text = fallbackWakeOnly
            ? await _sttService.startCommandListening(
                profile: CommandListenProfile.quickWake,
                allowAutoLanguage: true,
                maxNoSpeechMs: 1200,
              )
            : await _sttService.startCommandListening(
                allowAutoLanguage: true,
                durationSeconds: _isSpeaking
                    ? 3
                    : (_assistantMode == AssistantMode.navigation ? 11 : 7),
                minListenMs: _isSpeaking
                    ? 280
                    : (_assistantMode == AssistantMode.navigation ? 1100 : 420),
                silenceHoldMs: _isSpeaking
                    ? 520
                    : (_assistantMode == AssistantMode.navigation ? 1800 : 850),
                ampPollMs: _isSpeaking ? 95 : 115,
                restartCooldownMs: _isSpeaking
                    ? 180
                    : (_assistantMode == AssistantMode.navigation ? 320 : 220),
              );
        if (!mounted || _wakeFallbackStopRequested) break;
        final heard = (text ?? '').trim();
        if (heard.isEmpty) {
          await Future.delayed(_wakeFallbackNoSpeechWait);
          continue;
        }

        if (_isSpeaking) {
          if (_containsWakeWordCandidate(heard)) {
            appLog('[Dialog] wake phrase during speaking: $heard');
            await _handleWakeDetected();
          } else if (!_requireWakeWord &&
              _shouldProcessSpeechInterruption(heard)) {
            appLog('[Dialog] nav interruption: $heard');
            await _handleDirectFallbackCommand(heard);
          }
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (_containsWakeWordCandidate(heard)) {
          appLog('[Dialog] wake phrase: $heard');
          await _handleWakeDetected();
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (!_requireWakeWord &&
            _alwaysDialogMode &&
            _isDirectFallbackCommand(heard)) {
          appLog('[Dialog] direct command: $heard');
          await _handleDirectFallbackCommand(heard);
        }

        await Future.delayed(_wakeFallbackAfterListenWait);
      }
    } finally {
      _wakeFallbackLoopRunning = false;
      if (_wakeFallbackStopRequested) {
        appLog('[WakeFallback] stop');
      }
    }
  }

  bool _containsWakeWordCandidate(String text) {
    return WakePhraseMatcher.containsAcceptedWakeWord(text);
  }

  bool _shouldProcessSpeechInterruption(String text) {
    if (_assistantMode != AssistantMode.navigation) return false;
    final navState = _navigationController.state.value;
    final decision = _router.route(text);

    if (decision.candidateChoiceIndex != null &&
        navState.navStatus == NavigationStatus.awaitingChoice) {
      return true;
    }

    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
      case AssistantModeIntent.navStopRoutes:
      case AssistantModeIntent.navStopSchedule:
      case AssistantModeIntent.routeToPlaceLabel:
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.confirmYes:
      case AssistantModeIntent.confirmNo:
      case AssistantModeIntent.setPlaceLabel:
      case AssistantModeIntent.startOnboarding:
      case AssistantModeIntent.restartOnboarding:
      case AssistantModeIntent.updateUserFear:
      case AssistantModeIntent.readText:
      case AssistantModeIntent.switchVoiceLanguage:
        return true;
      case AssistantModeIntent.unknown:
        return _looksLikeFreeDestination(text);
      case AssistantModeIntent.visionDescribe:
      case AssistantModeIntent.repeat:
        return false;
    }
  }

  bool _looksLikeFreeDestination(String text) {
    final normalized = _router.normalize(text);
    if (normalized.length < 3) return false;
    if (!RegExp(r'[\p{L}0-9]', unicode: true).hasMatch(normalized)) {
      return false;
    }
    if (RegExp(r'^[0-9\s-]+$').hasMatch(normalized)) return false;
    if (RegExp(
      r'^(перв\S*|втор\S*|трет\S*|один|одна|два|две|три|бірін\S*|екін\S*|үшін\S*|бір|екі|үш)(\s+(вариант|номер|нұсқа|нөмір))?$',
    ).hasMatch(normalized)) {
      return false;
    }
    if (CommandRouter.exitNavModeTriggers.any(normalized.contains)) {
      return false;
    }
    if (CommandRouter.navStopTriggers.any(normalized.contains)) return false;
    if (CommandRouter.navStatusTriggers.any(normalized.contains)) return false;
    if (CommandRouter.navNextStepTriggers.any(normalized.contains)) {
      return false;
    }
    if (CommandRouter.navRejectChoiceTriggers.any(normalized.contains)) {
      return false;
    }
    if (CommandRouter.repeatTriggers.any(normalized.contains)) return false;
    if (CommandRouter.describeTriggers.any(normalized.contains)) return false;
    return true;
  }

  bool _isDirectFallbackCommand(String text) {
    final normalized = _router.normalize(text);
    if (normalized.length < 2) return false;
    if (!RegExp(r'[\p{L}]', unicode: true).hasMatch(normalized)) return false;
    if (_containsWakeWordCandidate(normalized)) return false;
    if (_personalizationReady &&
        _personalizationController.onboardingRequired &&
        _personalizationController.onboardingActive) {
      return true;
    }

    if (_assistantMode == AssistantMode.navigation) {
      final navState = _navigationController.state.value;
      final decision = _router.route(normalized);
      if (decision.candidateChoiceIndex != null &&
          navState.navStatus == NavigationStatus.awaitingChoice) {
        return true;
      }
      switch (decision.modeIntent) {
        case AssistantModeIntent.navStart:
        case AssistantModeIntent.navStopRoutes:
        case AssistantModeIntent.navStopSchedule:
        case AssistantModeIntent.routeToPlaceLabel:
        case AssistantModeIntent.navStop:
        case AssistantModeIntent.navStatus:
        case AssistantModeIntent.navNextStep:
        case AssistantModeIntent.navRejectChoice:
        case AssistantModeIntent.exitNavMode:
        case AssistantModeIntent.enterNavMode:
        case AssistantModeIntent.confirmYes:
        case AssistantModeIntent.confirmNo:
        case AssistantModeIntent.setPlaceLabel:
        case AssistantModeIntent.startOnboarding:
        case AssistantModeIntent.restartOnboarding:
        case AssistantModeIntent.updateUserFear:
        case AssistantModeIntent.readText:
        case AssistantModeIntent.switchVoiceLanguage:
          return true;
        case AssistantModeIntent.unknown:
          if (_looksLikeFreeDestination(normalized)) {
            return true;
          }
          break;
        case AssistantModeIntent.visionDescribe:
        case AssistantModeIntent.repeat:
          break;
      }
    }

    final hasIntentKeyword =
        CommandRouter.describeTriggers.any(normalized.contains) ||
        CommandRouter.repeatTriggers.any(normalized.contains) ||
        CommandRouter.readTextTriggers.any(normalized.contains);
    if (hasIntentKeyword) return true;

    final words = normalized.split(' ').where((w) => w.isNotEmpty).length;
    return words >= 2;
  }

  Future<void> _handleDirectFallbackCommand(String text) async {
    if (_commandInFlight || !_micGranted) return;
    _commandInFlight = true;
    try {
      _wakeWordOnlyMode = false;
      _requestId++;
      await _tts.stop();
      await _vibrateStart();
      _setCircleState(CircleState.listening);
      await _handleUserText(text);
    } catch (e) {
      appLog('[WakeFallback] direct command failed: $e');
      await _speak(_voiceL10n.commandProcessingFailed);
    } finally {
      _commandInFlight = false;
      _restoreWakeStateIfIdle();
    }
  }

  Future<void> _handleWakeDetected() async {
    final canBargeIn =
        _isSpeaking || _gptStatus == GptStatus.loading || _followUpActive;
    if (_wakeHandling && !canBargeIn) return;
    _wakeHandling = true;
    _lastWakeDetectedMs = DateTime.now().millisecondsSinceEpoch;
    _lastWakeAckDoneMs = _lastWakeDetectedMs;
    _lastWakeSttOpenedMs = _lastWakeDetectedMs;
    _setCircleState(CircleState.listening);
    try {
      await _runWakeAcknowledgeThenListen();
    } finally {
      _wakeHandling = false;
      _restoreWakeStateIfIdle();
    }
  }

  void _openModePickerFromWake() {
    if (!mounted) return;
    _modePickerAutoCloseTimer?.cancel();
    if (!_modePickerOpen) {
      setState(() => _modePickerOpen = true);
    }
    _modePickerAutoCloseTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_modePickerOpen) {
        setState(() => _modePickerOpen = false);
      }
    });
  }

  String _resolvedWakeAckText() {
    if (!_wakeReplyEnabled) return '';
    if (_voiceIsKazakh) {
      return _wakeAckTextKk.trim();
    }
    return _wakeAckTextRu.trim();
  }

  Future<void> _runWakeAcknowledgeThenListen() async {
    _openModePickerFromWake();
    _wakeWordOnlyMode = false;
    _stopWakeFallbackLoop();
    appLog('[WakeFlow] detected');
    _enterVoicePriorityWindow(reason: 'wake_detected');
    if (mounted) {
      setState(() => _lastWakeAt = DateTime.now());
    }
    _requestId++;

    // INSTANT INTERRUPTION
    await _tts.stop();
    await _stopPrimaryWake(reason: 'wake_detected');
    if (_followUpActive) {
      await _sttService.stop();
      _followUpActive = false;
    }
    _commandInFlight = false;

    // App-controlled mic cue is allowed only after a confirmed wake word.
    if (shouldPlayMicCue(MicCueEvent.wakeAccepted)) {
      unawaited(_playWakeCue());
    }
    unawaited(_vibrateStart());
    _lastWakeAckDoneMs = DateTime.now().millisecondsSinceEpoch;
    appLog('[WakeFlow] ack_skip_forced_for_speed');

    // Start listening immediately
    await _runCommandFlow(reason: 'wake');
  }

  Future<void> _speakWakeAckFast(String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    _setCircleState(CircleState.listening);
    _isSpeaking = true;
    try {
      await _ensureTtsLocaleForCurrentMode(force: true);
      await _tts.stop();
      await _tts.setSpeechRate(_wakeAckSpeechRate);
      await _tts.setPitch(_ttsPitch);
      await _tts.speak(line);
    } finally {
      await _tts.setSpeechRate(_ttsSpeechRate);
      await _tts.setPitch(_ttsPitch);
      _isSpeaking = false;
      _setCircleState(CircleState.listening);
    }
  }

  Future<void> _armWakeWordWaiting() async {
    if (!_micGranted) return;
    if (_requireWakeWord) {
      _wakeWordOnlyMode = true;
      _stopWakeFallbackLoop();
      _setCircleState(CircleState.wake);
      if (_useSttWakeEngine) {
        await _initializeSttWakeIfNeeded();
        await _syncPrimaryWakeMode();
      } else if (_wakeService.state.value.status != WakeWordStatus.error) {
        await _wakeService.start();
      } else {
        _scheduleWakeRecoveryIfNeeded(_wakeService.state.value);
        _syncWakeFallbackMode(_wakeService.state.value);
      }
      return;
    }
    if (_alwaysDialogMode) {
      _wakeWordOnlyMode = false;
      _startWakeFallbackLoop();
      _setCircleState(CircleState.wake);
      return;
    }
    _wakeWordOnlyMode = true;
    _stopWakeFallbackLoop();
    _setCircleState(CircleState.wake);
    if (_useSttWakeEngine) {
      await _initializeSttWakeIfNeeded();
      await _syncPrimaryWakeMode();
    } else if (_wakeService.state.value.status != WakeWordStatus.error) {
      await _wakeService.start();
    } else {
      _scheduleWakeRecoveryIfNeeded(_wakeService.state.value);
      _syncWakeFallbackMode(_wakeService.state.value);
    }
  }

  Future<void> _runCommandFlow({required String reason}) async {
    if (_commandInFlight) return;
    if (!_micGranted) return;

    _commandInFlight = true;
    final localRequestId = _requestId;
    final wakeHealthy =
        !_useSttWakeEngine &&
        _requireWakeWord &&
        _wakeService.state.value.status != WakeWordStatus.error;
    try {
      _enterVoicePriorityWindow(reason: 'command_$reason');
      if (_requireWakeWord) {
        await _stopPrimaryWake(reason: 'command_$reason');
      }
      final listenProfile = _assistantMode == AssistantMode.navigation
          ? CommandListenProfile.navigation
          : (reason == 'wake'
                ? CommandListenProfile.quickWake
                : CommandListenProfile.normal);
      appLog(
        reason == 'wake'
            ? '[WakeFlow] stt_open profile=${listenProfile.name}'
            : '[STT] start ($reason) profile=${listenProfile.name}',
      );
      String cleaned = '';
      var wakeOnlyPhrase = false;
      final maxWakeAttempts = reason == 'wake' ? 2 : 1;
      for (var attempt = 0; attempt < maxWakeAttempts; attempt++) {
        if (reason == 'wake' && attempt > 0) {
          appLog('[WakeFlow] stt_retry attempt=${attempt + 1}');
        }
        _lastWakeSttOpenedMs = DateTime.now().millisecondsSinceEpoch;
        _setCircleState(CircleState.listening);

        final text = await _sttService.startCommandListening(
          profile: listenProfile,
          languageHint: _interactionLanguage,
          allowAutoLanguage: reason == 'wake',
          maxNoSpeechMs: reason == 'wake' ? 3200 : null,
        );

        if (localRequestId != _requestId) return;
        cleaned = (text ?? '').trim();
        final normalized = _router.normalize(cleaned);
        final strippedWake = _router.stripWakeWords(normalized);
        wakeOnlyPhrase =
            cleaned.isNotEmpty &&
            _containsWakeWordCandidate(cleaned) &&
            strippedWake.isEmpty;
        if (reason == 'wake') {
          final sttDoneAt = DateTime.now().millisecondsSinceEpoch;
          appLog(
            '[WakeFlow] stt_done text="$cleaned" '
            'attempt=${attempt + 1} '
            'wake_to_ack=${_lastWakeAckDoneMs - _lastWakeDetectedMs}ms '
            'ack_to_stt=${_lastWakeSttOpenedMs - _lastWakeAckDoneMs}ms '
            'stt_total=${sttDoneAt - _lastWakeSttOpenedMs}ms',
          );
        }
        final shouldRetryWake =
            reason == 'wake' &&
            attempt == 0 &&
            (cleaned.isEmpty || wakeOnlyPhrase);
        if (!shouldRetryWake) {
          break;
        }
      }

      // Re-arm dedicated wake engine immediately after command capture.
      if (_useSttWakeEngine) {
        await _syncPrimaryWakeMode();
      } else if (wakeHealthy) {
        await _wakeService.start();
      }

      if (localRequestId != _requestId) return;
      _modePickerAutoCloseTimer?.cancel();
      if (_modePickerOpen && mounted) {
        setState(() => _modePickerOpen = false);
      }

      if (wakeOnlyPhrase) {
        appLog('[STT] ignore wake-only phrase after activation: $cleaned');
        _setCircleState(CircleState.wake);
      } else if (cleaned.isNotEmpty) {
        await _handleUserText(cleaned);
      } else {
        _setCircleState(CircleState.wake);
      }
    } finally {
      _commandInFlight = false;
      _exitVoicePriorityWindow(reason: 'command_$reason');
      _restoreWakeStateIfIdle();
    }
  }

  Future<void> _handleUserText(String text) async {
    final directive = _applyDialogStyleDirective(text);
    final userText = directive.cleanedText.isEmpty
        ? text.trim()
        : directive.cleanedText;
    final languageDetection = SpokenLanguageDetector.detect(
      userText,
      fallbackLanguage: _interactionLanguage,
    );
    _applyDetectedInteractionLanguage(
      languageDetection,
      userText,
      forDialogSession: true,
    );
    if (directive.onlyDirective) {
      await _speak(_dialogStyleConfirmationText());
      return;
    }
    if (_isContextResetCommand(userText)) {
      _clearDialogHistory();
      await _speak(_voiceL10n.dialogContextCleared);
      return;
    }

    final requestedMode = _detectModeSwitchByText(userText);
    if (requestedMode != null) {
      appLog(
        '[WakeFlow] command_routed_at=${DateTime.now().millisecondsSinceEpoch} '
        'mode=${requestedMode.name} text="${userText.trim()}"',
      );
      final changed = await _switchAssistantMode(
        requestedMode,
        reason: 'voice_mode_switch',
      );
      if (changed) {
        _triggerFastModeFeedback();
      } else {
        await _speak(_modeUnavailableMessage(requestedMode));
      }
      return;
    }

    if (await _maybeHandleExitCurrentModeCommand(userText)) {
      return;
    }

    final autoTriggeredMode = _detectContextTriggeredMode(userText);
    if (autoTriggeredMode != null && autoTriggeredMode != _assistantMode) {
      await _switchAssistantMode(
        autoTriggeredMode,
        reason: 'context_trigger',
        autoTriggered: true,
      );
    }

    if (_isGoHomeRouteCommand(userText)) {
      await _handleGoHomeShortcut(userText);
      return;
    }

    if (await _maybeHandleTextReaderControlCommand(userText)) {
      return;
    }

    final decision = _router.route(userText);
    if (decision.modeIntent == AssistantModeIntent.switchVoiceLanguage) {
      await _speak(_voiceLanguageSwitchAck());
      return;
    }
    if (_personalizationReady) {
      if (decision.modeIntent == AssistantModeIntent.startOnboarding) {
        await _startOnboardingFlow();
        return;
      }
      if (decision.modeIntent == AssistantModeIntent.restartOnboarding) {
        await _restartOnboardingFlow();
        return;
      }
      if (_personalizationController.onboardingRequired &&
          _personalizationController.onboardingActive) {
        await _handleOnboardingInput(text, decision);
        return;
      }
      if (decision.modeIntent == AssistantModeIntent.updateUserFear) {
        await _handleFearIntent(decision, text);
        return;
      }
      if (decision.modeIntent == AssistantModeIntent.setPlaceLabel) {
        await _handleSetPlaceLabelIntent(decision);
        return;
      }
      if (decision.modeIntent == AssistantModeIntent.routeToPlaceLabel) {
        await _handleRouteToLabelIntent(decision);
        return;
      }
    }

    if (decision.modeIntent == AssistantModeIntent.enterNavMode) {
      await _enterNavigationMode();
      return;
    }
    if (decision.modeIntent == AssistantModeIntent.exitNavMode) {
      await _exitNavigationMode();
      return;
    }
    if (await _handleGlobalNavigationIntent(userText, decision)) {
      return;
    }

    if (_assistantMode == AssistantMode.general) {
      await _handleGeneralModeCommand(userText, decision);
      return;
    }
    if (_assistantMode == AssistantMode.navigation) {
      await _handleNavigationModeCommand(userText, decision);
      return;
    }
    await _handleTaskModeCommand(userText, decision);
  }

  AssistantMode? _detectContextTriggeredMode(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return null;

    bool hasAny(List<String> variants) =>
        variants.any((value) => normalized.contains(value));

    if (hasAny([
      'цена',
      'ценник',
      'калории',
      'этикетка',
      'документ',
      'текст',
    ])) {
      return AssistantMode.textReader;
    }
    if (hasAny(['сдача', 'купюра', 'банкнота', 'фальшив', 'мошен'])) {
      return AssistantMode.antiFraud;
    }
    if (hasAny(['что надеть', 'погода', 'дрескод', 'киім', 'dress'])) {
      return AssistantMode.dressCode;
    }
    if (hasAny(['список покупок', 'купить', 'магазин', 'шопинг', 'shopping'])) {
      return AssistantMode.shopping;
    }
    if (hasAny(['готовк', 'рецепт', 'плита', 'холодильник', 'cook'])) {
      return AssistantMode.cooking;
    }
    if (hasAny(['запомни', 'память', 'помни это', 'есте сақта'])) {
      return AssistantMode.memory;
    }
    if (hasAny(['найди', 'отыщи', 'find'])) {
      return AssistantMode.find;
    }
    return null;
  }

  Future<bool> _handleGlobalNavigationIntent(
    String rawText,
    CommandDecision decision,
  ) async {
    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
      case AssistantModeIntent.navStopRoutes:
      case AssistantModeIntent.navStopSchedule:
      case AssistantModeIntent.routeToPlaceLabel:
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
      case AssistantModeIntent.confirmYes:
      case AssistantModeIntent.confirmNo:
        if (_assistantMode != AssistantMode.navigation) {
          await _enterNavigationMode();
          if (_assistantMode != AssistantMode.navigation) {
            return true;
          }
        }
        await _handleNavigationModeCommand(rawText, decision);
        return true;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.setPlaceLabel:
      case AssistantModeIntent.startOnboarding:
      case AssistantModeIntent.restartOnboarding:
      case AssistantModeIntent.updateUserFear:
      case AssistantModeIntent.readText:
      case AssistantModeIntent.visionDescribe:
      case AssistantModeIntent.repeat:
      case AssistantModeIntent.switchVoiceLanguage:
      case AssistantModeIntent.unknown:
        return false;
    }
  }

  bool _isGoHomeRouteCommand(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const exactMatches = <String>{
      'домой',
      'веди домой',
      'маршрут домой',
      'проведи домой',
      'до дома',
      'домға',
      'үйге',
      'үйге апар',
      'үйге жол сал',
      'маршрут үйге',
    };
    if (exactMatches.contains(normalized)) return true;
    const containsMatches = <String>[
      'домой пожалуйста',
      'проведи меня домой',
      'маршрут до дома',
      'отведи домой',
      'апар үйге',
      'үйге апарып жібер',
      'үйге апаршы',
    ];
    return containsMatches.any(normalized.contains);
  }

  bool _isExitCurrentModeCommand(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const exactMatches = <String>{
      'выключи режим',
      'выйди из режима',
      'выход из режима',
      'выйти из режима',
      'режимді өшір',
      'режимнен шық',
      'режимнен шығу',
    };
    if (exactMatches.contains(normalized)) return true;
    const containsMatches = <String>[
      'выключи этот режим',
      'выключи текущий режим',
      'выйди из этого режима',
      'выйди из текущего режима',
      'отключи режим',
      'закрой режим',
      'осы режимнен шық',
      'осы режимді өшір',
      'ағымдағы режимнен шық',
    ];
    return containsMatches.any(normalized.contains);
  }

  Future<bool> _maybeHandleExitCurrentModeCommand(String text) async {
    if (!_isExitCurrentModeCommand(text)) return false;
    if (_assistantMode == AssistantMode.general) {
      await _speak(
        _voiceText(
          ru: 'Сейчас уже обычный режим.',
          kk: 'Қазір қалыпты режим қосулы.',
        ),
      );
      return true;
    }
    final changed = await _switchAssistantMode(
      AssistantMode.general,
      reason: 'voice_exit_mode',
    );
    if (changed) {
      _triggerFastModeFeedback();
    }
    return true;
  }

  Future<void> _handleGoHomeShortcut(String rawText) async {
    if (!_personalizationReady) {
      await _speak(
        _voiceText(
          ru: 'Сначала сохраните домашнюю метку.',
          kk: 'Әуелі үй меткасын сақтап алыңыз.',
        ),
      );
      return;
    }

    final fallback = _voiceText(ru: 'домой', kk: 'үйге');
    final decision = CommandDecision(
      cleanedText: rawText.trim(),
      modeIntent: AssistantModeIntent.routeToPlaceLabel,
      destinationQuery: fallback,
      placeLabelName: fallback,
    );

    final label = await _findPlaceLabelForRouteCommand(
      decision,
      fallbackDestination: fallback,
    );
    if (label == null) {
      await _speak(
        _voiceText(
          ru: 'Домашняя метка не найдена. Сначала сохраните дом как метку.',
          kk: 'Үй меткасы табылмады. Әуелі үйді метка ретінде сақтаңыз.',
        ),
      );
      return;
    }

    if (_assistantMode != AssistantMode.navigation) {
      await _enterNavigationMode();
      if (_assistantMode != AssistantMode.navigation) {
        return;
      }
    }

    await _startRouteWithConfirmation(label.addressText, routeSource: 'label');
  }

  Future<void> _startOnboardingFlow() async {
    if (!_personalizationReady) return;
    if (!_showOnboardingOverlay) {
      setState(() {
        _showOnboardingOverlay = true;
      });
    }
    await _personalizationController.startOrResumeOnboarding(force: true);
    if (!mounted) return;
    _syncOnboardingReminderTimer();
    _maybeStartOnboardingDialog();
  }

  Future<void> _restartOnboardingFlow() async {
    if (!_personalizationReady) return;
    setState(() {
      _showOnboardingOverlay = true;
    });
    await _personalizationController.restartOnboardingFromScratch();
    await _speakOnboardingLine(
      _voiceText(
        ru: 'Хорошо, начинаем опрос заново.',
        kk: 'Жақсы, опрос қайта басталды.',
      ),
    );
    _maybeStartOnboardingDialog();
  }

  Future<_OnboardingTurnResult> _handleOnboardingInput(
    String rawText,
    CommandDecision decision, {
    bool promptNextQuestion = true,
  }) async {
    final reminderRequest = parseOnboardingReminderRequest(rawText);
    if (reminderRequest != null) {
      await _deferOnboarding(reminderRequest);
      return _OnboardingTurnResult.paused;
    }

    final answer = decision.cleanedText.trim().isEmpty
        ? rawText.trim()
        : decision.cleanedText.trim();
    if (answer.isEmpty) {
      await _speakOnboardingLine(_voiceL10n.didntHearCommandRepeat);
      return _OnboardingTurnResult.retry;
    }

    await _personalizationController.answerOnboardingQuestion(answer);
    if (!_personalizationController.onboardingRequired) {
      setState(() {
        _showOnboardingOverlay = false;
      });
      await _speakOnboardingLine(
        _voiceText(
          ru: 'Персонализация завершена. Я готова к работе.',
          kk: 'Персонализация аяқталды. Енді дайынмын.',
        ),
      );
      return _OnboardingTurnResult.completed;
    }
    if (promptNextQuestion) {
      final nextQuestion = _personalizationController.currentQuestionText(
        _interactionLanguage,
      );
      if (nextQuestion.isNotEmpty) {
        await _speakOnboardingLine(nextQuestion);
      }
    }
    return _OnboardingTurnResult.advanced;
  }

  void _maybeStartOnboardingDialog() {
    if (!_micGranted || !_personalizationReady || _onboardingDialogInProgress) {
      return;
    }
    if (!_showOnboardingOverlay) return;
    if (!_personalizationController.onboardingRequired ||
        !_personalizationController.onboardingActive) {
      return;
    }
    unawaited(_runOnboardingDialogLoop());
  }

  Future<void> _runOnboardingDialogLoop() async {
    if (_onboardingDialogInProgress || !_micGranted || !_personalizationReady) {
      return;
    }
    if (!_showOnboardingOverlay ||
        !_personalizationController.onboardingRequired ||
        !_personalizationController.onboardingActive) {
      return;
    }

    _onboardingDialogInProgress = true;
    _wakeWordOnlyMode = false;
    _stopWakeFallbackLoop();
    await _stopPrimaryWake(reason: 'onboarding');
    try {
      while (mounted &&
          _showOnboardingOverlay &&
          _personalizationController.onboardingRequired &&
          _personalizationController.onboardingActive) {
        final question = _personalizationController.currentQuestionText(
          _interactionLanguage,
        );
        if (question.isEmpty) break;
        await _speakOnboardingLine(question);
        if (!mounted) return;

        _setCircleState(CircleState.listening);
        final heard = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 8,
          minListenMs: 240,
          silenceHoldMs: 720,
          ampPollMs: 95,
          restartCooldownMs: 120,
          maxNoSpeechMs: 4500,
          alwaysTranscribe: true,
        );
        if (!mounted) return;

        final rawText = (heard ?? '').trim();
        appLog(
          '[Onboarding] heard="${_truncateForLog(rawText)}" '
          'stt_error=${_sttService.state.value.lastError ?? '-'}',
        );
        final decision = _router.route(rawText);
        if (decision.modeIntent == AssistantModeIntent.restartOnboarding) {
          await _personalizationController.restartOnboardingFromScratch();
          await _speakOnboardingLine(
            _voiceText(
              ru: 'Хорошо, начинаем опрос заново.',
              kk: 'Жақсы, опрос қайта басталды.',
            ),
          );
          continue;
        }
        final result = await _handleOnboardingInput(
          rawText,
          decision,
          promptNextQuestion: false,
        );
        if (result == _OnboardingTurnResult.paused ||
            result == _OnboardingTurnResult.completed) {
          break;
        }
      }
    } finally {
      _onboardingDialogInProgress = false;
      if (_micGranted) {
        if (_useSttWakeEngine) {
          await _syncPrimaryWakeMode();
        } else if (_wakeService.state.value.status == WakeWordStatus.error) {
          _wakeWordOnlyMode = false;
          _scheduleWakeRecoveryIfNeeded(_wakeService.state.value);
          _syncWakeFallbackMode(_wakeService.state.value);
        } else if (_alwaysDialogMode) {
          _wakeWordOnlyMode = false;
          _startWakeFallbackLoop();
        } else {
          await _armWakeWordWaiting();
        }
      }
    }
  }

  Future<void> _speakOnboardingLine(String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    _setCircleState(CircleState.speaking);
    await _speak(line);
  }

  Future<void> _handleFearIntent(
    CommandDecision decision,
    String rawText,
  ) async {
    final fearText = decision.fearText?.trim().isNotEmpty == true
        ? decision.fearText!.trim()
        : rawText.trim();
    if (fearText.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'Скажите, чего вы боитесь, и я запомню.',
          kk: 'Неден қорқатыныңызды айтыңыз.',
        ),
      );
      return;
    }
    await _personalizationController.updateFromDirectUserFact(fearText);
    await _speak(
      _voiceText(
        ru: 'Поняла, запомнила это как важный риск.',
        kk: 'Жақсы, сақтап қойдым.',
      ),
    );
  }

  Future<void> _handleSetPlaceLabelIntent(CommandDecision decision) async {
    var labelName = (decision.placeLabelName ?? '').trim();
    var addressText = (decision.freeAddressText ?? '').trim();

    final withAddressMatch = RegExp(
      r'^(.+?)\s+(адрес|мекенжай|по адресу|как)\s+(.+)$',
      unicode: true,
    ).firstMatch(labelName);
    if (withAddressMatch != null) {
      labelName = (withAddressMatch.group(1) ?? '').trim();
      addressText = (withAddressMatch.group(3) ?? '').trim();
    }

    if (labelName.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'Скажите название метки. Например: дом.',
          kk: 'Қандай атаумен сақтау керек? Мысалы: үй.',
        ),
      );
      return;
    }

    while (mounted) {
      if (addressText.isEmpty) {
        await _speak(
          _voiceText(
            ru: 'Продиктуйте адрес для метки "$labelName".',
            kk: '"$labelName" меткасы үшін мекенжайды айтыңыз.',
          ),
        );
        _setCircleState(CircleState.listening);
        final answer = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 10,
          minListenMs: 320,
          silenceHoldMs: 1100,
          ampPollMs: 110,
          restartCooldownMs: 150,
          maxNoSpeechMs: 7000,
        );
        if (!mounted) return;
        addressText = _extractDestinationCandidate((answer ?? '').trim());
        if (addressText.isEmpty) {
          await _speak(_voiceL10n.didntHearCommandRepeat);
          continue;
        }
      }

      final candidate = await _navigationController.resolveDestinationCandidate(
        addressText,
      );
      if (candidate == null) {
        await _speak(
          _voiceText(
            ru: 'Не смогла найти этот адрес. Скажите, как сохранить правильно.',
            kk: 'Бұл мекенжайды таба алмадым. Қалай дұрыс сақтау керегін айтыңыз.',
          ),
        );
        _setCircleState(CircleState.listening);
        final corrected = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 10,
          minListenMs: 320,
          silenceHoldMs: 1100,
          ampPollMs: 110,
          restartCooldownMs: 150,
          maxNoSpeechMs: 7000,
        );
        if (!mounted) return;
        final correction = _parseLabelCorrection(
          (corrected ?? '').trim(),
          currentLabelName: labelName,
        );
        if (!correction.hasAny) {
          await _speak(_voiceL10n.didntHearCommandRepeat);
          continue;
        }
        labelName = (correction.labelName ?? labelName).trim();
        addressText = (correction.addressText ?? '').trim();
        continue;
      }

      await _speak(
        _voiceText(
          ru: 'Сохранить метку "$labelName" с адресом "${candidate.displayLabel}"?',
          kk: '"$labelName" меткасын "${candidate.displayLabel}" мекенжайымен сақтайын ба?',
        ),
      );
      _setCircleState(CircleState.listening);
      final confirmAnswer = await _sttService.startCommandListening(
        languageHint: _interactionLanguage,
        allowAutoLanguage: false,
        durationSeconds: 8,
        minListenMs: 300,
        silenceHoldMs: 950,
        ampPollMs: 105,
        restartCooldownMs: 150,
        maxNoSpeechMs: 6000,
      );
      if (!mounted) return;
      final response = (confirmAnswer ?? '').trim();
      if (response.isEmpty) {
        await _speak(_voiceL10n.didntHearCommandRepeat);
        continue;
      }

      if (_isAffirmativeResponse(response)) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await _personalizationRepository.upsertPlaceLabel(
          PlaceLabel(
            labelName: labelName,
            labelNameNorm: normalizeText(labelName),
            addressText: candidate.displayLabel,
            lat: candidate.point.latitude,
            lon: candidate.point.longitude,
            createdAtEpochMs: now,
            updatedAtEpochMs: now,
          ),
        );
        await _personalizationController.refresh();
        await _speak(
          _voiceText(
            ru: 'Сохранила метку "$labelName".',
            kk: '"$labelName" меткасы сақталды.',
          ),
        );
        return;
      }

      var correction = _parseLabelCorrection(
        response,
        currentLabelName: labelName,
      );

      if (_isNegativeResponse(response) &&
          (correction.addressText ?? '').trim().isEmpty) {
        await _speak(
          _voiceText(
            ru: 'Скажите как правильно. Например: "сохрани как дом адрес Абая 10".',
            kk: 'Дұрысын айтыңыз. Мысалы: "сақта үй мекенжайы Абай 10".',
          ),
        );
        _setCircleState(CircleState.listening);
        final corrected = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 10,
          minListenMs: 320,
          silenceHoldMs: 1100,
          ampPollMs: 110,
          restartCooldownMs: 150,
          maxNoSpeechMs: 7000,
        );
        if (!mounted) return;
        correction = _parseLabelCorrection(
          (corrected ?? '').trim(),
          currentLabelName: labelName,
        );
      }

      if (!correction.hasAny) {
        await _speak(
          _voiceText(
            ru: 'Скажите "да" для подтверждения или продиктуйте правильные метку и адрес.',
            kk: 'Иә деп растаңыз немесе дұрыс атау мен мекенжайды айтыңыз.',
          ),
        );
        continue;
      }

      labelName = (correction.labelName ?? labelName).trim();
      if ((correction.addressText ?? '').trim().isNotEmpty) {
        addressText = correction.addressText!.trim();
      } else {
        addressText = '';
      }
    }
  }

  Future<void> _handleRouteToLabelIntent(CommandDecision decision) async {
    var labelName = (decision.placeLabelName ?? '').trim();
    if (labelName.isEmpty) {
      labelName = (decision.destinationQuery ?? '').trim();
    }
    if (labelName.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'К какой метке построить маршрут?',
          kk: 'Қай меткаға маршрут құру керек?',
        ),
      );
      return;
    }

    final label = await _findPlaceLabelForRouteCommand(
      decision,
      fallbackDestination: labelName,
    );
    if (label == null) {
      if (_assistantMode != AssistantMode.navigation) {
        await _enterNavigationMode();
        if (_assistantMode != AssistantMode.navigation) {
          return;
        }
      }
      await _startRouteWithConfirmation(labelName, routeSource: 'manual');
      return;
    }

    if (_assistantMode != AssistantMode.navigation) {
      await _enterNavigationMode();
      if (_assistantMode != AssistantMode.navigation) {
        return;
      }
    }

    await _startRouteWithConfirmation(label.addressText, routeSource: 'label');
  }

  Future<PlaceLabel?> _findPlaceLabelForRouteCommand(
    CommandDecision decision, {
    required String fallbackDestination,
  }) async {
    final lookupCandidates = <String>[];
    void addCandidate(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (!lookupCandidates.contains(trimmed)) {
        lookupCandidates.add(trimmed);
      }
    }

    const leadingWords = <String>{
      'до',
      'да',
      'к',
      'ко',
      'в',
      'во',
      'на',
      'по',
      'маршрут',
      'бағыт',
      'багыт',
    };

    addCandidate(fallbackDestination);
    addCandidate(decision.destinationQuery ?? '');
    addCandidate(decision.placeLabelName ?? '');
    addCandidate(_extractDestinationCandidate(fallbackDestination));
    addCandidate(_extractDestinationCandidate(decision.destinationQuery ?? ''));
    addCandidate(_extractDestinationCandidate(decision.placeLabelName ?? ''));

    final snapshot = List<String>.from(lookupCandidates);
    for (final candidate in snapshot) {
      final normalized = normalizeText(candidate);
      final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
      if (words.length > 1 && leadingWords.contains(words.first)) {
        addCandidate(words.sublist(1).join(' '));
      }
    }

    for (final candidate in lookupCandidates) {
      try {
        final label = await _personalizationRepository.findPlaceLabelByName(
          candidate,
        );
        if (label != null) return label;
      } catch (e) {
        appLog('[Personalization] place label lookup error: $e');
      }
    }
    return null;
  }

  Future<void> _handleGeneralModeCommand(
    String rawText,
    CommandDecision decision,
  ) async {
    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
      case AssistantModeIntent.navStopRoutes:
      case AssistantModeIntent.navStopSchedule:
      case AssistantModeIntent.routeToPlaceLabel:
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
        await _speak(_voiceL10n.enableRouteModeFirst);
        return;
      case AssistantModeIntent.repeat:
        await _repeatLastAnswer();
        return;
      case AssistantModeIntent.readText:
        await _handleReadTextIntent(rawText);
        return;
      case AssistantModeIntent.switchVoiceLanguage:
        await _speak(_voiceLanguageSwitchAck());
        return;
      case AssistantModeIntent.visionDescribe:
        final userText = decision.cleanedText.isEmpty
            ? rawText
            : decision.cleanedText;
        final describeText = decision.directionRu == null
            ? userText
            : _describePromptForDirection(decision.directionRu!);
        await _describeWithVision(
          describeText,
          systemPrompt: _buildVisionPrompt(),
        );
        return;
      case AssistantModeIntent.unknown:
        final userText = decision.cleanedText.isEmpty
            ? rawText.trim()
            : decision.cleanedText.trim();
        if (userText.isEmpty) {
          await _speak(_voiceL10n.didntHearCommandRepeat);
          return;
        }
        if (_isIdentityQuestion(userText)) {
          await _speak(_identityAnswer());
          return;
        }
        if (_isCapabilitiesQuestion(userText)) {
          await _speak(_capabilitiesAnswer());
          return;
        }
        if (_isRouteModeHelpQuestion(userText)) {
          await _speak(_routeModeHelpAnswer(_wantsDetailedByText(userText)));
          return;
        }
        if (_looksLikeVisualFreeRequest(userText)) {
          await _describeWithVision(
            userText,
            systemPrompt: _buildVisionPrompt(),
          );
        } else {
          await _askGpt(userText, systemPrompt: _buildBlindPrompt());
        }
        return;
      case AssistantModeIntent.confirmYes:
      case AssistantModeIntent.confirmNo:
        await _speak(_voiceL10n.didntHearCommandRepeat);
        return;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.setPlaceLabel:
      case AssistantModeIntent.startOnboarding:
      case AssistantModeIntent.restartOnboarding:
      case AssistantModeIntent.updateUserFear:
        return;
    }
  }

  Future<void> _handleNavigationModeCommand(
    String rawText,
    CommandDecision decision,
  ) async {
    final navState = _navigationController.state.value;
    if (decision.candidateChoiceIndex != null &&
        navState.navStatus == NavigationStatus.awaitingChoice) {
      await _navigationController.selectCandidate(
        decision.candidateChoiceIndex!,
      );
      return;
    }

    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
      case AssistantModeIntent.navStopRoutes:
      case AssistantModeIntent.navStopSchedule:
      case AssistantModeIntent.routeToPlaceLabel:
        var destination = decision.destinationQuery?.trim() ?? '';
        if (destination.isEmpty) {
          destination = (decision.placeLabelName ?? '').trim();
        }
        if (destination.isEmpty) {
          await _speak(_voiceL10n.sayAddressAfterRoutePhrase);
          return;
        }
        if (decision.destinationKindHint !=
            NavigationDestinationKind.transitStop) {
          final byLabel = await _findPlaceLabelForRouteCommand(
            decision,
            fallbackDestination: destination,
          );
          if (byLabel != null) {
            await _startRouteWithConfirmation(
              byLabel.addressText,
              routeSource: 'label',
            );
            return;
          }
        }
        await _startRouteWithConfirmation(
          destination,
          routeSource: 'manual',
          destinationKindHint: decision.destinationKindHint,
        );
        return;
      case AssistantModeIntent.navStopRoutes:
        await _navigationController.speakStopRoutes(
          decision.destinationQuery?.trim() ?? '',
        );
        return;
      case AssistantModeIntent.navStopSchedule:
        await _navigationController.speakScheduledArrivals(
          stopQuery: decision.destinationQuery?.trim() ?? '',
          routeName: decision.transitRouteName?.trim() ?? '',
        );
        return;
      case AssistantModeIntent.navStop:
        await _navigationController.stopRoute();
        return;
      case AssistantModeIntent.navStatus:
        await _navigationController.speakStatus();
        return;
      case AssistantModeIntent.navNextStep:
        await _navigationController.speakNextStep();
        return;
      case AssistantModeIntent.navRejectChoice:
        await _navigationController.rejectCandidateSelection();
        return;
      case AssistantModeIntent.readText:
        await _handleReadTextIntent(rawText);
        return;
      case AssistantModeIntent.switchVoiceLanguage:
        await _speak(_voiceLanguageSwitchAck());
        return;
      case AssistantModeIntent.repeat:
      case AssistantModeIntent.visionDescribe:
        await _speak(_voiceL10n.routeModeDescribeBlocked);
        return;
      case AssistantModeIntent.unknown:
        final freeText = decision.cleanedText.isEmpty
            ? rawText.trim()
            : decision.cleanedText.trim();
        if (_isIdentityQuestion(freeText)) {
          await _speak(_identityAnswer());
          return;
        }
        if (_isCapabilitiesQuestion(freeText)) {
          await _speak(_capabilitiesAnswer());
          return;
        }
        if (_isRouteModeHelpQuestion(freeText)) {
          await _speak(_routeModeHelpAnswer(true));
          return;
        }
        if (_looksLikeFreeDestination(freeText)) {
          await _startRouteWithConfirmation(freeText);
          return;
        }
        if (freeText.isNotEmpty) {
          await _askGpt(
            freeText,
            systemPrompt: _buildBlindPrompt(navigationMode: true),
          );
        }
        return;
      case AssistantModeIntent.confirmYes:
      case AssistantModeIntent.confirmNo:
        await _speak(_voiceL10n.navAnswerYesOrNoOrAddress);
        return;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.setPlaceLabel:
      case AssistantModeIntent.startOnboarding:
      case AssistantModeIntent.restartOnboarding:
      case AssistantModeIntent.updateUserFear:
        return;
    }
  }

  Future<void> _handleTaskModeCommand(
    String rawText,
    CommandDecision decision,
  ) async {
    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
      case AssistantModeIntent.navStopRoutes:
      case AssistantModeIntent.navStopSchedule:
      case AssistantModeIntent.routeToPlaceLabel:
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
        await _speak(_voiceL10n.enableRouteModeFirst);
        return;
      case AssistantModeIntent.repeat:
        await _repeatLastAnswer();
        return;
      case AssistantModeIntent.readText:
        await _handleReadTextIntent(rawText);
        return;
      case AssistantModeIntent.switchVoiceLanguage:
        await _speak(_voiceLanguageSwitchAck());
        return;
      case AssistantModeIntent.visionDescribe:
        final userText = decision.cleanedText.isEmpty
            ? rawText
            : decision.cleanedText;
        await _describeWithVision(userText, systemPrompt: _buildVisionPrompt());
        return;
      case AssistantModeIntent.unknown:
        final userText = decision.cleanedText.isEmpty
            ? rawText.trim()
            : decision.cleanedText.trim();
        if (userText.isEmpty) {
          await _speak(_voiceL10n.didntHearCommandRepeat);
          return;
        }
        if (_isIdentityQuestion(userText)) {
          await _speak(_identityAnswer());
          return;
        }
        if (_isCapabilitiesQuestion(userText)) {
          await _speak(_capabilitiesAnswer());
          return;
        }
        await _handleModeSpecificUnknown(userText);
        return;
      case AssistantModeIntent.confirmYes:
      case AssistantModeIntent.confirmNo:
        await _speak(_voiceL10n.didntHearCommandRepeat);
        return;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.setPlaceLabel:
      case AssistantModeIntent.startOnboarding:
      case AssistantModeIntent.restartOnboarding:
      case AssistantModeIntent.updateUserFear:
        return;
    }
  }

  Future<void> _handleModeSpecificUnknown(String userText) async {
    switch (_assistantMode) {
      case AssistantMode.general:
        await _handleHomeModeCommand(userText);
        return;
      case AssistantMode.navigation:
        await _handleRouteModeCommand(userText);
        return;
      case AssistantMode.safety:
        await _handleHomeModeCommand(userText);
        return;
      case AssistantMode.textReader:
        await _handleTextReaderModeCommand(userText);
        return;
      case AssistantMode.shopping:
        await _handleShoppingModeCommand(userText);
        return;
      case AssistantMode.cooking:
        await _handleCookingModeCommand(userText);
        return;
      case AssistantMode.dressCode:
        await _handleDressCodeModeCommand(userText);
        return;
      case AssistantMode.antiFraud:
        await _handleAntiFraudModeCommand(userText);
        return;
      case AssistantMode.memory:
        await _handleMemoryModeCommand(userText);
        return;
      case AssistantMode.find:
        await _handleFindModeCommand(userText);
        return;
    }
  }

  Future<void> _handleHomeModeCommand(String userText) async {
    if (_shouldUseVisionInHomeMode(userText)) {
      await _describeWithVision(
        userText,
        systemPrompt: _buildVisionPrompt(
          extraInstruction: _looksLikeColorQuestion(userText)
              ? _voiceText(
                  ru: 'Если пользователь спрашивает про цвет, назови основной видимый цвет точно. Если нужно, назови только 1-2 главных цвета.',
                  kk: 'Егер пайдаланушы түс туралы сұраса, көрінетін негізгі түсті нақты ата. Қажет болса 1-2 түсті ғана айт.',
                )
              : null,
        ),
      );
      return;
    }
    await _askGpt(userText, systemPrompt: _buildBlindPrompt());
  }

  Future<void> _handleRouteModeCommand(String userText) async {
    if (_looksLikeVisualFreeRequest(userText)) {
      await _describeWithVision(userText, systemPrompt: _buildVisionPrompt());
      return;
    }
    await _askGpt(
      userText,
      systemPrompt: _buildBlindPrompt(navigationMode: true),
    );
  }

  bool _shouldUseVisionInHomeMode(String userText) {
    final normalized = _router.normalize(userText);
    if (normalized.isEmpty) return true;
    if (_looksLikeVisualFreeRequest(userText)) return true;
    const metaCues = <String>[
      'что ты уме',
      'кто ты',
      'режим',
      'умеешь',
      'что можешь',
      'не істей',
      'кімсің',
      'режим',
    ];
    for (final cue in metaCues) {
      if (normalized.contains(cue)) return false;
    }
    return _currentModeDescriptor().perception.prefersSceneDescription;
  }

  Future<void> _handleSafetyModeCommand(String userText) async {
    await _describeWithVision(userText, systemPrompt: _buildVisionPrompt());
  }

  Future<void> _handleTextReaderModeCommand(String userText) async {
    await _runManualTextReadSession(
      userText,
      source: _TextReaderReadSource.voice,
    );
  }

  Future<bool> _maybeHandleTextReaderControlCommand(String userText) async {
    if (_assistantMode != AssistantMode.textReader) return false;
    final normalized = _router.normalize(userText);
    if (normalized.isEmpty) return false;

    if (_isTextReaderStopCommand(normalized)) {
      await _cancelActiveTextReaderSession();
      return true;
    }
    if (_isTextReaderResumeCommand(normalized)) {
      await _runManualTextReadSession(
        userText,
        source: _TextReaderReadSource.voice,
      );
      return true;
    }
    return false;
  }

  bool _isTextReaderStopCommand(String normalized) {
    const cues = <String>[
      'стоп',
      'остановись',
      'остановить',
      'пауза',
      'хватит',
      'тоқта',
      'пауза жаса',
    ];
    for (final cue in cues) {
      if (normalized == cue || normalized.contains(cue)) {
        return true;
      }
    }
    return false;
  }

  bool _isTextReaderResumeCommand(String normalized) {
    const cues = <String>[
      'начни сначала',
      'начать сначала',
      'продолжай',
      'продолжить',
      'читай дальше',
      'продолжай читать',
      'resume',
      'continue',
      'қайта баста',
      'жалғастыр',
    ];
    for (final cue in cues) {
      if (normalized == cue || normalized.contains(cue)) {
        return true;
      }
    }
    return false;
  }

  TextReaderReadSource _toTextReaderReadSource(_TextReaderReadSource source) {
    switch (source) {
      case _TextReaderReadSource.voice:
        return TextReaderReadSource.voice;
      case _TextReaderReadSource.tap:
        return TextReaderReadSource.tap;
      case _TextReaderReadSource.auto:
        return TextReaderReadSource.auto;
    }
  }

  _TextReaderSessionState _toTextReaderSessionState(TextReaderState state) {
    switch (state) {
      case TextReaderState.scanning:
        return _TextReaderSessionState.scanning;
      case TextReaderState.speaking:
        return _TextReaderSessionState.speaking;
      case TextReaderState.paused:
        return _TextReaderSessionState.paused;
      case TextReaderState.failed:
        return _TextReaderSessionState.failed;
      case TextReaderState.idle:
        return _TextReaderSessionState.idle;
    }
  }

  void _applyTextReaderState(
    TextReaderState state, {
    String? failureReason,
    bool updateUi = true,
  }) {
    _textReaderSessionState = _toTextReaderSessionState(state);
    if (failureReason != null) {
      _lastTextReaderFailureReason = failureReason;
    } else if (state != TextReaderState.failed) {
      _lastTextReaderFailureReason = '';
    }
    if (updateUi && mounted) {
      setState(() {});
    }
  }

  void _resetTextReaderAutoState({bool clearLastSignature = false}) {
    _pendingAutoTextReaderSignature = '';
    _pendingAutoTextReaderSeenCount = 0;
    if (clearLastSignature) {
      _lastAutoTextReaderSignature = '';
      _lastAutoTextReaderSpeakMs = 0;
      _lastAutoTextReaderExactSignature = '';
      _lastAutoTextReaderExactMs = 0;
      _lastTextReaderVisionSignature = '';
      _lastTextReaderVisionMs = 0;
    }
  }

  Future<void> _cancelActiveTextReaderSession() async {
    _textReaderSessionCancelRequested = true;
    _textReaderController.stop();
    await _tts.stop();
    _isSpeaking = false;
    _applyTextReaderState(_textReaderController.state);
    appLog('[TextReader][control] stopped');
    _restoreWakeStateIfIdle();
  }

  Future<void> _pauseTextReaderContinuousReading() async {
    _textReaderAutoPaused = true;
    _textReaderSessionCancelRequested = true;
    _textReaderController.pause();
    await _tts.stop();
    _isSpeaking = false;
    _syncTextReaderLoop();
    _applyTextReaderState(_textReaderController.state);
    appLog('[TextReader][control] paused');
    _restoreWakeStateIfIdle();
  }

  Future<void> _resumeTextReaderContinuousReading({bool restart = true}) async {
    _textReaderAutoPaused = false;
    _textReaderSessionCancelRequested = false;
    _textReaderController.resume(clearSpokenSignature: restart);
    _syncTextReaderLoop();
    _applyTextReaderState(_textReaderController.state);
    appLog('[TextReader][control] resumed restart=$restart');
    if (restart) {
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || _assistantMode != AssistantMode.textReader) return;
        unawaited(_runAutoTextReaderTick());
      });
    }
  }

  Future<void> _handleReadTextIntent(String rawText) async {
    if (!_featureFlags.textReaderEnabled ||
        !_isModeEnabled(AssistantMode.textReader)) {
      await _speak(_modeUnavailableMessage(AssistantMode.textReader));
      return;
    }
    if (_assistantMode != AssistantMode.textReader) {
      final changed = await _switchAssistantMode(
        AssistantMode.textReader,
        reason: 'intent_read_text',
      );
      if (!changed) {
        await _speak(_modeUnavailableMessage(AssistantMode.textReader));
        return;
      }
    }
    if (!_cameraGranted || !_cameraStreaming) {
      await _initCameraLive();
      if (!_cameraGranted || !_cameraStreaming) {
        await _speak(
          _voiceText(
            ru: 'Для чтения текста нужна камера.',
            kk: 'Мәтінді оқу үшін камера қажет.',
          ),
        );
        return;
      }
    }
    await _runManualTextReadSession(
      rawText,
      source: _TextReaderReadSource.voice,
    );
  }

  Future<void> _kickTextReaderAutoReadAfterModeSwitch() async {
    await Future<void>.delayed(const Duration(milliseconds: 420));
    if (!mounted || _assistantMode != AssistantMode.textReader) return;
    if (_manualTextReadInProgress || _textReaderLoopBusy) return;
    if (!_cameraGranted || !_cameraStreaming) {
      await _initCameraLive();
      if (!mounted || _assistantMode != AssistantMode.textReader) return;
      if (!_cameraGranted || !_cameraStreaming) return;
    }
    await _runAutoTextReaderTick();
  }

  Future<void> _runManualTextReadSession(
    String rawText, {
    required _TextReaderReadSource source,
  }) async {
    if (source == _TextReaderReadSource.auto && _textReaderAutoPaused) {
      return;
    }
    if (_manualTextReadInProgress || _textReaderController.isBusy) {
      appLog('[TextReader][manual_session] skip busy source=${source.name}');
      return;
    }

    if (source != _TextReaderReadSource.auto) {
      _textReaderSessionCancelRequested = false;
    }
    _manualTextReadInProgress = true;
    _textReaderController.markIdle();
    _applyTextReaderState(TextReaderState.scanning);
    appLog('[TextReader][manual_session] start source=${source.name}');
    if (source != _TextReaderReadSource.auto) {
      _enterVoicePriorityWindow(reason: 'manual_text_read');
    }

    try {
      await _syncHeavyServices();
      if (!_cameraGranted) {
        await _initCameraLive();
      }
      if (!_cameraGranted) {
        _lastTextReaderFailureReason = 'camera_denied';
        _applyTextReaderState(
          TextReaderState.failed,
          failureReason: _lastTextReaderFailureReason,
        );
        appLog('[TextReader][manual_session] fail reason=camera_denied');
        if (source != _TextReaderReadSource.auto) {
          await _speak(
            _voiceText(
              ru: 'Для чтения текста нужна камера.',
              kk: 'Мәтінді оқу үшін камера қажет.',
            ),
          );
        }
        return;
      }
      if (!_cameraStreaming) {
        await _startCameraStream(reason: 'manual_text_read');
      }
      if (!_cameraStreaming) {
        _lastTextReaderFailureReason = 'camera_stream_unavailable';
        _applyTextReaderState(
          TextReaderState.failed,
          failureReason: _lastTextReaderFailureReason,
        );
        appLog(
          '[TextReader][manual_session] fail reason=camera_stream_unavailable',
        );
        if (source != _TextReaderReadSource.auto) {
          await _speak(_textReaderFailureMessage());
        }
        return;
      }

      final attempt = await _textReaderController.runManual(
        source: _toTextReaderReadSource(source),
      );
      _applyTextReaderState(
        attempt.state,
        failureReason: attempt.failureReason,
      );

      if (_textReaderSessionCancelRequested) {
        appLog('[TextReader][manual_session] cancel requested');
        return;
      }
      if (!attempt.hasResult) {
        final failureReason = attempt.failureReason ?? 'no_text';
        appLog(
          '[TextReader][manual_session] '
          '${attempt.skipped ? 'skip' : 'fail'} reason=$failureReason',
        );
        if (!attempt.skipped && source != _TextReaderReadSource.auto) {
          await _speak(_textReaderFailureMessage());
        }
        return;
      }

      await _handleTextReaderAttemptSuccess(
        rawText: rawText,
        source: source,
        result: attempt.result!,
      );
    } finally {
      _manualTextReadInProgress = false;
      if (!_isSpeaking &&
          !_textReaderAutoPaused &&
          _textReaderController.state != TextReaderState.failed) {
        _textReaderController.markIdle();
      }
      if (source != _TextReaderReadSource.auto) {
        _exitVoicePriorityWindow(reason: 'manual_text_read');
      }
      _applyTextReaderState(_textReaderController.state);
    }
  }

  Future<List<OnDeviceTextReadResult>>
  _collectManualTextReadCandidates() async {
    final results = <OnDeviceTextReadResult>[];
    final aggressiveShortText = _assistantMode == AssistantMode.textReader;
    for (var i = 0; i < _manualTextReadAttempts; i += 1) {
      if (_textReaderSessionCancelRequested) {
        break;
      }
      final attempt = i + 1;
      final timeout = Duration(
        milliseconds: i == 0
            ? _manualTextReadFirstTimeoutMs
            : _manualTextReadRetryTimeoutMs,
      );
      final frame = await _prepareTextReaderFrame(timeout: timeout);
      if (frame == null) {
        appLog('[TextReader][manual_session] attempt=$attempt no_frame');
      } else {
        final result = await _textReaderService.readFrame(
          frame,
          force: true,
          aggressiveShortText: aggressiveShortText,
        );
        if (result == null || !result.hasRawText) {
          appLog('[TextReader][manual_session] attempt=$attempt no_result');
        } else {
          final text = _resolveManualSpeechText(result);
          final effectiveScript = _effectiveManualScript(result, text);
          appLog(
            '[TextReader][manual_session] attempt=$attempt '
            'score=${_scoreManualTextReadCandidate(result).toStringAsFixed(1)} '
            'script=${effectiveScript.name} '
            'raw="${_truncateForLog(result.rawText)}" '
            'text="${_truncateForLog(text)}"',
          );
          results.add(result);
          final stableRepeats = _countStableManualCandidates(results, text);
          final assessment = _assessTextReaderCandidate(
            result,
            resolvedTextOverride: text,
            stableRepeats: stableRepeats,
            allowVisionFallback: true,
          );
          if (assessment.disposition != TextReaderCandidateDisposition.reject) {
            appLog(
              '[TextReader][manual_session] early_accept '
              'attempt=$attempt '
              'score=${assessment.score.toStringAsFixed(1)} '
              'stable_repeats=$stableRepeats '
              'disposition=${assessment.disposition.name}',
            );
            break;
          }
        }
      }
      if (i < _manualTextReadAttempts - 1) {
        await Future<void>.delayed(
          const Duration(milliseconds: _manualTextReadInterAttemptDelayMs),
        );
      }
    }
    return results;
  }

  double _scoreManualTextReadCandidate(OnDeviceTextReadResult result) {
    final resolvedText = _resolveManualSpeechText(result);
    return _assessTextReaderCandidate(
      result,
      resolvedTextOverride: resolvedText,
      allowVisionFallback: true,
    ).score;
  }

  TextReaderCandidateAssessment _assessTextReaderCandidate(
    OnDeviceTextReadResult result, {
    int stableRepeats = 0,
    bool allowVisionFallback = true,
    String? resolvedTextOverride,
  }) {
    final resolvedText =
        (resolvedTextOverride ?? _resolveManualSpeechText(result)).trim();
    final effectiveScript = _effectiveManualScript(result, resolvedText);
    final aggressiveShortText = _assistantMode == AssistantMode.textReader;
    return assessTextReaderCandidate(
      rawText: result.rawText,
      resolvedText: resolvedText,
      manualSpeechLinesCount: result.blocks.length,
      rawDominantScript: result.rawDominantScript,
      effectiveScript: effectiveScript,
      hasStructuredData: result.hasStructuredData,
      stableRepeats: stableRepeats,
      acceptScore: aggressiveShortText
          ? _manualTextReadAggressiveAcceptScore
          : _manualTextReadAcceptScore,
      allowVisionFallback: allowVisionFallback,
      aggressiveShortText: aggressiveShortText,
    );
  }

  String _resolveManualSpeechText(OnDeviceTextReadResult result) {
    if (result.hasStructuredData) {
      if (result.price != null && result.calories != null) {
        return 'Цена ${result.price} тенге, калорийность ${result.calories} ккал';
      }
      if (result.price != null) return 'Цена ${result.price} тенге';
      if (result.calories != null) return '${result.calories} ккал';
    }

    if (result.blocks.isNotEmpty) {
      return result.blocks.join('. ');
    }

    return result.manualFallbackText;
  }

  int _countStableManualCandidates(
    List<OnDeviceTextReadResult> candidates,
    String resolvedText,
  ) {
    final selectedSignature = buildManualCandidateSignature(resolvedText);
    if (selectedSignature.isEmpty) return 0;
    return candidates.where((candidate) {
      final candidateText = _resolveManualSpeechText(candidate);
      final candidateSignature = buildManualCandidateSignature(candidateText);
      return candidateSignature.isNotEmpty &&
          candidateSignature == selectedSignature;
    }).length;
  }

  DetectedTextScript _effectiveManualScript(
    OnDeviceTextReadResult result, [
    String? resolvedTextOverride,
  ]) {
    final resolvedText =
        (resolvedTextOverride ?? _resolveManualSpeechText(result)).trim();
    if (resolvedText.isEmpty) {
      return result.rawDominantScript;
    }
    final resolvedScript = TextReadingNormalizer.detectScript(resolvedText);
    if (resolvedScript == DetectedTextScript.unknown) {
      return result.rawDominantScript;
    }
    return resolvedScript;
  }

  String _buildApproximateTextReaderAnswer(OnDeviceTextReadResult result) {
    final spokenText = _truncateForSpeech(_resolveManualSpeechText(result));
    if (spokenText.isEmpty) {
      return _textReaderFailureMessage();
    }
    return _voiceText(
      ru: 'Примерно прочитанный текст: $spokenText',
      kk: 'Шамамен оқылған мәтін: $spokenText',
    );
  }

  bool _isTextReaderStructuredQuery(String normalizedUserText) {
    return normalizedUserText.contains('цен') ||
        normalizedUserText.contains('price') ||
        normalizedUserText.contains('калор') ||
        normalizedUserText.contains('kcal');
  }

  List<String> _buildTextReaderSpeechSegments(
    OnDeviceTextReadResult result, {
    String? overrideText,
  }) {
    final override = overrideText?.trim() ?? '';
    if (override.isNotEmpty) {
      return _splitTextReaderSpeechSegments(override);
    }

    if (!result.hasStructuredData &&
        (result.looksPseudoRussianOcr ||
            result.rawDominantScript == DetectedTextScript.mixed ||
            result.rawDominantScript == DetectedTextScript.unknown)) {
      return const <String>[];
    }

    if (result.blocks.isNotEmpty) {
      return result.blocks
          .expand(_splitMixedLanguageSpeechSegments)
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
    }

    return _splitTextReaderSpeechSegments(_resolveManualSpeechText(result));
  }

  List<String> _buildAutoTextReaderSpeechSegments(
    OnDeviceTextReadResult result,
  ) {
    if (!result.hasStructuredData &&
        (result.looksPseudoRussianOcr ||
            result.rawDominantScript == DetectedTextScript.mixed ||
            result.rawDominantScript == DetectedTextScript.unknown)) {
      return const <String>[];
    }
    if (result.blocks.isNotEmpty) {
      return result.blocks.take(1).toList();
    }
    return const <String>[];
  }

  List<String> _splitTextReaderSpeechSegments(String text) {
    final source = text.trim();
    if (source.isEmpty) return const <String>[];
    final segments = _splitTextReaderSpeechUnits(source)
        .expand(_splitMixedLanguageSpeechSegments)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (segments.isNotEmpty) {
      return segments;
    }
    return <String>[
      _truncateForSpeech(source, maxChars: 220),
    ].where((line) => line.isNotEmpty).toList(growable: false);
  }

  List<String> _splitTextReaderSpeechUnits(String text) {
    final source = text.trim();
    if (source.isEmpty) return const <String>[];
    final normalized = source
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ');
    final lines = normalized
        .split(RegExp(r'\n+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length > 1) {
      return lines;
    }
    final sentences = source
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (sentences.length > 1) {
      return sentences;
    }
    return <String>[source];
  }

  List<String> _splitMixedLanguageSpeechSegments(String text) {
    final source = text.trim();
    if (source.isEmpty) return const <String>[];

    final tokens = RegExp(
      r'[A-Za-z]+|[А-Яа-яЁё]+|[0-9]+|[^A-Za-zА-Яа-яЁё0-9]+',
      unicode: true,
    ).allMatches(source).map((match) => match.group(0) ?? '').toList();
    if (tokens.isEmpty) {
      return <String>[
        _truncateForSpeech(source, maxChars: 180),
      ].where((line) => line.isNotEmpty).toList(growable: false);
    }

    final segments = <String>[];
    final buffer = StringBuffer();
    var currentScript = DetectedTextScript.unknown;

    void flush() {
      final chunk = _truncateForSpeech(
        buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
        maxChars: 180,
      );
      buffer.clear();
      currentScript = DetectedTextScript.unknown;
      if (chunk.isNotEmpty) {
        segments.add(chunk);
      }
    }

    for (final token in tokens) {
      if (token.isEmpty) continue;
      final tokenScript = TextReadingNormalizer.detectScript(token);
      if (tokenScript == DetectedTextScript.unknown) {
        if (buffer.isNotEmpty) {
          buffer.write(token);
        }
        continue;
      }

      if (buffer.isEmpty) {
        buffer.write(token);
        currentScript = tokenScript;
        continue;
      }

      if (currentScript == tokenScript ||
          currentScript == DetectedTextScript.unknown) {
        buffer.write(token);
        currentScript = tokenScript;
        continue;
      }

      flush();
      buffer.write(token);
      currentScript = tokenScript;
    }

    flush();
    return segments;
  }

  String _buildTextReaderSpeechSignature(
    List<String> segments, {
    OnDeviceTextReadResult? result,
  }) {
    final compact = segments
        .map((segment) => segment.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((segment) => segment.isNotEmpty)
        .join(' | ');
    if (compact.isEmpty) return '';
    final suffix = <String>[
      if (result?.price != null)
        'price:${result!.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
      if (result?.calories != null) 'cal:${result!.calories}',
    ].join('|');
    return suffix.isEmpty ? compact : '$compact|$suffix';
  }

  bool _shouldSpeakAutoTextReaderTranscript(
    List<String> segments, {
    OnDeviceTextReadResult? result,
  }) {
    final signature = _buildTextReaderSpeechSignature(segments, result: result);
    if (signature.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (signature == _lastAutoTextReaderSignature) return false;
    if (now - _lastAutoTextReaderSpeakMs < _textReaderSpeechCooldownMs) {
      return false;
    }
    _lastAutoTextReaderSignature = signature;
    _lastAutoTextReaderSpeakMs = now;
    return true;
  }

  bool _markAutoTextReaderCandidateSeen(
    String signature, {
    int? requiredSeenCount,
  }) {
    final value = signature.trim();
    if (value.isEmpty) {
      _resetTextReaderAutoState();
      return false;
    }
    if (_pendingAutoTextReaderSignature == value) {
      _pendingAutoTextReaderSeenCount += 1;
    } else {
      _pendingAutoTextReaderSignature = value;
      _pendingAutoTextReaderSeenCount = 1;
    }
    return _pendingAutoTextReaderSeenCount >=
        (requiredSeenCount ?? _textReaderStableFramesRequired);
  }

  bool _shouldTriggerAutoExactTextRead(OnDeviceTextReadResult result) {
    final resolvedText = _resolveManualSpeechText(result);
    final rawText = result.rawText.trim();
    final candidateText = resolvedText.isNotEmpty ? resolvedText : rawText;
    final candidateSignature = buildManualCandidateSignature(candidateText);
    final inTextReaderMode = _assistantMode == AssistantMode.textReader;
    final requiredSeenCount = inTextReaderMode ? 2 : null;
    if (candidateSignature.isEmpty) {
      _resetTextReaderAutoState();
      return false;
    }
    final hasEnoughSignal =
        result.hasStructuredData ||
        rawText.length >= 48 ||
        resolvedText.length >= 24 ||
        result.blocks.length >= 2 ||
        (inTextReaderMode &&
            (rawText.length >= 12 ||
                resolvedText.length >= 8 ||
                result.blocks.isNotEmpty ||
                result.manualFallbackText.trim().isNotEmpty));
    if (!hasEnoughSignal) {
      return false;
    }
    if (!_markAutoTextReaderCandidateSeen(
      'exact:$candidateSignature',
      requiredSeenCount: requiredSeenCount,
    )) {
      return false;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastAutoTextReaderExactSignature == candidateSignature &&
        now - _lastAutoTextReaderExactMs < _textReaderAutoExactCooldownMs) {
      return false;
    }

    final assessment = _assessTextReaderCandidate(
      result,
      resolvedTextOverride: resolvedText,
      stableRepeats: _pendingAutoTextReaderSeenCount,
      allowVisionFallback: inTextReaderMode,
    );

    if (!TextReadingNormalizer.isSpeechSafe(resolvedText) &&
        !result.hasStructuredData &&
        !assessment.requiresVisionFallback) {
      if (assessment.score >= _manualTextReadAcceptScore) {
        appLog(
          '[TextReader][auto] ignoring unsafe text candidate: "$resolvedText"',
        );
      }
      return false;
    }

    if (inTextReaderMode &&
        assessment.acceptsDirectSpeech &&
        !_isAutoTextReaderDirectSpeechStableEnough(
          result,
          resolvedText: resolvedText,
          stableRepeats: _pendingAutoTextReaderSeenCount,
          score: assessment.score,
        )) {
      return false;
    }

    final shouldTrigger =
        assessment.acceptsDirectSpeech ||
        assessment.structuredOnlyAccepted ||
        assessment.requiresVisionFallback;
    if (!shouldTrigger) {
      return false;
    }

    _lastAutoTextReaderExactSignature = candidateSignature;
    _lastAutoTextReaderExactMs = now;
    return true;
  }

  bool _isAutoTextReaderDirectSpeechStableEnough(
    OnDeviceTextReadResult result, {
    required String resolvedText,
    required int stableRepeats,
    required double score,
  }) {
    if (result.hasStructuredData) return true;
    final compactLength = RegExp(
      r'[A-Za-zА-Яа-яЁё0-9]',
      unicode: true,
    ).allMatches(resolvedText).length;
    final shortSingleBlock = compactLength < 12 && result.blocks.length <= 1;
    if (!shortSingleBlock) return true;
    return stableRepeats >= 3 && score >= 24.0;
  }

  Future<String?> _tryFastTextReaderVisionTranscript(
    OnDeviceTextReadResult result, {
    required bool autoRead,
    required String reason,
  }) async {
    if (_assistantMode != AssistantMode.textReader) return null;
    if (result.hasStructuredData) return null;
    if (_llmRateLimitRemaining() != null) return null;
    if (_gptStatus == GptStatus.loading || _textReaderVisionRequestInFlight) {
      return null;
    }
    final candidateText = _resolveManualSpeechText(result).trim().isNotEmpty
        ? _resolveManualSpeechText(result)
        : result.rawText;
    final signature = buildManualCandidateSignature(candidateText);
    if (signature.isEmpty) return null;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTextReaderVisionSignature == signature &&
        now - _lastTextReaderVisionMs < _textReaderVisionCooldownMs) {
      appLog(
        '[TextReader][vision_fast] skip cooldown '
        'reason=$reason auto=$autoRead signature=$signature',
      );
      return null;
    }

    _lastTextReaderVisionSignature = signature;
    _lastTextReaderVisionMs = now;
    appLog(
      '[TextReader][vision_fast] start '
      'reason=$reason auto=$autoRead signature=$signature',
    );
    return _tryTextReaderVisionFallback(
      fastMode: true,
      autoRead: autoRead,
      reason: reason,
    );
  }

  Future<void> _pauseWakeFallbackForAutoTextRead() async {
    var stoppedWakeFallback = false;
    await _stopPrimaryWake(reason: 'auto_text_read');
    if (_wakeFallbackActive || _wakeFallbackLoopRunning) {
      _stopWakeFallbackLoop();
      stoppedWakeFallback = true;
    }
    if (_sttService.isListening) {
      await _sttService.stop();
      stoppedWakeFallback = true;
    }
    if (stoppedWakeFallback) {
      appLog('[TextReader][auto] paused wake fallback');
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _speakTextReaderSegments(
    List<String> segments, {
    required bool autoRead,
  }) async {
    _textReaderSessionCancelRequested = false;
    final now = DateTime.now();
    if (now.difference(_lastReadClearTime).inSeconds > 30) {
      _recentReadSegments.clear();
      _lastReadClearTime = now;
    }

    for (final segment in segments) {
      if (_textReaderSessionCancelRequested) {
        appLog('[TextReader][speech] canceled');
        return;
      }
      final text = segment.trim();
      if (text.isEmpty) continue;

      // Filter out seen segments to avoid annoying loops
      if (autoRead && _isAlreadyReadFuzzy(text)) {
        continue;
      }

      final useEnglish = TextReadingNormalizer.shouldUseEnglishTts(text);

      final speechText = TextReadingNormalizer.normalizeForTts(
        text,
        useEnglishVoice: useEnglish,
      );

      // Secondary junk filter before deciding to speak AND before pausing mic
      if (!TextReadingNormalizer.isSpeechSafe(speechText)) {
        appLog('[TextReader][speech] skipping unsafe segment: "$speechText"');
        continue;
      }

      // ONLY pause mic here, when we are 100% sure we will speak
      if (autoRead) {
        await _pauseWakeFallbackForAutoTextRead();
      }

      await _ensureTtsLocaleForSpokenText(text, autoRead: autoRead);
      _recentReadSegments.add(speechText);
      appLog('[TextReader][speech] speak: "$speechText" (english=$useEnglish)');
      await _speak(speechText, ensureLocale: false);
    }
  }

  bool _isAlreadyReadFuzzy(String text) {
    if (_recentReadSegments.isEmpty) return false;
    final signature = buildManualCandidateSignature(text);
    if (signature.isEmpty) return false;

    for (final recent in _recentReadSegments) {
      final recentSignature = buildManualCandidateSignature(recent);
      // If we already read something that contains this new fragment, skip it.
      if (recentSignature.contains(signature)) {
        return true;
      }
    }
    return false;
  }

  Future<String?> _tryTextReaderVisionFallback({
    bool fastMode = false,
    bool autoRead = false,
    String reason = 'fallback',
    int? timeoutMs,
    int? maxAttempts,
  }) async {
    if (_gptStatus == GptStatus.loading ||
        _textReaderVisionRequestInFlight ||
        _llmRateLimitRemaining() != null) {
      return null;
    }
    _textReaderVisionRequestInFlight = true;
    final jpegBytes = await _captureLatestJpegFrame();
    if (jpegBytes == null || jpegBytes.isEmpty) {
      _textReaderVisionRequestInFlight = false;
      appLog('[TextReader][vision_fallback] no_frame');
      return null;
    }

    final systemPrompt = _voiceText(
      ru: fastMode
          ? 'Ты — быстрый OCR для незрячего пользователя. Верни только чёткий видимый печатный текст. Сохрани язык оригинала. Без пояснений. Если текста нет или он нечёткий, верни строго NO_TEXT.'
          : 'Ты — ассистент для незрячих. Извлеки только печатный текст с изображения. Сохрани оригинальный язык. Верни ЧИСТЫЙ ТЕКСТ без своих комментариев. Если текста нет или он неразборчив, верни СТРОГО: NO_TEXT.',
      kk: fastMode
          ? 'Сен — зағип пайдаланушыға арналған жылдам OCR. Тек анық көрінетін баспа мәтінді қайтар. Түпнұсқа тілін сақта. Еш түсіндірмесіз. Егер мәтін жоқ немесе анық емес болса, қатаң түрде NO_TEXT деп қайтар.'
          : 'Сен — зағип жандарға көмекшісің. Суреттегі баспа мәтінді ғана тауып шығар. Түпнұсқа тілін сақта. Өз пікіріңсіз ТЕК МӘТІНДІ қайтар. Егер мәтін жоқ болса, СТРОГО: NO_TEXT деп жаз.',
    );
    final userPrompt = _voiceText(
      ru: fastMode
          ? 'Быстро верни только текст на изображении. Иначе NO_TEXT.'
          : 'Прочитай текст на картинке. Если его нет, ответь NO_TEXT.',
      kk: fastMode
          ? 'Суреттен тек мәтінді жылдам қайтар. Әйтпесе NO_TEXT.'
          : 'Суреттегі мәтінді оқы. Егер мәтін жоқ болса, NO_TEXT деп жауап бер.',
    );

    try {
      appLog(
        '[TextReader][vision_fallback] start '
        'fast=$fastMode auto=$autoRead reason=$reason',
      );
      final raw = await _openAi.askWithImage(
        userPrompt,
        jpegBytes,
        systemPrompt: _openAi.buildSystemPrompt(basePrompt: systemPrompt),
        history: const <OpenAiChatMessage>[],
        taskMode: 'text_reader_ocr',
        perceptionSnapshot: <String, Object?>{
          'ocr_only': true,
          'fast_mode': fastMode,
          'auto_read': autoRead,
        },
        maxOutputTokens: fastMode ? 120 : 220,
        requestTimeout: Duration(
          milliseconds: timeoutMs ?? _textReaderVisionTimeoutMs,
        ),
        maxAttempts: maxAttempts ?? (fastMode ? 1 : 3),
      );
      final text = _postprocessTextReaderVisionTranscript(raw);
      if (text.isEmpty) {
        appLog('[TextReader][vision_fallback] empty');
        return null;
      }
      appLog(
        '[TextReader][vision_fallback] ok text="${_truncateForLog(text)}"',
      );
      return text;
    } on LlmRateLimitException catch (e) {
      _applyLlmRateLimit(e.retryAfter);
      appLog('[TextReader][vision_fallback] rate_limit: ${e.message}');
      return null;
    } catch (e) {
      appLog('[TextReader][vision_fallback] error: $e');
      return null;
    } finally {
      _textReaderVisionRequestInFlight = false;
    }
  }

  String _postprocessTextReaderVisionTranscript(String rawText) {
    var text = rawText.trim();
    if (text.isEmpty) return '';
    if (text.toUpperCase() == 'NO_TEXT') return '';
    text = text
        .replaceFirst(
          RegExp(
            r'^(видимый текст|текст|прочитанный текст|мәтін)\s*[:\-]\s*',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '';
    if (_visionIncompleteMessage() == text) return '';
    return text;
  }

  String _buildDirectTextReadAnswer(
    String spokenText, {
    OnDeviceTextReadResult? result,
  }) {
    final text = _truncateForSpeech(spokenText, maxChars: 220);
    if (text.isEmpty) {
      return _textReaderFailureMessage();
    }
    final isLatinManual = TextReadingNormalizer.shouldUseEnglishTts(text);
    final parts = <String>[];
    if (result?.price != null) {
      parts.add(
        _voiceText(
          ru: 'Цена ${result!.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
          kk: 'Бағасы ${result!.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
        ),
      );
    }
    if (result?.calories != null) {
      parts.add(
        _voiceText(
          ru: 'Калорийность ${result!.calories} ккал',
          kk: 'Калориясы ${result!.calories} ккал',
        ),
      );
    }
    final meta = parts.isEmpty ? '' : '${parts.join('. ')}. ';
    if (isLatinManual && meta.isEmpty) {
      return text;
    }
    return _voiceText(
      ru: '${meta}Прочитанный текст: $text',
      kk: '${meta}Оқылған мәтін: $text',
    );
  }

  String _textReaderFailureMessage() {
    return _voiceText(
      ru: 'Не смогла уверенно прочитать текст. Поднесите ближе и держите ровно.',
      kk: 'Мәтінді сенімді оқи алмадым. Камераны жақындатып, түзу ұстаңыз.',
    );
  }

  Future<void> _handleShoppingModeCommand(String userText) async {
    final normalized = _router.normalize(userText);
    if (normalized.contains('цен') ||
        normalized.contains('бағ') ||
        normalized.contains('price')) {
      await _handleTextReaderModeCommand(userText);
      return;
    }
    if (_looksLikeShoppingListSetup(userText)) {
      final session = await _shoppingModeService.startSessionFromText(userText);
      final items = session.items.map((item) => item.name).join(', ');
      final answer = _voiceText(
        ru: 'Список покупок запущен: $items.',
        kk: 'Тізім басталды: $items.',
      );
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }

    final pickedItem = _extractPickedShoppingItem(userText);
    if (pickedItem != null) {
      final session = await _shoppingModeService.markPicked(pickedItem);
      if (session == null) {
        await _speak(
          _voiceText(
            ru: 'Сначала продиктуйте список покупок.',
            kk: 'Алдымен тізімді айтыңыз.',
          ),
        );
        return;
      }
      final pending = session.pendingItems.map((item) => item.name).join(', ');
      final answer = pending.isEmpty
          ? _voiceText(
              ru: 'Все покупки отмечены.',
              kk: 'Барлық сатып алу белгіленді.',
            )
          : _voiceText(
              ru: 'Отметила. Осталось: $pending.',
              kk: 'Белгіледім. Қалғаны: $pending.',
            );
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }

    final session = await _shoppingModeService.currentSession();
    if (session == null || session.items.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'В режиме шопинга сначала скажите список покупок.',
          kk: 'Сатып алу режимінде алдымен тізімді айтыңыз.',
        ),
      );
      return;
    }

    final pending = session.pendingItems;
    if (_asksShoppingStatus(userText)) {
      final answer = pending.isEmpty
          ? _voiceText(ru: 'Список уже закрыт.', kk: 'Тізім толық жабылды.')
          : _voiceText(
              ru: 'Осталось купить: ${pending.map((item) => item.name).join(', ')}.',
              kk: 'Қалған тауарлар: ${pending.map((item) => item.name).join(', ')}.',
            );
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }

    final target = _extractFindTarget(userText) ?? pending.first.name;
    await _describeWithVision(
      'Найди товар: $target. Подскажи направление и как взять.',
      systemPrompt: _buildVisionPrompt(
        extraInstruction: _voiceText(
          ru: 'Это shopping режим. Ищи товар на полке, говори коротко направление и конкретное действие для подхода.',
          kk: 'Бұл shopping режимі. Тауарды ізде, сөре бағытын қысқа айт, жақындау үшін нақты қимыл ұсын.',
        ),
      ),
    );
  }

  Future<void> _handleCookingModeCommand(String userText) async {
    await _describeWithVision(userText, systemPrompt: _buildVisionPrompt());
  }

  Future<void> _handleDressCodeModeCommand(String userText) async {
    final answer = await _buildDressCodeAnswer(userText);
    _rememberDialogTurn(userText, answer);
    _lastAnswer = answer;
    await _speak(answer);
  }

  Future<void> _handleAntiFraudModeCommand(String userText) async {
    final normalized = _router.normalize(userText);
    if (normalized.contains('цена') ||
        normalized.contains('чек') ||
        normalized.contains('калор')) {
      await _handleTextReaderModeCommand(userText);
      return;
    }
    await _describeWithVision(userText, systemPrompt: _buildVisionPrompt());
  }

  Future<void> _handleMemoryModeCommand(String userText) async {
    final anchorName = _extractMemoryAnchorName(userText);
    if (anchorName != null) {
      String? summary;
      try {
        if (_looksLikeSceneMemoryCapture(anchorName)) {
          summary = await _captureSceneAnchorSummary(anchorName);
        } else {
          summary = anchorName;
        }
      } catch (e) {
        appLog('[Memory] save anchor failed: $e');
      }
      if (summary == null) {
        await _speak(
          _voiceText(
            ru: 'Не смогла надежно сохранить текущую сцену.',
            kk: 'Сахнаны сенімді сақтай алмадым.',
          ),
        );
        return;
      }
      await _sceneMemoryService.saveAnchor(
        anchorName: anchorName,
        summary: summary,
      );
      final answer = _voiceText(
        ru: 'Сохранила как "$anchorName".',
        kk: '"$anchorName" ретінде сақтадым.',
      );
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }

    final lookup = _extractMemoryLookupName(userText);
    if (lookup != null) {
      final anchor = await _sceneMemoryService.findBestAnchor(lookup);
      if (anchor == null) {
        await _speak(
          _voiceText(
            ru: 'Не нашла сохраненный якорь с таким именем.',
            kk: 'Бұл атаумен сақталған якорь табылмады.',
          ),
        );
        return;
      }
      final answer = _voiceText(
        ru: 'Для "${anchor.name}" сохранено: ${anchor.summary}',
        kk: '"${anchor.name}" үшін сақталған сипаттама: ${anchor.summary}',
      );
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }

    final anchors = await _sceneMemoryService.recentAnchors();
    if (anchors.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'Пока нет сохраненных якорей сцены.',
          kk: 'Әзірге сақталған сахна якорьлері жоқ.',
        ),
      );
      return;
    }
    final answer = _voiceText(
      ru: 'Последние сохраненные якоря: ${anchors.map((item) => item.name).join(', ')}.',
      kk: 'Соңғы сақталған якорьлер: ${anchors.map((item) => item.name).join(', ')}.',
    );
    _rememberDialogTurn(userText, answer);
    _lastAnswer = answer;
    await _speak(answer);
  }

  Future<void> _handleFindModeCommand(String userText) async {
    final target = _extractFindTarget(userText);
    if (target == null || target.isEmpty) {
      await _speak(
        _voiceText(
          ru: 'Скажите, что именно нужно найти.',
          kk: 'Нені табу керек екенін айтыңыз.',
        ),
      );
      return;
    }
    final match = _matchFindTargetAgainstDetections(target);
    if (match != null) {
      final answer = _buildFindDetectionAnswer(target, match);
      _rememberDialogTurn(userText, answer);
      _lastAnswer = answer;
      await _speak(answer);
      return;
    }
    await _describeWithVision(
      'Найди объект: $target. Скажи, виден ли он и куда двигаться.',
      systemPrompt: _buildVisionPrompt(),
    );
  }

  Future<void> _enterNavigationMode() async {
    if (_assistantMode == AssistantMode.navigation) {
      await _speak(_voiceL10n.routeModeAlreadyEnabled);
      return;
    }
    final changed = await _switchAssistantMode(
      AssistantMode.navigation,
      reason: 'intent_enter_nav',
    );
    if (!changed) {
      await _speak(_voiceL10n.commandProcessingFailed);
    }
  }

  Future<void> _exitNavigationMode() async {
    if (_assistantMode != AssistantMode.navigation) {
      await _speak(_voiceL10n.routeModeNotEnabled);
      return;
    }
    final changed = await _switchAssistantMode(
      AssistantMode.general,
      reason: 'intent_exit_nav',
    );
    if (!changed) {
      await _speak(_voiceL10n.commandProcessingFailed);
    }
  }

  Future<bool> _switchAssistantMode(
    AssistantMode target, {
    required String reason,
    bool autoTriggered = false,
  }) async {
    if (_assistantMode == target) return true;
    if (!_isModeEnabled(target)) return false;

    if (_assistantMode == AssistantMode.navigation &&
        target != AssistantMode.navigation) {
      await _navigationController.exitMode();
      _lastNavCameraTarget = null;
    }

    if (target == AssistantMode.navigation &&
        _assistantMode != AssistantMode.navigation) {
      await _navigationController.enterMode();
      if (!_navigationController.state.value.modeEnabled) {
        return false;
      }
      _lastNavCameraTarget = null;
      if (_modeNeedsLiveCamera(target)) {
        unawaited(_initCameraLive());
      }
    } else if (_modeNeedsLiveCamera(target)) {
      unawaited(_initCameraLive());
    } else {
      unawaited(_stopCameraStream(reason: 'mode_switch_$reason'));
    }

    unawaited(_tts.stop());
    _assistantMode = target;
    if (target != AssistantMode.textReader) {
      _textReaderController.stop();
      _textReaderAutoPaused = false;
      _textReaderSessionCancelRequested = false;
    } else {
      _textReaderController.resume(clearSpokenSignature: true);
      _textReaderAutoPaused = false;
      _textReaderSessionCancelRequested = false;
    }
    _applyTextReaderState(_textReaderController.state, updateUi: false);
    _modeOrchestrator.transitionTo(
      _toJanarymMode(target),
      subState: 'active',
      autoTriggered: autoTriggered,
      autoTriggeredBy: reason,
    );
    unawaited(_syncHeavyServices());
    if (target == AssistantMode.textReader) {
      unawaited(_kickTextReaderAutoReadAfterModeSwitch());
    }

    if (mounted) {
      setState(() {});
    }
    appLog('[Mode] switched to ${target.name} (reason=$reason)');
    return true;
  }

  Future<void> _askGpt(String text, {String? systemPrompt}) async {
    if (await _speakLlmCooldownMessageIfNeeded()) return;
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    appLog('[GPT] start');
    final localRequestId = _requestId;
    if (!_thinkingSoundPlayed) {
      _thinkingSoundPlayed = true;
      await _playThinkingCue();
      await _vibrateThinking();
    }
    _setCircleState(CircleState.thinking);
    await Future.delayed(const Duration(milliseconds: 450));

    try {
      final personalizationContext = _personalizationReady
          ? OpenAiPersonalizationContext(
              responseLength: _personalizationController
                  .snapshot
                  .profile
                  .responseLength
                  .storageValue,
              toneStyle: _personalizationController
                  .snapshot
                  .profile
                  .toneStyle
                  .storageValue,
              warningIntensity:
                  _personalizationController.snapshot.profile.warningIntensity,
              activeFearTriggers:
                  _personalizationController.snapshot.activeFearTexts,
            )
          : null;
      final mergedSystemPrompt = _openAi.buildSystemPrompt(
        basePrompt: systemPrompt,
        personalization: personalizationContext,
      );
      final rawAnswer = await _openAi.askTextOnly(
        text,
        systemPrompt: mergedSystemPrompt,
        history: _dialogHistoryMessages(),
        contextMode: _assistantModeContextKey(_assistantMode),
        safetyContext: _activeSafetyContext(),
        sceneSummary: _sceneSummaryForPrompt(),
        maxOutputTokens: _maxTextOutputTokens(),
      );
      final answer = _postprocessDialogAnswer(rawAnswer);
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      _rememberDialogTurn(text, answer);
      appLog('[GPT] ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_voiceL10n.followUpNeedAnythingElse);
        await _startFollowUpWindow();
      }
    } on LlmRateLimitException catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      _applyLlmRateLimit(e.retryAfter);
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.message;
      });
      appLog('[GPT] rate limit: ${e.message}');
      await _speak(_llmRateLimitMessage());
    } catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      appLog('[GPT] error: $e');
      await _speak(_voiceL10n.commandProcessingFailed);
    }
    _thinkingSoundPlayed = false;
  }

  Future<void> _askGptWithImage(
    String text,
    Uint8List imageBytes, {
    String? systemPrompt,
  }) async {
    if (await _speakLlmCooldownMessageIfNeeded()) return;
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    appLog('[GPT] vision start');
    final localRequestId = _requestId;
    if (!_thinkingSoundPlayed) {
      _thinkingSoundPlayed = true;
      await _playThinkingCue();
      await _vibrateThinking();
    }
    _setCircleState(CircleState.thinking);

    try {
      final allowNumbers = _userRequestedNumericDetails(text);
      final mergedSystemPrompt = _openAi.buildSystemPrompt(
        basePrompt: systemPrompt,
      );
      final rawAnswer = await _openAi.askWithImage(
        text,
        imageBytes,
        systemPrompt: mergedSystemPrompt,
        history: _dialogHistoryMessages(),
        taskMode: _assistantModeContextKey(_assistantMode),
        perceptionSnapshot: _buildPerceptionSnapshot(),
        maxOutputTokens: _maxVisionOutputTokens(),
      );
      appLog('[GPT] vision raw: ${_truncateForLog(rawAnswer)}');
      var answer = _postprocessVisionAnswer(
        rawAnswer,
        allowNumbers: allowNumbers,
      );
      answer = _postprocessDialogAnswer(answer);
      appLog(
        '[GPT] vision final (allowNumbers=$allowNumbers): '
        '${_truncateForLog(answer)}',
      );
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      _rememberDialogTurn(text, answer);
      appLog('[GPT] vision ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_voiceL10n.followUpNeedAnythingElse);
        await _startFollowUpWindow();
      }
    } on LlmRateLimitException catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      _applyLlmRateLimit(e.retryAfter);
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.message;
      });
      appLog('[GPT] vision rate limit: ${e.message}');
      await _speak(_llmRateLimitMessage());
    } catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      appLog('[GPT] vision error: $e');
      await _speak(_voiceL10n.commandProcessingFailed);
    }
    _thinkingSoundPlayed = false;
  }

  Future<void> _describeWithVision(String text, {String? systemPrompt}) async {
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) {
        await _speak(_voiceL10n.noCameraAccess);
        return;
      }
    }

    if (!_cameraStreaming) {
      await _startCameraStream(reason: 'vision_request');
    }

    var frameReady = await _waitForFreshFrame(
      timeout: const Duration(milliseconds: 1400),
    );
    if (!frameReady) {
      await _startCameraStream(reason: 'vision_retry_after_frame_timeout');
      frameReady = await _waitForFreshFrame(
        timeout: const Duration(milliseconds: 1200),
      );
      if (!frameReady) {
        await _speak(_voiceL10n.fastFrameUnavailable);
        return;
      }
    }

    final frameAt = _lastFrameAt;
    if (frameAt == null) {
      await _speak(_voiceL10n.frameUnavailable);
      return;
    }

    final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
    if (ageMs > _maxFrameAgeMs &&
        !await _waitForFreshFrame(timeout: const Duration(milliseconds: 500))) {
      await _speak(_voiceL10n.staleFrameUnavailable);
      return;
    }

    appLog('[VISION] send last frame to GPT');
    final frame = _lastFrame!;
    final jpegBytes = await compute(convertNv21ToJpeg, frame.toJpegPayload());
    await _askGptWithImage(
      text,
      jpegBytes,
      systemPrompt: systemPrompt ?? _buildVisionPrompt(),
    );
  }

  Future<Uint8List?> _captureLatestJpegFrame() async {
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) return null;
    }
    if (!_cameraStreaming) {
      await _startCameraStream(reason: 'jpeg_capture_request');
    }

    var frameReady = await _waitForFreshFrame(
      timeout: const Duration(milliseconds: 1400),
    );
    if (!frameReady) {
      await _startCameraStream(reason: 'jpeg_capture_retry');
      frameReady = await _waitForFreshFrame(
        timeout: const Duration(milliseconds: 1200),
      );
      if (!frameReady || _lastFrame == null) return null;
    }

    final frameAt = _lastFrameAt;
    if (frameAt == null || _lastFrame == null) return null;
    final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
    if (ageMs > _maxFrameAgeMs &&
        !await _waitForFreshFrame(timeout: const Duration(milliseconds: 500))) {
      return null;
    }
    return compute(convertNv21ToJpeg, _lastFrame!.toJpegPayload());
  }

  Future<CameraFrameSnapshot?> _prepareTextReaderFrame({
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    if (!_currentModeDescriptor().perception.enableOcr) {
      return null;
    }
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) return null;
    }
    if (!_cameraStreaming) {
      await _startCameraStream(reason: 'ocr_frame_request');
    }
    if (!await _waitForFreshFrame(timeout: timeout)) {
      appLog('[TextReader][frame] no_fresh_frame');
      return null;
    }
    final frame = _lastFrame;
    final frameAt = _lastFrameAt;
    if (frame == null || frameAt == null) {
      appLog('[TextReader][frame] missing_last_frame');
      return null;
    }
    final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
    if (ageMs > _maxFrameAgeMs) {
      appLog('[TextReader][frame] stale_frame age_ms=$ageMs');
      return null;
    }
    return frame;
  }

  Future<OnDeviceTextReadResult?> _readTextFromCurrentFrame({
    bool force = false,
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    if (_voicePriorityWindowActive && !force) {
      return null;
    }
    final frame = await _prepareTextReaderFrame(timeout: timeout);
    if (frame == null) return null;
    return _textReaderService.readFrame(
      frame,
      minInterval: Duration(milliseconds: _textReaderFrameIntervalMs),
      force: force,
      aggressiveShortText: _assistantMode == AssistantMode.textReader,
    );
  }

  String _textReaderKindForScan(TextReaderScanResult result) {
    final structured = result.structuredData;
    if (structured.price != null) return 'price';
    if (structured.calories != null) return 'nutrition';
    return 'document';
  }

  String _formatTextReaderPrice(double value) {
    return value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  }

  String _buildStructuredTextReaderSummary(TextReaderStructuredData data) {
    final parts = <String>[];
    if (data.price != null) {
      parts.add(
        _voiceText(
          ru: 'Цена ${_formatTextReaderPrice(data.price!)}',
          kk: 'Бағасы ${_formatTextReaderPrice(data.price!)}',
        ),
      );
    }
    if (data.calories != null) {
      parts.add(
        _voiceText(
          ru: 'Калорийность ${data.calories} ккал',
          kk: 'Калориясы ${data.calories} ккал',
        ),
      );
    }
    return parts.join('. ');
  }

  String _resolveTextReaderScanText(TextReaderScanResult result) {
    final fullText = result.fullText.trim();
    if (fullText.isNotEmpty) {
      return fullText;
    }
    return _buildStructuredTextReaderSummary(result.structuredData).trim();
  }

  List<String> _buildTextReaderSpeechSegmentsFromScan(
    TextReaderScanResult result,
  ) {
    final orderedLines = result.orderedLines
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (orderedLines.isEmpty) {
      return _splitTextReaderSpeechSegments(_resolveTextReaderScanText(result));
    }
    final segments = orderedLines
        .expand(_splitMixedLanguageSpeechSegments)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (segments.isNotEmpty) {
      return segments;
    }
    return _splitTextReaderSpeechSegments(_resolveTextReaderScanText(result));
  }

  String _buildTextReaderAnswerFromScan(
    TextReaderScanResult result, {
    required String normalizedUserText,
  }) {
    final structured = result.structuredData;
    if (normalizedUserText.contains('цен') ||
        normalizedUserText.contains('price')) {
      if (structured.price != null) {
        return _voiceText(
          ru: 'Цена примерно ${_formatTextReaderPrice(structured.price!)}.',
          kk: 'Бағасы шамамен ${_formatTextReaderPrice(structured.price!)}.',
        );
      }
    }
    if (normalizedUserText.contains('калор') ||
        normalizedUserText.contains('kcal')) {
      if (structured.calories != null) {
        return _voiceText(
          ru: 'Калорийность примерно ${structured.calories} ккал.',
          kk: 'Калориясы шамамен ${structured.calories} ккал.',
        );
      }
    }
    final text = _truncateForSpeech(
      _resolveTextReaderScanText(result),
      maxChars: 320,
    );
    if (text.isNotEmpty) {
      return text;
    }
    final structuredOnly = _buildStructuredTextReaderSummary(structured);
    if (structuredOnly.isNotEmpty) {
      return structuredOnly;
    }
    return _textReaderFailureMessage();
  }

  Future<void> _storeTextReaderScan(TextReaderScanResult result) async {
    final db = await _personalizationDatabase.database;
    final rawText = _resolveTextReaderScanText(result);
    await db.insert('ocr_reads', <String, Object?>{
      'read_kind': _textReaderKindForScan(result),
      'raw_text': await _securePayloadCodec.encrypt(rawText),
      'price': result.structuredData.price,
      'calories': result.structuredData.calories,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _personalizationDatabase.pruneOcrReads(maxEntries: 100);
  }

  void _publishTextReaderScanEvent(
    TextReaderScanResult result, {
    required _TextReaderReadSource source,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _perceptionEventBus.publish(
      PerceptionEvent(
        id: 'text_read_$now',
        type: PerceptionEventType.textRead,
        timestampMs: now,
        confidence: result.isStrong ? 0.95 : 0.78,
        label: _textReaderKindForScan(result),
        meta: <String, Object?>{
          'raw_text': result.fullText,
          'blocks': result.orderedLines,
          'auto_speech_text': result.orderedLines.isNotEmpty
              ? result.orderedLines.first
              : '',
          'scan_source': result.source.name,
          'quality': result.quality.name,
          'signature': result.signature,
          'price': result.structuredData.price,
          'calories': result.structuredData.calories,
          'mode': _assistantModeContextKey(_assistantMode),
          'manual_source': source.name,
        },
      ),
    );
  }

  Future<void> _speakTextReaderAnswerText(
    String answer, {
    required bool autoRead,
  }) async {
    _textReaderController.markSpeaking();
    _applyTextReaderState(_textReaderController.state);
    try {
      await _ensureTtsLocaleForSpokenText(answer, autoRead: autoRead);
      await _speak(answer, ensureLocale: false);
    } finally {
      _textReaderController.markIdle();
      _applyTextReaderState(_textReaderController.state);
    }
  }

  Future<void> _handleTextReaderAttemptSuccess({
    required String rawText,
    required _TextReaderReadSource source,
    required TextReaderScanResult result,
  }) async {
    final normalizedUserText = _router.normalize(rawText);
    final autoRead = source == _TextReaderReadSource.auto;
    final wantsStructuredOnly = _isTextReaderStructuredQuery(
      normalizedUserText,
    );
    final answer = _buildTextReaderAnswerFromScan(
      result,
      normalizedUserText: normalizedUserText,
    );
    final segments = wantsStructuredOnly
        ? const <String>[]
        : _buildTextReaderSpeechSegmentsFromScan(result);

    await _storeTextReaderScan(result);
    _publishTextReaderScanEvent(result, source: source);
    if (!autoRead) {
      _rememberDialogTurn(rawText, answer);
    }
    _lastAnswer = answer;
    appLog(
      '[TextReader][result] source=${source.name} '
      'scan=${result.source.name} quality=${result.quality.name} '
      'signature=${result.signature} text="${_truncateForLog(_resolveTextReaderScanText(result))}"',
    );

    if (segments.isNotEmpty) {
      _textReaderController.markSpeaking();
      _applyTextReaderState(_textReaderController.state);
      try {
        await _speakTextReaderSegments(segments, autoRead: autoRead);
      } finally {
        _textReaderController.markIdle();
        _applyTextReaderState(_textReaderController.state);
      }
      return;
    }

    await _speakTextReaderAnswerText(answer, autoRead: autoRead);
  }

  Future<void> _storeOcrRead(OnDeviceTextReadResult result) async {
    final db = await _personalizationDatabase.database;
    await db.insert('ocr_reads', <String, Object?>{
      'read_kind': result.kind,
      'raw_text': await _securePayloadCodec.encrypt(result.rawText),
      'price': result.price,
      'calories': result.calories,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _personalizationDatabase.pruneOcrReads(maxEntries: 100);
  }

  void _publishTextReadEvent(
    OnDeviceTextReadResult result, {
    _TextReaderReadSource? source,
    double? selectedScore,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _perceptionEventBus.publish(
      PerceptionEvent(
        id: 'text_read_$now',
        type: PerceptionEventType.textRead,
        timestampMs: now,
        confidence: result.hasText ? 0.9 : 0.0,
        label: result.kind,
        meta: <String, Object?>{
          'raw_text': result.rawText,
          'blocks': result.blocks,
          'manual_fallback_text': result.manualFallbackText,
          'auto_speech_text': result.blocks.isNotEmpty
              ? result.blocks.first
              : '',
          'dominant_script': result.rawDominantScript.name,
          'looks_pseudo_russian_ocr': result.looksPseudoRussianOcr,
          'price': result.price,
          'calories': result.calories,
          'mode': _assistantModeContextKey(_assistantMode),
          'manual_source': source?.name ?? 'auto',
          'manual_selected_score': selectedScore,
        },
      ),
    );
  }

  String _buildTextReaderAnswer(
    OnDeviceTextReadResult result, {
    required String normalizedUserText,
    required bool autoRead,
  }) {
    final spokenTextSource = autoRead
        ? (result.blocks.isNotEmpty ? result.blocks.first : '')
        : _resolveManualSpeechText(result);
    final spokenText = _truncateForSpeech(spokenTextSource);
    final isLatinManual =
        !autoRead &&
        TextReadingNormalizer.shouldUseEnglishTts(spokenTextSource);
    if (normalizedUserText.contains('цен') ||
        normalizedUserText.contains('price')) {
      if (result.price != null) {
        return _voiceText(
          ru: 'Цена примерно ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}.',
          kk: 'Бағасы шамамен ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}.',
        );
      }
      return _voiceText(
        ru: 'Цена не читается уверенно. Текст: $spokenText',
        kk: 'Баға анық көрінбейді. Мәтін: $spokenText',
      );
    }
    if (normalizedUserText.contains('калор') ||
        normalizedUserText.contains('kcal')) {
      if (result.calories != null) {
        return _voiceText(
          ru: 'Калорийность примерно ${result.calories} ккал.',
          kk: 'Калориясы шамамен ${result.calories} ккал.',
        );
      }
      return _voiceText(
        ru: 'Калории не нашла. Прочитанный текст: $spokenText',
        kk: 'Калория табылмады. Оқылған мәтін: $spokenText',
      );
    }

    final parts = <String>[];
    if (result.price != null) {
      parts.add(
        _voiceText(
          ru: 'Цена ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
          kk: 'Бағасы ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
        ),
      );
    }
    if (result.calories != null) {
      parts.add(
        _voiceText(
          ru: 'Калорийность ${result.calories} ккал',
          kk: 'Калориясы ${result.calories} ккал',
        ),
      );
    }
    final prefix = autoRead
        ? _voiceText(ru: 'Читаю', kk: 'Оқып тұрмын')
        : _voiceText(ru: 'Прочитанный текст', kk: 'Оқылған мәтін');
    final meta = parts.isEmpty ? '' : '${parts.join('. ')}. ';
    if (spokenText.isEmpty) {
      if (meta.isNotEmpty) {
        return meta.trimRight();
      }
      return _voiceText(
        ru: 'Не смогла уверенно прочитать текст.',
        kk: 'Мәтінді сенімді оқи алмадым.',
      );
    }
    if (isLatinManual && meta.isEmpty) {
      return spokenText;
    }
    return '$meta$prefix: $spokenText';
  }

  String _buildStructuredOnlyTextReaderAnswer(
    OnDeviceTextReadResult result, {
    required String normalizedUserText,
  }) {
    if (normalizedUserText.contains('цен') ||
        normalizedUserText.contains('price')) {
      if (result.price != null) {
        return _voiceText(
          ru: 'Цена примерно ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}.',
          kk: 'Бағасы шамамен ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}.',
        );
      }
    }
    if (normalizedUserText.contains('калор') ||
        normalizedUserText.contains('kcal')) {
      if (result.calories != null) {
        return _voiceText(
          ru: 'Калорийность примерно ${result.calories} ккал.',
          kk: 'Калориясы шамамен ${result.calories} ккал.',
        );
      }
    }

    final parts = <String>[];
    if (result.price != null) {
      parts.add(
        _voiceText(
          ru: 'Цена ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
          kk: 'Бағасы ${result.price!.toStringAsFixed(result.price! % 1 == 0 ? 0 : 2)}',
        ),
      );
    }
    if (result.calories != null) {
      parts.add(
        _voiceText(
          ru: 'Калорийность ${result.calories} ккал',
          kk: 'Калориясы ${result.calories} ккал',
        ),
      );
    }
    if (parts.isEmpty) {
      return _textReaderFailureMessage();
    }
    return parts.join('. ');
  }

  void _syncTextReaderLoop() {
    final perception = _currentModeDescriptor().perception;
    final shouldRun =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        perception.enableAutoTextReader &&
        !_voicePriorityWindowActive &&
        !_textReaderAutoPaused &&
        _featureFlags.textReaderEnabled;
    if (!shouldRun) {
      _textReaderLoopTimer?.cancel();
      _textReaderLoopTimer = null;
      _textReaderLoopBusy = false;
      if (!_isSpeaking &&
          !_manualTextReadInProgress &&
          !_textReaderAutoPaused) {
        _textReaderController.markIdle();
        _applyTextReaderState(_textReaderController.state);
      }
      return;
    }
    if (_textReaderLoopTimer != null) return;
    _textReaderLoopTimer = Timer.periodic(
      Duration(milliseconds: _textReaderFrameIntervalMs),
      (_) {
        unawaited(_runAutoTextReaderTick());
      },
    );
    unawaited(_runAutoTextReaderTick());
  }

  Future<void> _runAutoTextReaderTick() async {
    final perception = _currentModeDescriptor().perception;
    if (_textReaderLoopBusy ||
        !perception.enableAutoTextReader ||
        !_featureFlags.textReaderEnabled) {
      return;
    }
    if (_commandInFlight ||
        _followUpActive ||
        _wakeHandling ||
        _isSpeaking ||
        _manualTextReadInProgress ||
        _textReaderAutoPaused ||
        !_cameraGranted ||
        !_cameraStreaming) {
      return;
    }
    _textReaderLoopBusy = true;
    try {
      final attempt = await _textReaderController.runAutoTick();
      _applyTextReaderState(
        attempt.state,
        failureReason: attempt.failureReason,
        updateUi: _assistantMode == AssistantMode.textReader,
      );
      if (!attempt.hasResult) {
        if (_assistantMode == AssistantMode.textReader && !attempt.skipped) {
          appLog(
            '[TextReader][auto] no_result reason=${attempt.failureReason ?? 'none'}',
          );
        }
        return;
      }

      await _handleTextReaderAttemptSuccess(
        rawText: _voiceText(ru: 'авточтение', kk: 'автоматты оқу'),
        source: _TextReaderReadSource.auto,
        result: attempt.result!,
      );
    } finally {
      _textReaderLoopBusy = false;
      if (mounted) {
        _syncWakeFallbackMode(_wakeService.state.value);
      }
    }
  }

  String _truncateForSpeech(String text, {int maxChars = 160}) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxChars) return compact;
    return '${compact.substring(0, maxChars).trimRight()}...';
  }

  bool _looksLikeShoppingListSetup(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    return normalized.contains('список') ||
        normalized.contains('купить') ||
        normalized.contains('shopping') ||
        normalized.contains('шопинг');
  }

  String? _extractPickedShoppingItem(String text) {
    final match = RegExp(
      r'(?:взял|взяла|нашел|нашла|отметь|picked|в корзине)\s+(.+)$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text.trim());
    final value = (match?.group(1) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  bool _asksShoppingStatus(String text) {
    final normalized = _router.normalize(text);
    return normalized.contains('что осталось') ||
        normalized.contains('что купить') ||
        normalized.contains('остат') ||
        normalized.contains('список');
  }

  Future<String> _buildDressCodeAnswer(String userText) async {
    try {
      final hasPermission = await _ensureLocationPermission();
      if (!hasPermission) {
        throw Exception('location_permission_denied');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      );
      final weather = await _openMeteoService.fetchCurrent(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (weather == null) {
        throw Exception('weather_unavailable');
      }
      final weatherText = _voiceIsKazakh
          ? weather.describeKk()
          : weather.describeRu();
      final suggestion = _outfitSuggestion(weather);
      return _voiceText(
        ru: 'Сейчас $weatherText. $suggestion',
        kk: 'Қазір $weatherText. $suggestion',
      );
    } catch (_) {
      return _voiceText(
        ru: 'Не смогла получить погоду. Но если выходите на улицу, выбирайте закрытую обувь и внешний слой.',
        kk: 'Ауа райын ала алмадым. Бірақ сыртта жел болса, жабық аяқ киім мен сыртқы қабат таңдаңыз.',
      );
    }
  }

  String _outfitSuggestion(WeatherSnapshot weather) {
    final temp = weather.temperatureC;
    final windy = weather.windSpeedKmh >= 20;
    if (_voiceIsKazakh) {
      if (temp <= 0) {
        return windy
            ? 'Қалың күрте, жылы бас киім және жабық аяқ киім киіңіз.'
            : 'Жылы күрте мен жабық аяқ киім киіңіз.';
      }
      if (temp <= 10) {
        return windy
            ? 'Куртка не қалың худи және жабық аяқ киім дұрыс.'
            : 'Жеңіл күрте мен жабық аяқ киім дұрыс.';
      }
      if (temp <= 18) {
        return 'Жеңіл сыртқы қабат пен ыңғайлы аяқ киім жеткілікті.';
      }
      return 'Жеңіл киім жарайды, бірақ күн қатты болса бас киім қосыңыз.';
    }
    if (temp <= 0) {
      return windy
          ? 'Нужны теплая куртка, шапка и закрытая обувь.'
          : 'Нужны теплая куртка и закрытая обувь.';
    }
    if (temp <= 10) {
      return windy
          ? 'Подойдет куртка или плотный худи и закрытая обувь.'
          : 'Подойдет легкая куртка и закрытая обувь.';
    }
    if (temp <= 18) {
      return 'Хватит легкого верхнего слоя и удобной обуви.';
    }
    return 'Подойдет легкая одежда, при ярком солнце добавьте головной убор.';
  }

  Future<String?> _captureSceneAnchorSummary(String anchorName) async {
    final jpegBytes = await _captureLatestJpegFrame();
    if (jpegBytes == null || jpegBytes.isEmpty) return null;
    final raw = await _openAi.askWithImage(
      'Опиши устойчивые ориентиры этой сцены для памяти: $anchorName',
      jpegBytes,
      systemPrompt: _buildVisionPrompt(
        extraInstruction: _voiceIsKazakh
            ? 'Memory режимі. Бір сөйлеммен тек тұрақты ориентирлерді сипатта.'
            : 'Режим memory. Одним предложением опиши только устойчивые ориентиры сцены.',
      ),
      history: _dialogHistoryMessages(),
      taskMode: _assistantModeContextKey(_assistantMode),
      perceptionSnapshot: _buildPerceptionSnapshot(),
      maxOutputTokens: 120,
    );
    return _postprocessDialogAnswer(raw);
  }

  String? _extractMemoryAnchorName(String text) {
    final match = RegExp(
      r'(?:запомни|сохрани|помни это как|есте сақта)\s+(.+)$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text.trim());
    final value = (match?.group(1) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  String? _extractMemoryLookupName(String text) {
    final match = RegExp(
      r'(?:что помнишь про|вспомни|покажи память|еске тусір|еске түсір)\s+(.+)$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text.trim());
    final value = (match?.group(1) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  bool _looksLikeSceneMemoryCapture(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    return normalized.contains('это место') ||
        normalized.contains('эту сцену') ||
        normalized.contains('эту комнату') ||
        normalized.contains('осы жер') ||
        normalized.contains('осы бөлме');
  }

  String? _extractFindTarget(String text) {
    final match = RegExp(
      r'(?:найди|отыщи|find)\s+(.+)$',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text.trim());
    final value = (match?.group(1) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  ReflexDetection? _matchFindTargetAgainstDetections(String target) {
    final normalizedTarget = _normalizeDetectorToken(target);
    if (normalizedTarget.isEmpty) return null;
    for (final detection in _latestReflexDetections) {
      final candidates = <String>{
        _normalizeDetectorToken(detection.sourceLabel),
        _normalizeDetectorToken(detection.hazardLabel),
        _normalizeDetectorToken(_reflexDisplayLabel(detection.hazardLabel)),
      };
      if (candidates.any(
        (candidate) =>
            candidate.isNotEmpty &&
            (candidate == normalizedTarget ||
                candidate.contains(normalizedTarget) ||
                normalizedTarget.contains(candidate)),
      )) {
        return detection;
      }
    }
    return null;
  }

  String _normalizeDetectorToken(String value) {
    final normalized = _router.normalize(value).replaceAll(RegExp(r'\s+'), ' ');
    return normalized
        .replaceAll('colour', 'color')
        .replaceAll('велосипед', 'bike')
        .replaceAll('машина', 'car')
        .replaceAll('плита', 'hot surface')
        .replaceAll('острый предмет', 'sharp object')
        .trim();
  }

  String _buildFindDetectionAnswer(String target, ReflexDetection detection) {
    final direction = switch (detection.direction) {
      'left' => _voiceText(ru: 'слева', kk: 'сол жақта'),
      'right' => _voiceText(ru: 'справа', kk: 'оң жақта'),
      _ => _voiceText(ru: 'прямо перед вами', kk: 'тура алда'),
    };
    final action = switch (detection.direction) {
      'left' => _voiceText(
        ru: 'поверните немного влево',
        kk: 'сол жаққа бұрылыңыз',
      ),
      'right' => _voiceText(
        ru: 'поверните немного вправо',
        kk: 'оң жаққа бұрылыңыз',
      ),
      _ => _voiceText(ru: 'сделайте шаг вперед', kk: 'бір қадам алға жылжыңыз'),
    };
    return '$target $direction. $action.';
  }

  Future<void> _repeatLastAnswer() async {
    if (_lastAnswer.trim().isEmpty) {
      await _speak(_voiceL10n.noAnswerToRepeat);
      return;
    }
    await _speak(_lastAnswer);
  }

  String _postprocessVisionAnswer(
    String rawAnswer, {
    required bool allowNumbers,
  }) {
    var text = rawAnswer.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return _visionIncompleteMessage();

    text = text
        .replaceFirst(
          RegExp(
            r'^(на (этой )?(фотографии|картинке|изображении)\s*[,:\-]?\s*)',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trimLeft();
    text = text
        .replaceFirst(
          RegExp(
            r'^(бул (суретте|фотода|бейнеде)\s*[,:\-]?\s*)',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trimLeft();

    if (!allowNumbers) {
      text = _stripUnrequestedNumericDetails(text);
      if (text.isEmpty) return _visionIncompleteMessage();
    }

    if (_isLikelyVisionFragment(text)) {
      return _visionIncompleteMessage();
    }

    if (!RegExp(r'[.!?…]$').hasMatch(text)) {
      text = '$text.';
    }
    return text;
  }

  bool _userRequestedNumericDetails(String userText) {
    final normalized = _router.normalize(userText);
    if (normalized.isEmpty) return false;

    const denyPhrases = <String>[
      'без чисел',
      'без цифр',
      'без градусов',
      'без координат',
      'без процентов',
      'цифры не нужны',
      'числа не нужны',
      'сансыз',
      'пайызсыз',
      'градуссыз',
      'бұрышсыз',
      'координатасыз',
    ];
    for (final phrase in denyPhrases) {
      if (normalized.contains(phrase)) return false;
    }

    const allowPhrases = <String>[
      'с числами',
      'с цифрами',
      'в цифрах',
      'в числах',
      'точные числа',
      'точные цифры',
      'подробно с числами',
      'подробно с цифрами',
      'в градусах',
      'с градусами',
      'градус',
      'угол',
      'углы',
      'координат',
      'азимут',
      'процент',
      'проценты',
      'в процентах',
      'numbers',
      'with numbers',
      'degrees',
      'degree',
      'angles',
      'coordinates',
      'percent',
      'percentages',
      'санмен',
      'сандармен',
      'санмен айт',
      'градуспен',
      'бұрыш',
      'координат',
      'пайыз',
    ];
    for (final phrase in allowPhrases) {
      if (normalized.contains(phrase)) return true;
    }
    return false;
  }

  String _stripUnrequestedNumericDetails(String text) {
    var cleaned = text;
    final patterns = <RegExp>[
      RegExp(
        r'[-+]?\d{1,3}[.,]\d+\s*[,;]\s*[-+]?\d{1,3}[.,]\d+',
        caseSensitive: false,
      ),
      RegExp(r'\b\d+(?:[.,]\d+)?\s*%', caseSensitive: false),
      RegExp(r'\b\d+(?:[.,]\d+)?\s*°', caseSensitive: false),
      RegExp(
        r'\b\d+(?:[.,]\d+)?\s*(?:градус(?:ов|а)?|граду(?:с|са|сов)|deg(?:ree)?s?)\b',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(
        r'\b(?:угол|углы|азимут|координат\w*|процент\w*|градус\w*|degree(?:s)?|angles?|coordinates?|percent(?:ages?)?)\b',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(r'[-+]?\d+(?:[.,]\d+)?', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, ' ');
    }

    cleaned = cleaned.replaceAll(RegExp(r'\(\s*\)'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+([,.;:!?])'), r'$1');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    cleaned = cleaned.replaceAll(RegExp(r'^[,.;:\-\s]+'), '').trimLeft();
    cleaned = cleaned.replaceAll(RegExp(r'[,.;:\-\s]+$'), '').trimRight();
    return cleaned;
  }

  String _truncateForLog(String text, {int maxChars = 220}) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) return normalized;
    return '${normalized.substring(0, maxChars)}...';
  }

  bool _isLikelyVisionFragment(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;

    final lower = trimmed.toLowerCase();
    if (lower.endsWith('...') ||
        lower.endsWith('…') ||
        lower.endsWith(',') ||
        lower.endsWith(':') ||
        lower.endsWith('-')) {
      return true;
    }

    final normalized = _router.normalize(trimmed);
    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length <= 1) {
      return true;
    }

    const stubPhrases = <String>[
      'на этой фотографии',
      'на фотографии',
      'на изображении',
      'это изображение',
      'бул суретте',
      'бул фотода',
      'бул бейнеде',
    ];
    for (final phrase in stubPhrases) {
      final phraseWordCount = phrase.split(' ').length;
      if (normalized == phrase) return true;
      if (normalized.startsWith(phrase) &&
          words.length <= phraseWordCount + 2) {
        return true;
      }
    }

    return false;
  }

  String _visionIncompleteMessage() {
    return _voiceText(
      ru: 'Не удалось полностью описать кадр. Наведите камеру точнее и скажите: "опиши ещё раз".',
      kk: 'Кадр толық оқылмады. Камераны дәлдеп, "қайта сипатта" деп айтыңыз.',
    );
  }

  Future<bool> _waitForFreshFrame({
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final frame = _lastFrame;
      final frameAt = _lastFrameAt;
      if (frame != null && frameAt != null) {
        final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
        if (ageMs <= _maxFrameAgeMs) {
          return true;
        }
      }
      await Future.delayed(const Duration(milliseconds: 80));
    }
    return false;
  }

  Future<bool> _speakLlmCooldownMessageIfNeeded() async {
    final left = _llmRateLimitRemaining();
    if (left == null) return false;
    await _speak(_llmRateLimitMessage(wait: left));
    return true;
  }

  Duration? _llmRateLimitRemaining() {
    final until = _llmRateLimitedUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left.inMilliseconds <= 0) {
      _llmRateLimitedUntil = null;
      return null;
    }
    return left;
  }

  void _applyLlmRateLimit(Duration? retryAfter) {
    final fallback = const Duration(seconds: 35);
    final effective = retryAfter ?? fallback;
    final clamped = Duration(
      seconds: effective.inSeconds.clamp(5, 120),
      milliseconds: 0,
    );
    final candidate = DateTime.now().add(clamped);
    final current = _llmRateLimitedUntil;
    if (current == null || candidate.isAfter(current)) {
      _llmRateLimitedUntil = candidate;
    }
  }

  String _llmRateLimitMessage({Duration? wait}) {
    final left = wait ?? _llmRateLimitRemaining();
    final seconds = left == null ? 35 : left.inSeconds.clamp(1, 120);
    return _voiceText(
      ru: 'Лимит запросов временно превышен. Подождите $seconds секунд и повторите.',
      kk: 'Сұрау лимиті уақытша асып кетті. $seconds секунд күтіп, қайта айтыңыз.',
    );
  }

  _DialogBrevityMode _parseInitialBrevityMode(String raw) {
    final value = raw.trim().toLowerCase();
    switch (value) {
      case 'short':
      case 'brief':
      case 'compact':
      case 'кратко':
      case 'коротко':
      case 'қысқа':
        return _DialogBrevityMode.short;
      case 'detailed':
      case 'long':
      case 'подробно':
      case 'толық':
      case 'толығырақ':
        return _DialogBrevityMode.detailed;
      case 'auto':
      default:
        return _DialogBrevityMode.auto;
    }
  }

  bool _isContextResetCommand(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const triggers = <String>[
      'очисти контекст',
      'сбрось контекст',
      'очистить контекст',
      'контекстті тазала',
      'контекст тазала',
    ];
    for (final trigger in triggers) {
      if (normalized.contains(trigger)) return true;
    }
    return false;
  }

  void _clearDialogHistory() {
    if (_dialogHistory.isEmpty) return;
    _dialogHistory.clear();
    appLog('[Dialog] context cleared');
  }

  void _rememberDialogTurn(String userText, String assistantText) {
    if (_dialogContextTurns <= 0) return;
    final user = userText.trim();
    final assistant = assistantText.trim();
    if (user.isEmpty || assistant.isEmpty) return;
    _dialogHistory.add(_DialogTurn(userText: user, assistantText: assistant));
    final overflow = _dialogHistory.length - _dialogContextTurns;
    if (overflow > 0) {
      _dialogHistory.removeRange(0, overflow);
    }
  }

  List<OpenAiChatMessage> _dialogHistoryMessages() {
    if (_dialogHistory.isEmpty || _dialogContextTurns <= 0) return const [];
    final messages = <OpenAiChatMessage>[];
    for (final turn in _dialogHistory) {
      messages.add(OpenAiChatMessage(role: 'user', content: turn.userText));
      messages.add(
        OpenAiChatMessage(role: 'assistant', content: turn.assistantText),
      );
    }
    return messages;
  }

  int _maxTextOutputTokens() {
    switch (_dialogBrevityMode) {
      case _DialogBrevityMode.short:
        return 120;
      case _DialogBrevityMode.detailed:
        return 420;
      case _DialogBrevityMode.auto:
        return 260;
    }
  }

  int _maxVisionOutputTokens() {
    switch (_dialogBrevityMode) {
      case _DialogBrevityMode.short:
        return 130;
      case _DialogBrevityMode.detailed:
        return 320;
      case _DialogBrevityMode.auto:
        return 220;
    }
  }

  String _postprocessDialogAnswer(String raw) {
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return text;
    text = _sanitizeProjectIdentityAnswer(text);
    if (_dialogBrevityMode == _DialogBrevityMode.short) {
      text = _compressToShortAnswer(text);
    }
    if (text.trim().isEmpty) {
      return _assistantFallbackAnswer();
    }
    return text;
  }

  String _sanitizeProjectIdentityAnswer(String text) {
    final normalized = _router.normalize(text);
    final hasGenericAiIdentity =
        normalized.contains('я языковая модель') ||
        normalized.contains('я ии') ||
        normalized.contains('как ии') ||
        normalized.contains('как языковая модель') ||
        normalized.contains('chatgpt') ||
        normalized.contains('as an ai') ||
        normalized.contains('language model');
    if (!hasGenericAiIdentity) return text;
    return _capabilitiesAnswer();
  }

  String _assistantFallbackAnswer() {
    return _voiceText(
      ru: 'Поняла. Кратко: JANARYM работает голосом, описывает кадр с камеры и ведёт в режиме маршрута.',
      kk: 'Түсіндім. Қысқаша жауап берейін: JANARYM дауыспен жұмыс істейді, камерадан сипаттайды және маршрут режимін жүргізеді.',
    );
  }

  String _compressToShortAnswer(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return compact;

    final sentenceMatches = RegExp(r'[^.!?…]+[.!?…]?').allMatches(compact);
    final sentences = <String>[];
    for (final match in sentenceMatches) {
      final sentence = (match.group(0) ?? '').trim();
      if (sentence.isEmpty) continue;
      sentences.add(sentence);
      if (sentences.length >= 2) break;
    }
    if (sentences.isEmpty) return compact;

    var result = sentences.join(' ').trim();
    result = result.replaceAll(
      RegExp(
        r'^(в целом|вообще|в принципе|ну|итак|короче|по сути)\s*[,:\-]?\s*',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!RegExp(r'[.!?…]$').hasMatch(result)) {
      result = '$result.';
    }
    return result;
  }

  int _lastDirectivePosition(String normalizedText, List<String> phrases) {
    var best = -1;
    for (final phrase in phrases) {
      final idx = normalizedText.lastIndexOf(phrase);
      if (idx > best) {
        best = idx;
      }
    }
    return best;
  }

  _DialogStyleDirectiveResult _applyDialogStyleDirective(String rawText) {
    final source = rawText.trim();
    if (source.isEmpty) {
      return const _DialogStyleDirectiveResult(
        cleanedText: '',
        onlyDirective: false,
      );
    }

    final normalized = _router.normalize(source);
    const shortPhrases = <String>[
      'коротко',
      'кратко',
      'вкратце',
      'по делу',
      'только важное',
      'в двух словах',
      'қысқа',
      'қысқаша',
      'маңызды ғана',
    ];
    const detailedPhrases = <String>[
      'подробно',
      'подробнее',
      'детально',
      'максимально подробно',
      'толық',
      'толығырақ',
    ];
    const autoPhrases = <String>[
      'как обычно',
      'обычно',
      'обычный ответ',
      'обычный режим',
      'қалыпты',
      'әдеттегідей',
    ];

    final shortPos = _lastDirectivePosition(normalized, shortPhrases);
    final detailedPos = _lastDirectivePosition(normalized, detailedPhrases);
    final autoPos = _lastDirectivePosition(normalized, autoPhrases);
    final hasDirective = shortPos >= 0 || detailedPos >= 0 || autoPos >= 0;

    if (hasDirective) {
      final latestPos = [
        shortPos,
        detailedPos,
        autoPos,
      ].reduce((a, b) => a > b ? a : b);
      if (latestPos == shortPos) {
        _dialogBrevityMode = _DialogBrevityMode.short;
      } else if (latestPos == detailedPos) {
        _dialogBrevityMode = _DialogBrevityMode.detailed;
      } else {
        _dialogBrevityMode = _DialogBrevityMode.auto;
      }
    }

    var cleaned = source;
    final stripPatterns = <RegExp>[
      RegExp(
        r'\b(коротко|кратко|вкратце|по делу|только важное|в двух словах|қысқа|қысқаша|маңызды ғана)\b',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(
        r'\b(подробно|подробнее|детально|максимально подробно|толық|толығырақ)\b',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(
        r'\b(как обычно|обычно|обычный ответ|обычный режим|қалыпты|әдеттегідей)\b',
        caseSensitive: false,
        unicode: true,
      ),
      RegExp(
        r'\b(отвечай|ответь|говори|скажи|давай|теперь|пожалуйста|пж)\b',
        caseSensitive: false,
        unicode: true,
      ),
    ];
    for (final pattern in stripPatterns) {
      cleaned = cleaned.replaceAll(pattern, ' ');
    }
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    final remainder = _router
        .normalize(cleaned)
        .replaceAll(
          RegExp(
            r'\b(мне|нужно|надо|можно|просто|и|режим|формат|ответа|ответ)\b',
            caseSensitive: false,
            unicode: true,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final onlyDirective = hasDirective && remainder.isEmpty;

    return _DialogStyleDirectiveResult(
      cleanedText: cleaned,
      onlyDirective: onlyDirective,
    );
  }

  String _dialogStyleConfirmationText() {
    switch (_dialogBrevityMode) {
      case _DialogBrevityMode.short:
        return _voiceText(
          ru: 'Поняла. Теперь отвечаю коротко и только по важному.',
          kk: 'Түсіндім. Енді қысқа, тек маңыздысын айтамын.',
        );
      case _DialogBrevityMode.detailed:
        return _voiceText(
          ru: 'Хорошо, теперь отвечаю подробнее.',
          kk: 'Жақсы, енді толығырақ жауап беремін.',
        );
      case _DialogBrevityMode.auto:
        return _voiceText(
          ru: 'Хорошо, возвращаю обычный формат ответа.',
          kk: 'Жақсы, енді әдеттегі форматта жауап беремін.',
        );
    }
  }

  bool _isCapabilitiesQuestion(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'что ты умеешь',
      'что умеешь',
      'что ты можешь',
      'что можешь',
      'твои возможности',
      'что ты делаешь',
      'не істей аласын',
      'не істей аласың',
      'не істейсің',
      'мүмкіндіктерің',
      'қолыңнан не келеді',
    ];
    for (final cue in cues) {
      if (normalized.contains(cue)) return true;
    }
    return false;
  }

  bool _isIdentityQuestion(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'кто ты',
      'как тебя зовут',
      'кто ты такая',
      'кто ты такой',
      'сен кімсің',
      'атың кім',
      'сенін атың',
      'сенің атың',
    ];
    for (final cue in cues) {
      if (normalized.contains(cue)) return true;
    }
    return false;
  }

  bool _isRouteModeHelpQuestion(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'режим маршрута',
      'режим маршрут',
      'режим навигации',
      'маршрут режимі',
      'навигация режимі',
      'как работает маршрут',
      'как работает режим маршрута',
      'маршрут как работает',
      'қалай жұмыс істейді маршрут',
      'қалай жұмыс істейді навигация',
    ];
    for (final cue in cues) {
      if (normalized.contains(cue)) return true;
    }
    return false;
  }

  bool _wantsDetailedByText(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'подробно',
      'подробнее',
      'детально',
      'толық',
      'толығырақ',
      'егжей',
    ];
    for (final cue in cues) {
      if (normalized.contains(cue)) return true;
    }
    return _dialogBrevityMode == _DialogBrevityMode.detailed;
  }

  String _capabilitiesAnswer() {
    final short = _dialogBrevityMode == _DialogBrevityMode.short;
    final mode = _voiceText(
      ru: 'Сейчас я в режиме: ${_spokenModeDisplayName(_assistantMode)}.',
      kk: 'Қазір ${_spokenModeDisplayName(_assistantMode)} режиміндемін.',
    );
    final enabledModes = _availableModes()
        .map(_spokenModeDisplayName)
        .join(', ');
    if (_voiceIsKazakh) {
      if (short) {
        return '$mode Мен JANARYM ішінде дауыс, камера және режимдік көмек арқылы жұмыс істеймін. Қолжетімді режимдер: $enabledModes.';
      }
      return '$mode Мен JANARYM ішіндегі ассистентпін. Негізгі мүмкіндіктерім: ояту сөзімен диалог, камерадағы көріністі қысқа сипаттау, қауіп туралы автоматты ескерту, маршрутты бастау, үйге апару, нысанды табу, есте сақтау, мәтін оқу, шоппинг, дайындау, дрескод және антимошенничество сценарийлері. Қолжетімді режимдер: $enabledModes.';
    }
    if (short) {
      return '$mode Я ассистент JANARYM: работаю голосом, камерой и режимами задач. Доступные режимы: $enabledModes.';
    }
    return '$mode Я ассистент внутри JANARYM. Могу: работать по wake-слову «Жанарым», кратко описывать сцену с камеры, автоматически предупреждать об опасности, вести маршрут, вести домой по сохраненной точке, искать объект, хранить память, читать текст, помогать в шоппинге, готовке, дрескоде и антимошенничестве. Доступные режимы: $enabledModes.';
  }

  String _identityAnswer() {
    return _voiceText(
      ru: 'Я ассистент JANARYM внутри этого приложения. Помогаю голосом, камерой и режимом маршрута.',
      kk: 'Менің атым JANARYM ассистенті. Мен осы қолданбаның ішінде сізге дауыспен, камерамен және маршрут режимімен көмектесемін.',
    );
  }

  String _routeModeHelpAnswer(bool detailed) {
    final short = !detailed || _dialogBrevityMode == _DialogBrevityMode.short;
    final navState = _navigationController.state.value;
    final routeActive = navState.activeRoute != null;
    if (_voiceIsKazakh) {
      if (short) {
        final stateLine = routeActive
            ? 'Қазір маршрут белсенді.'
            : 'Қазір маршрут белсенді емес.';
        return '$stateLine Маршрут режимінде сіз межені айтасыз, мен маршрут құрамын және жолда келесі бұрылыс пен қашықтықты айтып отырамын.';
      }
      final stateLine = routeActive
          ? 'Қазір маршрут белсенді, қажет болса статусын немесе келесі қадамды сұрай аласыз.'
          : 'Қазір белсенді маршрут жоқ, жаңа меже айта аласыз.';
      return '$stateLine Маршрут режимі былай жұмыс істейді: режимді қосасыз, меже адресін айтасыз, мен маршрут құрамын, кейін жолда келесі әрекетті, қалған қашықтықты және статусын айтып тұрамын. Негізгі командалар: «маршрут до ...», «статус маршрута», «что дальше», «стоп маршрут».';
    }
    if (short) {
      final stateLine = routeActive
          ? 'Сейчас маршрут активен.'
          : 'Сейчас активного маршрута нет.';
      return '$stateLine В режиме маршрута вы называете цель, я строю маршрут и по пути озвучиваю следующий шаг и дистанцию.';
    }
    final stateLine = routeActive
        ? 'Сейчас маршрут активен, можно спрашивать статус и следующий шаг.'
        : 'Сейчас маршрут не активен, можно сразу сказать адрес.';
    return '$stateLine Режим маршрута работает так: вы включаете режим, называете адрес назначения, я строю маршрут и веду голосом по шагам. В любой момент можно спросить статус, следующий шаг или остановить маршрут. Также можно строить маршрут до сохранённых меток (например, дом/работа). Команды: «маршрут до ...», «статус маршрута», «что дальше», «стоп маршрут».';
  }

  String _dialogStylePromptTail() {
    if (_dialogBrevityMode == _DialogBrevityMode.auto) return '';
    if (_voiceIsKazakh) {
      if (_dialogBrevityMode == _DialogBrevityMode.short) {
        return 'Жауап 1-2 қысқа сөйлем болсын, тек маңызды ақпаратты айт.';
      }
      return 'Қажет болса толығырақ, бірақ нақты әрі құрылымды жауап бер.';
    }
    if (_dialogBrevityMode == _DialogBrevityMode.short) {
      return 'Отвечай очень кратко: 1-2 коротких предложения и только главное.';
    }
    return 'Можно отвечать подробнее, но по делу и структурно.';
  }

  String _projectCapabilitiesPrompt({required bool navigationMode}) {
    final enabledModes = _availableModes()
        .map(_spokenModeDisplayName)
        .join(', ');
    final releaseStage = _featureFlags.releaseStage;
    if (_voiceIsKazakh) {
      final modeLine = navigationMode
          ? 'Қазір маршрут режимі қосулы, навигация контекстін ұстан.'
          : 'Қазір жалпы режим қосулы.';
      return 'Сен JANARYM қолданбасының ішіндегі ассистентсің. '
          'Өзіңді ChatGPT немесе тілдік модель ретінде таныстырма. '
          'Пайдаланушы "не істей аласың?" деп сұраса, тек JANARYM мүмкіндіктерін айт: '
          '1) ояту сөзі "Жанарым" арқылы дауыс диалогы, '
          '2) камера кадрын қысқаша сипаттау, '
          '3) маршрут режимін қосу/өшіру, маршрут құру, маршрут күйі мен келесі қадамды айту, '
          '4) үйге және сақталған меткаларға маршрут құру, '
          '5) соңғы жауапты қайталау, '
          '6) қысқа/толық жауап стилін ауыстыру, '
          '7) автоматты қауіп ескертуі камера белсенді кезде әрқашан жұмыс істейді, '
          '8) қосымша режимдер: ordinary/route/home/find/memory/text_reader/shopping/cooking/dress_code/anti_fraud. '
          'Қолданбада жоқ мүмкіндікті ойдан шығарма. '
          'Егер сұраныс қолданба шегінен тыс болса, оны қысқа айт та осы функциялардың жақынын ұсын. '
          'Қолжетімді режимдер: $enabledModes. Релиз кезеңі: $releaseStage. '
          '$modeLine';
    }

    final modeLine = navigationMode
        ? 'Сейчас активен режим маршрута, держи навигационный контекст как приоритет.'
        : 'Сейчас активен обычный режим.';
    return 'Ты ассистент внутри приложения JANARYM. '
        'Никогда не представляйся ChatGPT, ИИ-моделью или универсальным помощником. '
        'Не перечисляй абстрактные возможности модели. '
        'Если пользователь спрашивает "что ты умеешь", отвечай только возможностями JANARYM: '
        '1) голосовой диалог через wake-слово "Жанарым", '
        '2) краткое описание сцены с последнего кадра камеры, '
        '3) режим маршрута: включение/выключение, построение маршрута, статус маршрута, следующий шаг, остановка маршрута, '
        '4) маршрут домой и к сохранённым меткам, '
        '5) повтор последнего ответа, '
        '6) переключение стиля ответа (коротко/подробно/обычно), '
        '7) автоматические предупреждения об опасности, пока камера активна, '
        '8) дополнительные режимы: ordinary/route/home/find/memory/text_reader/shopping/cooking/dress_code/anti_fraud. '
        'Не выдумывай функции, которых нет в приложении. '
        'Если запрос вне возможностей приложения, скажи это коротко и предложи ближайший поддерживаемый сценарий. '
        'Доступные режимы: $enabledModes. Стадия релиза: $releaseStage. '
        '$modeLine';
  }

  String _runtimeProjectStatePrompt({required bool navigationMode}) {
    final navState = _navigationController.state.value;
    final route = navState.activeRoute;
    final routeActive = route != null;
    final navStatus = _navStatusLabel(navState.navStatus);
    final cameraState = _cameraGranted && _cameraStreaming ? 'on' : 'off';
    final micState = _micGranted ? 'on' : 'off';
    final runtimeState = _runtimeServiceRunning ? 'on' : 'off';

    final currentMode = navigationMode
        ? 'navigation'
        : _assistantModeContextKey(_assistantMode);
    if (_voiceIsKazakh) {
      return 'Ағымдағы runtime-контекст: '
          'режим=$currentMode, '
          'навигация-күйі=$navStatus, '
          'белсенді маршрут=${routeActive ? 'иә' : 'жоқ'}, '
          'камера=$cameraState, микрофон=$micState, runtime_service=$runtimeState. '
          'Жауапта осы контекстті ескер.';
    }
    return 'Текущий runtime-контекст: '
        'режим=$currentMode, '
        'навигационный статус=$navStatus, '
        'активный маршрут=${routeActive ? 'да' : 'нет'}, '
        'камера=$cameraState, микрофон=$micState, runtime_service=$runtimeState. '
        'Учитывай это состояние в ответе.';
  }

  String _navStatusLabel(NavigationStatus status) => status.name;

  String _assistantModeContextKey(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(mode).contextKey;
  }

  Map<String, Object?> _buildPerceptionSnapshot() {
    final descriptor = _currentModeDescriptor();
    return <String, Object?>{
      'mode': descriptor.contextKey,
      'mode_sub_state': _modeOrchestrator.value.subState,
      'camera_streaming': _cameraStreaming,
      'frame_age_ms': _lastFrameAt == null
          ? null
          : DateTime.now().difference(_lastFrameAt!).inMilliseconds,
      'hazard_hint': _latestHazardHint.isEmpty ? null : _latestHazardHint,
      'safety_level': _currentReflexSafetyLevel().name,
      'perception_filters': descriptor.perception.toSnapshot(),
    };
  }

  String _sceneSummaryForPrompt() {
    final descriptor = _currentModeDescriptor();
    final frameAgeMs = _lastFrameAt == null
        ? 'unknown'
        : DateTime.now().difference(_lastFrameAt!).inMilliseconds.toString();
    final focus = <String>[
      ...descriptor.perception.hazardLabelsOfInterest,
      ...descriptor.perception.ocrFocus,
    ].join(',');
    final modeState = _modeOrchestrator.value.subState;
    if (_latestHazardHint.isNotEmpty) {
      return 'mode=${descriptor.contextKey}, sub_state=$modeState, '
          'camera=${_cameraStreaming ? 'on' : 'off'}, '
          'frame_age_ms=$frameAgeMs, hazard=$_latestHazardHint, focus=$focus';
    }
    return 'mode=${descriptor.contextKey}, sub_state=$modeState, '
        'camera=${_cameraStreaming ? 'on' : 'off'}, '
        'frame_age_ms=$frameAgeMs, focus=$focus';
  }

  String _activeSafetyContext() {
    final level = _currentReflexSafetyLevel().name;
    if (_latestHazardHint.isEmpty) {
      if (!_featureFlags.safetyEnabled) return 'safety_monitoring_off';
      return 'safety_monitoring_on; level=$level';
    }
    return 'safety_monitoring_on; level=$level; latest_hazard=$_latestHazardHint';
  }

  String _buildBlindPrompt({
    bool navigationMode = false,
    String? extraInstruction,
  }) {
    final descriptor = _currentModeDescriptor();
    final parts = <String>[
      CommandRouter.blindSystemPromptFor(_voiceLanguage),
      _projectCapabilitiesPrompt(navigationMode: navigationMode),
      _runtimeProjectStatePrompt(navigationMode: navigationMode),
      descriptor.prompts.blind(isKazakh: _voiceIsKazakh),
    ];
    final styleTail = _dialogStylePromptTail();
    if (styleTail.isNotEmpty) {
      parts.add(styleTail);
    }
    if (navigationMode) {
      parts.add(
        _voiceText(
          ru: 'Пользователь сейчас в режиме маршрута.',
          kk: 'Пайдаланушы қазір маршрут режимінде.',
        ),
      );
    }
    if (extraInstruction != null && extraInstruction.trim().isNotEmpty) {
      parts.add(extraInstruction.trim());
    }
    return parts.join(' ');
  }

  String _buildVisionPrompt({String? extraInstruction}) {
    final descriptor = _currentModeDescriptor();
    final parts = <String>[
      CommandRouter.visionSystemPromptFor(_voiceLanguage),
      _projectCapabilitiesPrompt(
        navigationMode: _assistantMode == AssistantMode.navigation,
      ),
      _runtimeProjectStatePrompt(
        navigationMode: _assistantMode == AssistantMode.navigation,
      ),
      descriptor.prompts.vision(isKazakh: _voiceIsKazakh),
    ];
    final styleTail = _dialogStylePromptTail();
    if (styleTail.isNotEmpty) {
      parts.add(styleTail);
    }
    if (extraInstruction != null && extraInstruction.trim().isNotEmpty) {
      parts.add(extraInstruction.trim());
    }
    return parts.join(' ');
  }

  bool _looksLikeVisualFreeRequest(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'что видишь',
      'что видно',
      'что передо мной',
      'что рядом',
      'что вокруг',
      'передо мной',
      'вокруг',
      'на экране',
      'на кадре',
      'алдымда',
      'айналамда',
      'не көріп тұрсың',
      'не көріп тұр',
      'какой цвет',
      'какого цвета',
      'цвет предмета',
      'цвет этого',
      'узнай цвет',
      'определи цвет',
      'what color',
      'қандай түс',
      'түсі қандай',
      'түсін айт',
    ];
    return cues.any(normalized.contains);
  }

  bool _looksLikeColorQuestion(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return false;
    const cues = <String>[
      'какой цвет',
      'какого цвета',
      'цвет',
      'what color',
      'қандай түс',
      'түсі қандай',
      'түс',
    ];
    return cues.any(normalized.contains);
  }

  bool _isNegativeResponse(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    final decision = _router.route(t);
    if (decision.isNegative) return true;
    return t.contains('спасибо') ||
        t.contains('не хочу') ||
        t.contains('рахмет') ||
        t.contains('қаламаймын');
  }

  bool _isAffirmativeResponse(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    final decision = _router.route(t);
    if (decision.isAffirmative) return true;
    return false;
  }

  _LabelCorrectionDraft _parseLabelCorrection(
    String text, {
    required String currentLabelName,
  }) {
    final raw = text.trim();
    if (raw.isEmpty) return const _LabelCorrectionDraft();

    final decision = _router.route(raw);
    var labelName = (decision.placeLabelName ?? '').trim();
    var addressText = (decision.freeAddressText ?? '').trim();

    final labelAddressMatch = RegExp(
      r'^(.+?)\s+(адрес|мекенжай|по адресу|как)\s+(.+)$',
      unicode: true,
    ).firstMatch(labelName);
    if (labelAddressMatch != null) {
      labelName = (labelAddressMatch.group(1) ?? '').trim();
      if (addressText.isEmpty) {
        addressText = (labelAddressMatch.group(3) ?? '').trim();
      }
    }

    if (labelName.isEmpty) {
      final fromRaw = RegExp(
        r'^(нет|не так|неправильно|жок|жоқ)?\s*(сохрани(\s+как)?|запомни(\s+как)?|поставь\s+метку|создай\s+метку)?\s*(.+?)\s+(адрес|мекенжай|по адресу|как)\s+(.+)$',
        unicode: true,
      ).firstMatch(_router.normalize(raw));
      if (fromRaw != null) {
        labelName = (fromRaw.group(5) ?? '').trim();
        if (addressText.isEmpty) {
          addressText = (fromRaw.group(7) ?? '').trim();
        }
      }
    }

    if (addressText.isEmpty) {
      final destination = (decision.destinationQuery ?? '').trim();
      if (destination.isNotEmpty &&
          !_isAffirmativeResponse(destination) &&
          !_isNegativeResponse(destination)) {
        addressText = destination;
      }
    }

    if (addressText.isEmpty) {
      final rawMatch = RegExp(
        r'(адрес|мекенжай|по адресу)\s+(.+)$',
        unicode: true,
      ).firstMatch(_router.normalize(raw));
      if (rawMatch != null) {
        addressText = (rawMatch.group(2) ?? '').trim();
      }
    }

    if (addressText.isEmpty &&
        !_isAffirmativeResponse(raw) &&
        !_isNegativeResponse(raw)) {
      final plainAddress = _extractDestinationCandidate(raw);
      if (plainAddress.isNotEmpty &&
          !plainAddress.contains('сохрани') &&
          !plainAddress.contains('метк')) {
        addressText = plainAddress;
      }
    }

    labelName = labelName.replaceFirst(
      RegExp(r'^(нет|не так|неправильно|жок|жоқ)\s+', unicode: true),
      '',
    );
    labelName = labelName.replaceFirst(
      RegExp(
        r'^(сохрани(\s+как)?|запомни(\s+как)?|поставь\s+метку|создай\s+метку|метку|метка|сақта|белгі\s+қой|белгі\s+жаса)\s+',
        unicode: true,
      ),
      '',
    );
    labelName = labelName.trim();

    addressText = _extractDestinationCandidate(addressText);

    final hasAddress = addressText.trim().isNotEmpty;
    if (labelName.isEmpty && hasAddress) {
      labelName = currentLabelName;
    }

    if (labelName.isEmpty && !hasAddress) {
      return const _LabelCorrectionDraft();
    }

    return _LabelCorrectionDraft(
      labelName: labelName.isEmpty ? null : labelName,
      addressText: hasAddress ? addressText : null,
    );
  }

  String _extractDestinationCandidate(String text) {
    final normalized = _router.stripWakeWords(_router.normalize(text)).trim();
    if (normalized.isEmpty) return '';
    if (_isAffirmativeResponse(normalized) || _isNegativeResponse(normalized)) {
      return '';
    }

    final decision = _router.route(normalized);
    var candidate = (decision.destinationQuery ?? '').trim();
    if (candidate.isEmpty) {
      candidate = normalized;
    }

    candidate = candidate.replaceFirst(
      RegExp(
        r'^(это\s+)?(правильн\w*\s+адрес|правильн\w*|адрес)\s+',
        unicode: true,
      ),
      '',
    );
    candidate = candidate.replaceFirst(
      RegExp(
        r'^(б[ұу]л\s+)?(д[ұу]рыс\s+мекенжай|мекенжай|д[ұу]рыс)\s+',
        unicode: true,
      ),
      '',
    );
    candidate = candidate.trim();
    if (candidate.length < 3) return '';
    return candidate;
  }

  Future<void> _startRouteWithConfirmation(
    String rawDestination, {
    String routeSource = 'manual',
    NavigationDestinationKind destinationKindHint =
        NavigationDestinationKind.generic,
  }) async {
    if (!_micGranted) {
      await _navigationController.startRouteWithKind(
        rawDestination,
        source: routeSource,
        destinationKind: destinationKindHint,
      );
      return;
    }

    var destination = _extractDestinationCandidate(rawDestination);
    if (destination.isEmpty) {
      await _speak(_voiceL10n.navSayDestinationAfterRouteWords);
      return;
    }

    if (destinationKindHint == NavigationDestinationKind.transitStop) {
      final stopPrefix = _interactionLanguage == AppLanguage.kk ? 'аялдамасы ' : 'остановка ';
      if (!destination.toLowerCase().contains('остановка') && 
          !destination.toLowerCase().contains('аялдама')) {
        destination = _interactionLanguage == AppLanguage.kk
            ? '\$destination \$stopPrefix'
            : '\$stopPrefix\$destination';
      }
    }

    var effectiveSource = routeSource;
    final confirmAddress =
        !_personalizationReady ||
        _personalizationController.snapshot.profile.confirmAddressBeforeRoute;

    if (_personalizationReady &&
        routeSource == 'manual' &&
        destinationKindHint != NavigationDestinationKind.transitStop) {
      final similar = await _personalizationRepository.findBestSimilarRoute(
        destination,
      );
      if (similar != null) {
        await _speak(
          _voiceL10n.navConfirmAddressQuestion(similar.resolvedAddress),
        );
        _setCircleState(CircleState.listening);
        final similarAnswer = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 8,
          minListenMs: 300,
          silenceHoldMs: 950,
          ampPollMs: 105,
          restartCooldownMs: 150,
          maxNoSpeechMs: 6000,
        );
        if (!mounted) return;
        final normalized = _router.normalize((similarAnswer ?? '').trim());
        if (_isAffirmativeResponse(normalized)) {
          destination = similar.resolvedAddress;
          effectiveSource = 'suggestion';
          if (!confirmAddress) {
            await _navigationController.startRouteWithKind(
              destination,
              source: effectiveSource,
              destinationKind: destinationKindHint,
            );
            return;
          }
        } else if (!_isNegativeResponse(normalized)) {
          final maybeAddress = _extractDestinationCandidate(normalized);
          if (maybeAddress.isNotEmpty) {
            destination = maybeAddress;
          }
        }
      }
    }

    if (!confirmAddress) {
      await _navigationController.startRouteWithKind(
        destination,
        source: effectiveSource,
        destinationKind: destinationKindHint,
      );
      return;
    }

    final wakeHealthy =
        !_useSttWakeEngine &&
        _requireWakeWord &&
        _wakeService.state.value.status != WakeWordStatus.error;

    try {
      if (_requireWakeWord) {
        await _stopPrimaryWake(reason: 'route_confirm');
      }

      while (mounted) {
        await _speak(_voiceL10n.navConfirmAddressQuestion(destination));
        _setCircleState(CircleState.listening);
        final answer = await _sttService.startCommandListening(
          languageHint: _interactionLanguage,
          allowAutoLanguage: false,
          durationSeconds: 9,
          minListenMs: 320,
          silenceHoldMs: 1000,
          ampPollMs: 105,
          restartCooldownMs: 150,
          maxNoSpeechMs: 6000,
        );
        if (!mounted) return;
        final response = (answer ?? '').trim();
        if (response.isEmpty) {
          await _speak(_voiceL10n.didntHearCommandRepeat);
          continue;
        }

        final normalized = _router.normalize(response);
        if (_isAffirmativeResponse(normalized)) {
          await _navigationController.startRouteWithKind(
            destination,
            source: effectiveSource,
            destinationKind: destinationKindHint,
          );
          return;
        }

        if (_isNegativeResponse(normalized)) {
          await _speak(_voiceL10n.navSayCorrectAddressNow);
          _setCircleState(CircleState.listening);
          final corrected = await _sttService.startCommandListening(
            languageHint: _interactionLanguage,
            allowAutoLanguage: false,
            durationSeconds: 10,
            minListenMs: 350,
            silenceHoldMs: 1100,
            ampPollMs: 110,
            restartCooldownMs: 150,
            maxNoSpeechMs: 7000,
          );
          if (!mounted) return;
          final correctedDestination = _extractDestinationCandidate(
            (corrected ?? '').trim(),
          );
          if (correctedDestination.isEmpty) {
            await _speak(_voiceL10n.didntHearCommandRepeat);
            continue;
          }
          destination = correctedDestination;
          effectiveSource = routeSource;
          continue;
        }

        final implicitDestination = _extractDestinationCandidate(response);
        if (implicitDestination.isNotEmpty) {
          destination = implicitDestination;
          effectiveSource = routeSource;
          continue;
        }

        await _speak(_voiceL10n.navAnswerYesOrNoOrAddress);
      }
    } finally {
      if (_useSttWakeEngine) {
        await _syncPrimaryWakeMode();
      } else if (wakeHealthy) {
        await _wakeService.start();
      } else if (!_requireWakeWord &&
          (_alwaysDialogMode ||
              _wakeService.state.value.status == WakeWordStatus.error)) {
        _startWakeFallbackLoop();
      }
    }
  }

  Future<void> _startFollowUpWindow() async {
    if (_followUpActive) {
      _followUpPending = true;
      return;
    }
    if (!_micGranted) return;
    _followUpActive = true;
    _followUpPending = false;
    final localRequestId = _requestId;

    try {
      _wakeWordOnlyMode = false;
      await _stopPrimaryWake(reason: 'follow_up');
      _setCircleState(CircleState.listening);
      appLog('[STT] post-speech listening');
      final text = await _sttService.startCommandListening(
        languageHint: _interactionLanguage,
        allowAutoLanguage: false,
        durationSeconds: 5,
        minListenMs: 260,
        silenceHoldMs: 700,
        ampPollMs: 100,
        restartCooldownMs: 120,
        maxNoSpeechMs: 5000,
      );
      final cleaned = (text ?? '').trim();
      if (localRequestId != _requestId) return;
      if (cleaned.isNotEmpty) {
        if (_isNegativeResponse(cleaned)) {
          await _armWakeWordWaiting();
        } else {
          await _handleUserText(cleaned);
        }
      } else {
        await _armWakeWordWaiting();
      }
    } catch (e) {
      appLog('[STT] post-speech follow-up failed: $e');
      await _armWakeWordWaiting();
    } finally {
      _followUpActive = false;
      if (_followUpPending && mounted) {
        _followUpPending = false;
        unawaited(_startFollowUpWindow());
      } else {
        _restoreWakeStateIfIdle();
      }
    }
  }

  Future<void> _speak(String text, {bool ensureLocale = true}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    appLog('[TTS] speak');
    _setCircleState(CircleState.speaking);
    _isSpeaking = true;
    try {
      if (ensureLocale) {
        await _ensureTtsLocaleForCurrentMode();
      }
      await _tts.stop();
      await _tts.speak(t);
    } finally {
      _isSpeaking = false;
      if (_circleState == CircleState.speaking) {
        _restoreWakeStateIfIdle();
      }
    }
  }

  Future<void> _stopAll() async {
    appLog('[Stop] pressed');
    _textReaderSessionCancelRequested = true;
    _textReaderController.stop();
    _applyTextReaderState(_textReaderController.state, updateUi: false);
    await _sttService.stop();
    await _tts.stop();
    _followUpActive = false;
    await _vibrateEnd();
    if (_micGranted) {
      if (_useSttWakeEngine) {
        await _syncPrimaryWakeMode();
      } else if (_requireWakeWord &&
          _wakeService.state.value.status != WakeWordStatus.error) {
        await _wakeService.start();
      } else if (_alwaysDialogMode) {
        _startWakeFallbackLoop();
      } else if (_wakeService.state.value.status == WakeWordStatus.error) {
        _scheduleWakeRecoveryIfNeeded(_wakeService.state.value);
        _syncWakeFallbackMode(_wakeService.state.value);
      } else {
        await _wakeService.start();
      }
    }
    _restoreWakeStateIfIdle();
  }

  Future<void> _stopTtsOnly() async {
    _textReaderSessionCancelRequested = true;
    if (_textReaderSessionState == _TextReaderSessionState.speaking) {
      _textReaderController.markIdle();
      _applyTextReaderState(_textReaderController.state, updateUi: false);
    }
    await _tts.stop();
  }

  void _triggerFastModeFeedback() {
    _setCircleState(CircleState.end);
    unawaited(_vibrateEnd());
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _restoreWakeStateIfIdle();
    });
  }

  String _formatTimestamp(DateTime? time) {
    if (time == null) return '—';
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _cameraStatusText() {
    if (!_cameraGranted) return _cameraMessage;
    final live = _cameraStreaming ? 'ON' : 'OFF';
    final last = _formatTimestamp(_lastFrameAt);
    final err = _cameraError.isEmpty
        ? ''
        : '\n${_l10n.panelErrorPrefix}: $_cameraError';
    return 'Live: $live\nLast frame: $last$err';
  }

  String _gptStatusLabel(GptStatus status) {
    switch (status) {
      case GptStatus.loading:
        return 'loading';
      case GptStatus.ok:
        return 'ok';
      case GptStatus.error:
        return 'error';
      case GptStatus.idle:
      default:
        return 'idle';
    }
  }

  AssistantMode _fromJanarymMode(JanarymMode mode) {
    switch (mode) {
      case JanarymMode.home:
        return AssistantMode.general;
      case JanarymMode.route:
        return AssistantMode.navigation;
      case JanarymMode.safety:
        return AssistantMode.general;
      case JanarymMode.shopping:
        return AssistantMode.shopping;
      case JanarymMode.cooking:
        return AssistantMode.cooking;
      case JanarymMode.dress_code:
        return AssistantMode.dressCode;
      case JanarymMode.anti_fraud:
        return AssistantMode.antiFraud;
      case JanarymMode.text_reader:
        return AssistantMode.textReader;
      case JanarymMode.memory:
        return AssistantMode.memory;
      case JanarymMode.find:
        return AssistantMode.find;
    }
  }

  ModeDescriptor _modeDescriptorForAssistantMode(AssistantMode mode) {
    return _modeOrchestrator.descriptorFor(_toJanarymMode(mode));
  }

  ModeDescriptor _currentModeDescriptor() {
    return _modeOrchestrator.activeDescriptor;
  }

  bool _modeNeedsLiveCamera(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(mode).perception.requiresLiveCamera;
  }

  bool _isModeEnabled(AssistantMode mode) {
    return _modeOrchestrator.isEnabled(_toJanarymMode(mode));
  }

  JanarymMode _toJanarymMode(AssistantMode mode) {
    switch (mode) {
      case AssistantMode.general:
        return JanarymMode.home;
      case AssistantMode.navigation:
        return JanarymMode.route;
      case AssistantMode.safety:
        return JanarymMode.home;
      case AssistantMode.shopping:
        return JanarymMode.shopping;
      case AssistantMode.cooking:
        return JanarymMode.cooking;
      case AssistantMode.dressCode:
        return JanarymMode.dress_code;
      case AssistantMode.antiFraud:
        return JanarymMode.anti_fraud;
      case AssistantMode.textReader:
        return JanarymMode.text_reader;
      case AssistantMode.memory:
        return JanarymMode.memory;
      case AssistantMode.find:
        return JanarymMode.find;
    }
  }

  List<AssistantMode> _availableModes() {
    return _modeOrchestrator
        .availableModes()
        .map(_fromJanarymMode)
        .toList(growable: false);
  }

  String _modeDisplayName(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(
      mode,
    ).ui.label(isKazakh: widget.appLanguage == AppLanguage.kk);
  }

  String _spokenModeDisplayName(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(
      mode,
    ).ui.label(isKazakh: _voiceIsKazakh);
  }

  AssistantMode? _detectModeSwitchByText(String text) {
    final normalized = _router.normalize(text);
    if (normalized.isEmpty) return null;

    final stripped = _router.stripWakeWords(normalized).trim();
    if (stripped.isEmpty) return null;

    final tokens = stripped
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    bool containsAnyFragment(List<String> fragments) {
      for (final fragment in fragments) {
        if (stripped.contains(fragment)) return true;
      }
      return false;
    }

    bool containsTokenPrefix(List<String> prefixes) {
      for (final token in tokens) {
        for (final prefix in prefixes) {
          if (token.startsWith(prefix)) return true;
        }
      }
      return false;
    }

    bool matchesSwitchIntent() {
      return containsTokenPrefix([
            'включ',
            'переключ',
            'смен',
            'постав',
            'откро',
            'запуст',
            'давай',
            'нуж',
            'хоч',
            'қос',
            'ауыстыр',
            'аш',
            'керек',
            'қалайм',
          ]) ||
          stripped == 'режим' ||
          stripped.startsWith('режим ') ||
          stripped == 'mode' ||
          stripped.startsWith('mode ');
    }

    bool isShortDirectModePhrase() {
      if (tokens.isEmpty || tokens.length > 3) return false;
      if (stripped.endsWith('?')) return false;
      if (containsTokenPrefix([
        'что',
        'как',
        'расскаж',
        'объясн',
        'уме',
        'мож',
        'why',
        'зачем',
      ])) {
        return false;
      }
      if (tokens.any((token) => token == 'не' || token == 'нет')) {
        return false;
      }
      return true;
    }

    bool wantsMode(
      List<String> tokenPrefixes, {
      List<String> fragments = const <String>[],
      bool allowBare = true,
    }) {
      if (!containsTokenPrefix(tokenPrefixes) &&
          !containsAnyFragment(fragments)) {
        return false;
      }
      if (matchesSwitchIntent()) return true;
      return allowBare && isShortDirectModePhrase();
    }

    final modeTokenPrefixes = <AssistantMode, List<String>>{
      AssistantMode.general: ['обычн', 'главн', 'home', 'қалыпты', 'жалпы'],
      AssistantMode.navigation: [
        'маршрут',
        'навигац',
        'route',
        'бағдарлағыш',
        'бағыт',
        'багыт',
        'бағдар',
      ],
      AssistantMode.shopping: [
        'шоп',
        'покупк',
        'shopping',
        'сауда',
        'сатып',
        'алу',
      ],
      AssistantMode.cooking: [
        'готовк',
        'кухн',
        'cooking',
        'дайында',
        'асуй',
        'ас',
      ],
      AssistantMode.dressCode: ['дрес', 'dress', 'киім'],
      AssistantMode.antiFraud: [
        'антимошен',
        'касс',
        'anti',
        'антиалаяқ',
        'алаяқ',
        'алаяқтық',
      ],
      AssistantMode.textReader: ['чтен', 'чтени', 'reader', 'оқу', 'мәтін'],
      AssistantMode.memory: ['памят', 'жад', 'есте', 'сақтау'],
      AssistantMode.find: ['поиск', 'find', 'іздеу', 'табу'],
    };

    final modeFragments = <AssistantMode, List<String>>{
      AssistantMode.general: ['обычный режим', 'главный режим', 'home scan'],
      AssistantMode.navigation: [
        'маршрутизатор',
        'маршрут',
        'навигация',
        'бағыт режимі',
      ],
      AssistantMode.shopping: ['шоппинг', 'покупки', 'shopping', 'сатып алу'],
      AssistantMode.cooking: ['готовка', 'кухня', 'cooking', 'ас дайындау'],
      AssistantMode.dressCode: ['дрескод', 'dress', 'киім режимі'],
      AssistantMode.antiFraud: [
        'антимошен',
        'анти мошен',
        'anti fraud',
        'алаяқтықтан қорғау',
      ],
      AssistantMode.textReader: [
        'чтение текста',
        'режим чтения',
        'включи чтение',
        'чтение',
        'чтения',
        'мәтін оқу',
        'мәтін оқу режимі',
        'оқу режимі',
      ],
      AssistantMode.memory: ['память', 'жад', 'есте сақтау'],
      AssistantMode.find: [
        'режим найти',
        'режим поиска',
        'включи найти',
        'включи поиск',
        'табу режимі',
        'іздеу режимі',
      ],
    };

    for (final entry in modeTokenPrefixes.entries) {
      final allowBare = entry.key != AssistantMode.find;
      if (wantsMode(
        entry.value,
        fragments: modeFragments[entry.key] ?? const <String>[],
        allowBare: allowBare,
      )) {
        appLog('[ModeSwitch] matched "${entry.key.name}" from "$stripped"');
        return entry.key;
      }
    }

    if (matchesSwitchIntent()) {
      appLog('[ModeSwitch] no match for "$stripped"');
    }
    return null;
  }

  List<_ModeMenuEntry> _modeMenuItems() {
    final kk = widget.appLanguage == AppLanguage.kk;
    final items = <_ModeMenuEntry>[
      _ModeMenuEntry(
        mode: AssistantMode.general,
        label: kk ? 'Қалыпты' : 'Обычный',
        icon: Icons.home_rounded,
      ),
      if (_isModeEnabled(AssistantMode.navigation))
        _ModeMenuEntry(
          mode: AssistantMode.navigation,
          label: kk ? 'Бағдарлағыш' : 'Маршрутизатор',
          icon: Icons.alt_route_rounded,
        ),
      if (_isModeEnabled(AssistantMode.navigation))
        _ModeMenuEntry(
          actionId: 'go_home',
          label: kk ? 'Үйге' : 'Домой',
          icon: Icons.house_rounded,
        ),
      if (_isModeEnabled(AssistantMode.find))
        _ModeMenuEntry(
          mode: AssistantMode.find,
          label: kk ? 'Табу' : 'Найти',
          icon: Icons.search_rounded,
        ),
      if (_isModeEnabled(AssistantMode.memory))
        _ModeMenuEntry(
          mode: AssistantMode.memory,
          label: kk ? 'Жад' : 'Память',
          icon: Icons.bookmark_rounded,
        ),
      if (_isModeEnabled(AssistantMode.textReader))
        _ModeMenuEntry(
          mode: AssistantMode.textReader,
          label: kk ? 'Мәтін оқу' : 'Чтение текста',
          icon: Icons.text_snippet_rounded,
        ),
      if (_isModeEnabled(AssistantMode.shopping))
        _ModeMenuEntry(
          mode: AssistantMode.shopping,
          label: kk ? 'Шоппинг' : 'Шоппинг',
          icon: Icons.shopping_bag_rounded,
        ),
      if (_isModeEnabled(AssistantMode.cooking))
        _ModeMenuEntry(
          mode: AssistantMode.cooking,
          label: kk ? 'Дайындау' : 'Готовка',
          icon: Icons.restaurant_menu_rounded,
        ),
      if (_isModeEnabled(AssistantMode.dressCode))
        _ModeMenuEntry(
          mode: AssistantMode.dressCode,
          label: kk ? 'Дресс-код' : 'Дрескод',
          icon: Icons.checkroom_rounded,
        ),
      if (_isModeEnabled(AssistantMode.antiFraud))
        _ModeMenuEntry(
          mode: AssistantMode.antiFraud,
          label: kk ? 'Антиалаяқ' : 'Антимошеничество',
          icon: Icons.shield_rounded,
        ),
      if (!_useSttWakeEngine)
        _ModeMenuEntry(
          actionId: 'voice_enrollment',
          label: kk ? 'Дауыс профилі' : 'Голосовой профиль',
          icon: Icons.record_voice_over_rounded,
        ),
    ];
    return items;
  }

  String _modeSwitchAck(AssistantMode mode) {
    return _voiceText(
      ru: 'Включила режим: ${_spokenModeDisplayName(mode)}.',
      kk: '${_spokenModeDisplayName(mode)} режимі қосылды.',
    );
  }

  String _modeUnavailableMessage(AssistantMode mode) {
    return _voiceText(
      ru: 'Режим ${_spokenModeDisplayName(mode)} сейчас выключен в конфиге.',
      kk: '${_spokenModeDisplayName(mode)} режимі қазір өшірулі.',
    );
  }

  String _circleLabel() {
    switch (_circleState) {
      case CircleState.wake:
        return _l10n.circleLabelWake;
      case CircleState.listening:
        return _l10n.circleLabelListening;
      case CircleState.thinking:
        return _l10n.circleLabelThinking;
      case CircleState.speaking:
        return _l10n.circleLabelSpeaking;
      case CircleState.end:
        return _l10n.circleLabelReady;
      case CircleState.idle:
      default:
        return _l10n.circleLabelReady;
    }
  }

  String _circleStatusText() {
    switch (_circleState) {
      case CircleState.wake:
        return _l10n.circleStatusWake;
      case CircleState.listening:
        return _l10n.circleStatusListening;
      case CircleState.thinking:
        return _l10n.circleStatusThinking;
      case CircleState.speaking:
        return _l10n.circleStatusSpeaking;
      case CircleState.end:
        return _l10n.circleStatusReady;
      case CircleState.idle:
      default:
        return _l10n.circleStatusReady;
    }
  }

  IconData _circleStatusIcon() {
    switch (_circleState) {
      case CircleState.wake:
        return Icons.hearing_rounded;
      case CircleState.listening:
        return Icons.mic_rounded;
      case CircleState.thinking:
        return Icons.psychology_alt_rounded;
      case CircleState.speaking:
        return Icons.record_voice_over_rounded;
      case CircleState.end:
        return Icons.check_circle_rounded;
      case CircleState.idle:
      default:
        return Icons.radio_button_checked_rounded;
    }
  }

  Color _circleStatusColor() {
    switch (_circleState) {
      case CircleState.wake:
        return const Color(0xFF94A3B8);
      case CircleState.listening:
        return const Color(0xFFF59E0B);
      case CircleState.thinking:
        return const Color(0xFF8B5CF6);
      case CircleState.speaking:
        return const Color(0xFF10B981);
      case CircleState.end:
        return const Color(0xFF22C55E);
      case CircleState.idle:
      default:
        return const Color(0xFF94A3B8);
    }
  }

  String _languageBadgeLabel(AppLanguage language) {
    return language == AppLanguage.kk
        ? _l10n.languageShortKk
        : _l10n.languageShortRu;
  }

  Color _modeAccentColor(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(mode).ui.accentColor;
  }

  IconData _modeIcon(AssistantMode mode) {
    return _modeDescriptorForAssistantMode(mode).ui.icon;
  }

  Widget _buildCameraStage() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF020617), Color(0xFF09021A), Color(0xFF140230)],
          ),
        ),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: RepaintBoundary(
          child: AspectRatio(
            aspectRatio: _cameraPreviewAspectRatio(controller),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RotatedBox(
                  quarterTurns: _cameraPreviewQuarterTurns(controller),
                  child: controller.buildPreview(),
                ),
                IgnorePointer(
                  child: RepaintBoundary(
                    child: RotatedBox(
                      quarterTurns: _cameraPreviewQuarterTurns(controller),
                      child: CustomPaint(
                        painter: BBoxPainter(
                          entries: _reflexBBoxes,
                          mirrorHorizontally:
                              controller.description.lensDirection ==
                              CameraLensDirection.front,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_featureFlags.developerDiagnosticsEnabled)
                  Positioned(
                    top: 14,
                    left: 14,
                    child: IgnorePointer(child: _buildDebugMetricsBadge()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _cameraPreviewAspectRatio(CameraController controller) {
    final orientation = _cameraPreviewOrientationName(controller);
    final isLandscape =
        orientation == 'DeviceOrientation.landscapeLeft' ||
        orientation == 'DeviceOrientation.landscapeRight';
    return isLandscape
        ? controller.value.aspectRatio
        : (1 / controller.value.aspectRatio);
  }

  int _cameraPreviewQuarterTurns(CameraController controller) {
    final orientation = _cameraPreviewOrientationName(controller);
    switch (orientation) {
      case 'DeviceOrientation.portraitUp':
        return 0;
      case 'DeviceOrientation.landscapeRight':
        return 1;
      case 'DeviceOrientation.portraitDown':
        return 2;
      case 'DeviceOrientation.landscapeLeft':
        return 3;
      default:
        return 0;
    }
  }

  String _cameraPreviewOrientationName(CameraController controller) {
    final orientation = controller.value.isRecordingVideo
        ? controller.value.recordingOrientation!
        : (controller.value.previewPauseOrientation ??
              controller.value.lockedCaptureOrientation ??
              controller.value.deviceOrientation);
    return orientation.toString();
  }

  Widget _buildDebugMetricsBadge() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCC020617),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('FPS ${_cameraPreviewFps.toString().padLeft(2, '0')}'),
              Text('Reflex ${_reflexInferenceLatencyMs}ms'),
              Text('Dropped $_cameraDroppedFrames'),
              Text('Boxes $_reflexDetectionsCount'),
            ],
          ),
        ),
      ),
    );
  }

  int _cameraImageRotationDegrees() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return 0;
    final sensorOrientation = controller.description.sensorOrientation;
    final deviceRotation = switch (controller.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    if (controller.description.lensDirection == CameraLensDirection.front) {
      return (sensorOrientation + deviceRotation) % 360;
    }
    return (sensorOrientation - deviceRotation + 360) % 360;
  }

  Widget _buildModePickerOverlay() {
    final menuItems = _modeMenuItems();
    return IgnorePointer(
      ignoring: !_modePickerOpen,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        opacity: _modePickerOpen ? 1 : 0,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          offset: _modePickerOpen ? Offset.zero : const Offset(0.06, 0.12),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutBack,
            scale: _modePickerOpen ? 1 : 0.88,
            child: Align(
              alignment: Alignment.bottomRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (int i = 0; i < menuItems.length; i++) ...[
                        AnimatedSlide(
                          duration: Duration(milliseconds: 170 + i * 22),
                          curve: Curves.easeOutCubic,
                          offset: _modePickerOpen
                              ? Offset.zero
                              : const Offset(0.22, 0),
                          child: menuItems[i].isMode
                              ? _buildModeGlassButton(
                                  menuItems[i].mode!,
                                  label: menuItems[i].label,
                                  iconOverride: menuItems[i].icon,
                                )
                              : _buildMenuActionGlassButton(
                                  actionId: menuItems[i].actionId!,
                                  label: menuItems[i].label,
                                  icon: menuItems[i].icon,
                                ),
                        ),
                        if (i != menuItems.length - 1)
                          const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuActionGlassButton({
    required String actionId,
    required String label,
    required IconData icon,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.white.withOpacity(0.10),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () async {
              _modePickerAutoCloseTimer?.cancel();
              if (mounted) {
                setState(() => _modePickerOpen = false);
              }
              await _vibrateEnd();
              switch (actionId) {
                case 'go_home':
                  await _handleGoHomeShortcut(
                    widget.appLanguage == AppLanguage.kk ? 'үйге' : 'домой',
                  );
                  break;
                case 'voice_enrollment':
                  await _openWakeEnrollmentSheet();
                  break;
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeGlassButton(
    AssistantMode mode, {
    String? label,
    IconData? iconOverride,
  }) {
    final active = _assistantMode == mode;
    final displayLabel = label ?? _modeDisplayName(mode);
    final displayIcon = iconOverride ?? _modeIcon(mode);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.white.withOpacity(active ? 0.2 : 0.1),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () async {
              final changed = await _switchAssistantMode(
                mode,
                reason: 'mode_picker',
              );
              if (!mounted) return;
              _modePickerAutoCloseTimer?.cancel();
              setState(() => _modePickerOpen = false);
              if (!changed) return;
              _triggerFastModeFeedback();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: active
                      ? _modeAccentColor(mode).withOpacity(0.9)
                      : Colors.white30,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    displayIcon,
                    size: 18,
                    color: active ? _modeAccentColor(mode) : Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    displayLabel,
                    style: TextStyle(
                      color: active ? Colors.white : Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openWakeEnrollmentSheet() async {
    if (_useSttWakeEngine) {
      await _speak(
        _voiceText(
          ru: 'Профиль голоса недоступен в режиме STT wake.',
          kk: 'STT wake режимінде дауыс профилі қолжетімсіз.',
        ),
      );
      return;
    }
    if (!_micGranted) {
      await _ensureMicPermission();
      if (!_micGranted || !mounted) return;
    }
    if (_wakeService.state.value.status == WakeWordStatus.error) {
      await _wakeService.recover(restartListening: true);
    } else {
      await _wakeService.start();
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(sheetContext).padding.bottom,
          ),
          child: ValueListenableBuilder<WakeWordState>(
            valueListenable: _wakeService.state,
            builder: (context, wake, _) {
              return ValueListenableBuilder<WakeEnrollmentState>(
                valueListenable: _wakeService.enrollmentState,
                builder: (context, enrollment, __) {
                  final isActive =
                      enrollment.isActive ||
                      wake.status == WakeWordStatus.enrolling;
                  final hasProfile = wake.hasOwnerProfile;
                  final total = enrollment.total <= 0 ? 8 : enrollment.total;
                  final current = enrollment.current.clamp(0, total);
                  final progress = total == 0
                      ? 0.0
                      : (current / total).clamp(0, 1).toDouble();
                  final statusText = switch (enrollment.state) {
                    'progress' =>
                      widget.appLanguage == AppLanguage.kk
                          ? 'Үлгі жазылып жатыр: $current/$total'
                          : 'Идет запись образца: $current/$total',
                    'completed' =>
                      widget.appLanguage == AppLanguage.kk
                          ? 'Дауыс профилі сақталды'
                          : 'Голосовой профиль сохранен',
                    'cancelled' =>
                      widget.appLanguage == AppLanguage.kk
                          ? 'Жазу тоқтатылды'
                          : 'Запись остановлена',
                    _ =>
                      hasProfile
                          ? (widget.appLanguage == AppLanguage.kk
                                ? 'Дауыс профилі дайын'
                                : 'Голосовой профиль готов')
                          : (widget.appLanguage == AppLanguage.kk
                                ? 'Дауыс профилі жоқ'
                                : 'Голосовой профиль не записан'),
                  };

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.appLanguage == AppLanguage.kk
                            ? 'Дауыс профилі'
                            : 'Голосовой профиль',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.appLanguage == AppLanguage.kk
                            ? '«Жанарым» сөзін 8 рет бірдей айтыңыз. Тыныш бөлме, 20-30 см қашықтық.'
                            : 'Скажите «Жанарым» 8 раз одинаково. Тихая комната, расстояние 20-30 см.',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isActive
                                ? const Color(0xFFF59E0B)
                                : hasProfile
                                ? const Color(0xFF22C55E)
                                : Colors.white24,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: isActive ? progress : (hasProfile ? 1 : 0),
                              minHeight: 7,
                              color: isActive
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFF22C55E),
                              backgroundColor: Colors.white12,
                            ),
                            if ((wake.lastError ?? '').isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                wake.lastError!,
                                style: const TextStyle(
                                  color: Color(0xFFFCA5A5),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: isActive
                                  ? null
                                  : () async {
                                      await _wakeService.start();
                                      await _wakeService.startEnrollment(
                                        sampleCount: 8,
                                      );
                                    },
                              child: Text(
                                widget.appLanguage == AppLanguage.kk
                                    ? 'Жазуды бастау'
                                    : 'Начать запись',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: isActive
                                  ? () async {
                                      await _wakeService.cancelEnrollment();
                                    }
                                  : null,
                              child: Text(
                                widget.appLanguage == AppLanguage.kk
                                    ? 'Тоқтату'
                                    : 'Остановить',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: hasProfile && !isActive
                                  ? () async {
                                      await _wakeService.clearOwnerProfile();
                                    }
                                  : null,
                              child: Text(
                                widget.appLanguage == AppLanguage.kk
                                    ? 'Профильді өшіру'
                                    : 'Сбросить профиль',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                Navigator.of(sheetContext).pop();
                              },
                              child: Text(
                                widget.appLanguage == AppLanguage.kk
                                    ? 'Жабу'
                                    : 'Закрыть',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  String _modeIndicatorSubStateLabel() {
    return _modeOrchestrator.localizedSubState(
      _modeOrchestrator.value.subState,
      isKazakh: widget.appLanguage == AppLanguage.kk,
    );
  }

  Widget _buildModeIndicatorPill() {
    final state = _modeOrchestrator.value;
    final descriptor = _modeOrchestrator.descriptorFor(state.activeMode);
    final color = descriptor.ui.accentColor;
    final modeLabel = descriptor.ui.label(
      isKazakh: widget.appLanguage == AppLanguage.kk,
    );
    final subState = _modeIndicatorSubStateLabel();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.26),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.75)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withOpacity(0.16),
            blurRadius: 18,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(descriptor.ui.icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            modeLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            subState,
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeToggleButton() {
    return AnimatedBuilder(
      animation: _modeFabPulse,
      builder: (context, _) {
        final scale = _modePickerOpen ? 1.0 : _modeFabPulse.value;
        final glowOpacity = _modePickerOpen ? 0.45 : 0.28;
        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Material(
                color: Colors.black.withOpacity(0.35),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () async {
                    if (!mounted) return;
                    final nextOpen = !_modePickerOpen;
                    _modePickerAutoCloseTimer?.cancel();
                    setState(() => _modePickerOpen = nextOpen);
                    if (nextOpen) {
                      await _vibrateStart();
                    } else {
                      await _vibrateEnd();
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _modePickerOpen
                            ? const Color(0xFF93C5FD)
                            : Colors.white30,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (_modePickerOpen
                                      ? const Color(0xFF60A5FA)
                                      : const Color(0xFF0EA5E9))
                                  .withOpacity(glowOpacity),
                          blurRadius: _modePickerOpen ? 18 : 14,
                          spreadRadius: _modePickerOpen ? 2 : 1,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedRotation(
                          duration: const Duration(milliseconds: 220),
                          turns: _modePickerOpen ? 0.125 : 0,
                          child: Icon(
                            _modePickerOpen
                                ? Icons.close_rounded
                                : Icons.grid_view_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Режимы',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _textReaderActionLabel() {
    if (_textReaderSessionState == _TextReaderSessionState.scanning ||
        _textReaderSessionState == _TextReaderSessionState.speaking ||
        _manualTextReadInProgress) {
      return widget.appLanguage == AppLanguage.kk ? 'Тоқтату' : 'Стоп';
    }
    return widget.appLanguage == AppLanguage.kk ? 'Оқу' : 'Прочитать';
  }

  Widget _buildTextReaderActionButton() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.black.withOpacity(0.32),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () async {
              if (_manualTextReadInProgress ||
                  _textReaderSessionState == _TextReaderSessionState.scanning ||
                  _textReaderSessionState == _TextReaderSessionState.speaking) {
                await _cancelActiveTextReaderSession();
                return;
              }
              await _runManualTextReadSession(
                widget.appLanguage == AppLanguage.kk
                    ? 'мәтінді оқы'
                    : 'прочитай',
                source: _TextReaderReadSource.tap,
              );
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xFF86EFAC).withOpacity(0.8),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withOpacity(0.28),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.menu_book_rounded,
                    color: Colors.white.withOpacity(0.95),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _textReaderActionLabel(),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _describePromptForDirection(String direction) {
    switch (direction) {
      case 'впереди':
        return _l10n.describeDirectionFrontPrompt;
      case 'слева':
        return _l10n.describeDirectionLeftPrompt;
      case 'справа':
        return _l10n.describeDirectionRightPrompt;
      case 'сзади':
        return _l10n.describeDirectionBackPrompt;
      case 'вокруг':
      default:
        return _l10n.describeDirectionAroundPrompt;
    }
  }

  _AssistantOrbTheme _orbThemeForState(CircleState state) {
    switch (state) {
      case CircleState.wake:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFFE0E7FF), Color(0xFFD0D4FF), Color(0xFF94A3B8)],
          glow: Color(0xFF94A3B8),
          inner: Color(0xFF0F172A),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.5,
        );
      case CircleState.listening:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFFFDE68A), Color(0xFFF97316), Color(0xFFEA580C)],
          glow: Color(0xFFFBBF24),
          inner: Color(0xFF2B1B0F),
          accent: Color(0xFFF59E0B),
          pulseFactor: 0.9,
        );
      case CircleState.thinking:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF8B5CF6), Color(0xFF7C3AED), Color(0xFF6D28D9)],
          glow: Color(0xFFAEA0FF),
          inner: Color(0xFF0C0F2C),
          accent: Color(0xFF8B5CF6),
          pulseFactor: 0.75,
        );
      case CircleState.speaking:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF10B981), Color(0xFF059669), Color(0xFF047857)],
          glow: Color(0xFF34D399),
          inner: Color(0xFF042B1C),
          accent: Color(0xFF34D399),
          pulseFactor: 0.7,
        );
      case CircleState.end:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF1E293B), Color(0xFF0F172A), Color(0xFF020617)],
          glow: Color(0xFF64748B),
          inner: Color(0xFF080C16),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.5,
        );
      case CircleState.idle:
      default:
        return const _AssistantOrbTheme(
          gradient: [Color(0xFF1E293B), Color(0xFF0F172A), Color(0xFF020617)],
          glow: Color(0xFF475569),
          inner: Color(0xFF080C16),
          accent: Color(0xFF94A3B8),
          pulseFactor: 0.35,
        );
    }
  }

  Widget _buildWakeDebugOverlay() {
    if (!_wakeDebugOverlayEnabled) {
      return const SizedBox.shrink();
    }
    if (_useSttWakeEngine) {
      final legacyFallbackActive =
          _sttWakeUnavailable && _sttWakeLegacyFallbackEnabled;
      final text =
          'WAKE stt_android\n'
          'LANG $_sttWakeLanguage\n'
          'ARM ${_sttWakeArmed ? 'on' : 'off'}\n'
          'LEGACY fb ${legacyFallbackActive ? 'on' : 'off'}\n'
          'MATCH $_lastSttWakeMatch\n'
          '${_lastSttWakeReason.isEmpty ? 'idle' : _lastSttWakeReason}';
      return IgnorePointer(
        child: Container(
          width: 150,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xB8162033),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _sttWakeArmed
                  ? const Color(0xAA39D98A)
                  : const Color(0x66FFFFFF),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 1.28,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder<WakeWordDebugState>(
      valueListenable: _wakeService.debugState,
      builder: (context, debug, _) {
        final keywordLabel = _wakeService.state.value.keywordLabel.isEmpty
            ? '--'
            : _wakeService.state.value.keywordLabel;
        final recallLabel = _wakeRecallModeRaw == 'balanced' ? 'bal' : 'max';
        final stage2Enabled = debug.stage2VerificationEnabled
            ? 'on'
            : (_wakeStage2VerificationEnabled ? 'on' : 'off');
        final templateEnabled = debug.templateVerificationEnabled
            ? 'on'
            : (_wakeTemplateVerificationEnabled ? 'on' : 'off');
        final speakerEnabled = debug.ownerVerificationEnabled
            ? 'on'
            : (_ownerVerificationEnabled ? 'on' : 'off');
        final ownerLabel = _wakeService.state.value.hasOwnerProfile
            ? (speakerEnabled == 'on'
                  ? 'owner:stored,verify:on'
                  : 'owner:stored,verify:off')
            : (speakerEnabled == 'on'
                  ? 'owner:none,verify:on'
                  : 'owner:none,verify:off');
        final text =
            'KW $keywordLabel\n'
            'REC $recallLabel\n'
            'STG $stage2Enabled\n'
            'TMP $templateEnabled\n'
            'SPK $speakerEnabled\n'
            'RMS ${debug.rmsDb?.toStringAsFixed(1) ?? '--'} dB\n'
            'SNR ${debug.snrDb?.toStringAsFixed(1) ?? '--'} dB\n'
            'VAD ${debug.vadActive ? 'speech' : 'noise'}\n'
            'S1 ${debug.stage1Score?.toStringAsFixed(2) ?? '--'}\n'
            'S2 ${debug.stage2Score?.toStringAsFixed(2) ?? '--'}\n'
            'SPK ${debug.speakerSimilarity?.toStringAsFixed(2) ?? '--'}\n'
            'CD ${debug.cooldownRemainingMs}ms\n'
            '${debug.reason.isEmpty ? 'idle' : debug.reason}\n'
            '$ownerLabel';
        return IgnorePointer(
          child: Container(
            width: 140,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xB8162033),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: debug.accepted
                    ? const Color(0xAA39D98A)
                    : const Color(0x66FFFFFF),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                height: 1.25,
                fontFamily: 'monospace',
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final topPadding = MediaQuery.paddingOf(context).top;
    final statusColor = _circleStatusColor();

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF020617),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () async {
          if (_isSpeaking ||
              _textReaderSessionState == _TextReaderSessionState.speaking) {
            await _stopTtsOnly();
            _textReaderSessionCancelRequested = true;
          }
        },
        child: Stack(
          children: [
            // --- Camera feed ---
            Positioned.fill(child: _buildCameraStage()),

            // --- Top-to-bottom gradient overlay ---
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.35, 0.65, 1.0],
                      colors: [
                        const Color(0xFF020617).withOpacity(0.75),
                        Colors.transparent,
                        Colors.transparent,
                        const Color(0xFF020617).withOpacity(0.90),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // --- Top status bar ---
            Positioned(
              top: topPadding + 12,
              left: 16,
              right: 16,
              child: _buildTopStatusBar(statusColor),
            ),

            // --- Wake debug overlay (dev) ---
            if (_wakeDebugOverlayEnabled)
              Positioned(
                left: 16,
                bottom: bottomPadding + 130,
                child: _buildWakeDebugOverlay(),
              ),

            // --- Text reader action button ---
            if (_assistantMode == AssistantMode.textReader)
              Positioned(
                right: 20,
                bottom: bottomPadding + 130,
                child: _buildTextReaderActionButton(),
              ),

            // --- Main circle button (bottom center) ---
            Positioned(
              bottom: bottomPadding + 24,
              left: 0,
              right: 0,
              child: Center(child: _buildMainCircleButton(statusColor)),
            ),
          ],
        ),
      ),
    );
  }

  /// Immersive glass top bar: shows current mode + live status dot
  Widget _buildTopStatusBar(Color statusColor) {
    final descriptor = _modeOrchestrator.descriptorFor(
      _modeOrchestrator.value.activeMode,
    );
    final accentColor = descriptor.ui.accentColor;
    final modeLabel = descriptor.ui.label(
      isKazakh: widget.appLanguage == AppLanguage.kk,
    );
    final statusLabel = _circleStatusLabel();

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.38),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: accentColor.withOpacity(0.45),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: accentColor.withOpacity(0.12),
                blurRadius: 24,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Row(
            children: [
              // Mode icon + name
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.18),
                  shape: BoxShape.circle,
                  border: Border.all(color: accentColor.withOpacity(0.5)),
                ),
                child: Icon(descriptor.ui.icon, size: 18, color: accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      modeLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        // Pulsing colored dot
                        AnimatedBuilder(
                          animation: _modeFabPulse,
                          builder: (_, __) => Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: statusColor.withOpacity(
                                    0.4 * _modeFabPulse.value,
                                  ),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Mode grid button (top right)
              GestureDetector(
                onTap: () => _openModeBottomSheet(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(
                    Icons.grid_view_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _circleStatusLabel() {
    switch (_circleState) {
      case CircleState.wake:
        return widget.appLanguage == AppLanguage.kk ? 'Тыңдауда' : 'Слушаю...';
      case CircleState.listening:
        return widget.appLanguage == AppLanguage.kk
            ? 'Сөйлеңіз'
            : 'Говорите...';
      case CircleState.thinking:
        return widget.appLanguage == AppLanguage.kk ? 'Ойлануда' : 'Думаю...';
      case CircleState.speaking:
        return widget.appLanguage == AppLanguage.kk
            ? 'Жауап беруде'
            : 'Отвечаю...';
      case CircleState.end:
        return widget.appLanguage == AppLanguage.kk ? 'Дайын' : 'Готово';
      default:
        return widget.appLanguage == AppLanguage.kk ? 'Дайын' : 'Готов';
    }
  }

  /// Large centered animated circle button
  Widget _buildMainCircleButton(Color statusColor) {
    return AnimatedBuilder(
      animation: _modeFabPulse,
      builder: (context, _) {
        final pulseScale = 1.0 + (_modeFabPulse.value - 1.0) * 0.6;
        final isActive =
            _circleState == CircleState.listening ||
            _circleState == CircleState.thinking ||
            _circleState == CircleState.speaking;

        return GestureDetector(
          onTap: () => _openModeBottomSheet(),
          onLongPress: () async {
            // Long press triggers command listening directly
            if (!_commandInFlight && !_wakeHandling) {
              await _handleWakeDetected();
            }
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow ring (animated pulse)
              if (isActive)
                Transform.scale(
                  scale: pulseScale,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: statusColor.withOpacity(
                          0.35 * (2.0 - _modeFabPulse.value),
                        ),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              // Second outer ring
              if (isActive)
                Transform.scale(
                  scale: pulseScale * 1.18,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: statusColor.withOpacity(
                          0.15 * (2.0 - _modeFabPulse.value),
                        ),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              // Main circle
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          statusColor.withOpacity(0.55),
                          statusColor.withOpacity(0.22),
                        ],
                      ),
                      border: Border.all(
                        color: statusColor.withOpacity(0.75),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: statusColor.withOpacity(0.45),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Icon(
                          _circleStatusIcon(),
                          key: ValueKey(_circleState),
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openModeBottomSheet() {
    final menuItems = _modeMenuItems();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.50),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) {
        return _ModePickerSheet(
          menuItems: menuItems,
          currentMode: _assistantMode,
          appLanguage: widget.appLanguage,
          modeDescriptorFor: _modeDescriptorForAssistantMode,
          onModeSelected: (mode) async {
            Navigator.of(sheetCtx).pop();
            final changed = await _switchAssistantMode(
              mode,
              reason: 'mode_picker',
            );
            if (changed && mounted) {
              _triggerFastModeFeedback();
            }
          },
          onActionSelected: (actionId) async {
            Navigator.of(sheetCtx).pop();
            switch (actionId) {
              case 'go_home':
                await _handleGoHomeShortcut(
                  widget.appLanguage == AppLanguage.kk ? 'үйге' : 'домой',
                );
                break;
              case 'voice_enrollment':
                await _openWakeEnrollmentSheet();
                break;
            }
          },
        );
      },
    );
  }

  Widget _buildOnboardingCard() {
    final step = _personalizationController.onboardingStep;
    final total = _personalizationController.totalOnboardingQuestions;
    final progress = total == 0 ? 0.0 : (step / total).clamp(0, 1).toDouble();
    final question = _personalizationController.currentQuestionText(
      widget.appLanguage,
    );
    final title = widget.appLanguage == AppLanguage.kk
        ? 'Жеке баптау: $step/$total'
        : 'Персонализация: $step/$total';
    final subtitle = widget.appLanguage == AppLanguage.kk
        ? 'Жауап беріңіз немесе "кейін" деңіз. Бір сағаттан кейін еске саламын.'
        : 'Ответьте голосом или скажите "позже". Я напомню через час.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937).withOpacity(0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFB923C).withOpacity(0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            color: const Color(0xFFF59E0B),
            backgroundColor: Colors.white12,
          ),
          const SizedBox(height: 8),
          Text(
            question.isEmpty ? subtitle : question,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          if (question.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton(
                onPressed: () {
                  unawaited(_startOnboardingFlow());
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFEA580C),
                ),
                child: Text(
                  widget.appLanguage == AppLanguage.kk
                      ? 'Жалғастыру'
                      : 'Продолжить',
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  unawaited(
                    _deferOnboarding(
                      defaultOnboardingReminderRequest(),
                      speakAck: false,
                    ),
                  );
                },
                child: Text(
                  widget.appLanguage == AppLanguage.kk ? 'Кейін' : 'Позже',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openPersonalizationSettings() async {
    if (!_personalizationReady) return;
    final snapshot = _personalizationController.snapshot;
    final nameController = TextEditingController(
      text: snapshot.profile.displayName,
    );
    var responseLength = snapshot.profile.responseLength;
    var toneStyle = snapshot.profile.toneStyle;
    var warningIntensity = snapshot.profile.warningIntensity.toDouble();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final labels = _personalizationController.snapshot.placeLabels;
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 14,
                bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.appLanguage == AppLanguage.kk
                          ? 'Жеке баптаулар'
                          : 'Персонализация',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: widget.appLanguage == AppLanguage.kk
                            ? 'Сізге қалай жүгінейін'
                            : 'Как к вам обращаться',
                        labelStyle: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ResponseLength>(
                      value: responseLength,
                      decoration: InputDecoration(
                        labelText: widget.appLanguage == AppLanguage.kk
                            ? 'Жауап ұзақтығы'
                            : 'Длина ответа',
                        labelStyle: const TextStyle(color: Colors.white70),
                      ),
                      dropdownColor: const Color(0xFF1E293B),
                      items: ResponseLength.values
                          .map(
                            (item) => DropdownMenuItem<ResponseLength>(
                              value: item,
                              child: Text(
                                _responseLengthLabel(item),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) return;
                        setSheetState(() {
                          responseLength = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ToneStyle>(
                      value: toneStyle,
                      decoration: InputDecoration(
                        labelText: widget.appLanguage == AppLanguage.kk
                            ? 'Қарым-қатынас тоны'
                            : 'Тон общения',
                        labelStyle: const TextStyle(color: Colors.white70),
                      ),
                      dropdownColor: const Color(0xFF1E293B),
                      items: ToneStyle.values
                          .map(
                            (item) => DropdownMenuItem<ToneStyle>(
                              value: item,
                              child: Text(
                                _toneStyleLabel(item),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) return;
                        setSheetState(() {
                          toneStyle = value;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.appLanguage == AppLanguage.kk
                          ? 'Ескерту жиілігі: ${warningIntensity.round()}'
                          : 'Интенсивность предупреждений: ${warningIntensity.round()}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Slider(
                      value: warningIntensity,
                      min: 1,
                      max: 3,
                      divisions: 2,
                      onChanged: (value) {
                        setSheetState(() {
                          warningIntensity = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    if (labels.isNotEmpty) ...[
                      Text(
                        widget.appLanguage == AppLanguage.kk
                            ? 'Сақталған меткалар'
                            : 'Сохраненные метки',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final label in labels.take(5))
                        Text(
                          '• ${label.labelName}: ${label.addressText}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () async {
                              final now = DateTime.now().millisecondsSinceEpoch;
                              final updated = snapshot.profile.copyWith(
                                displayName: nameController.text.trim(),
                                responseLength: responseLength,
                                toneStyle: toneStyle,
                                warningIntensity: warningIntensity.round(),
                                updatedAtEpochMs: now,
                              );
                              await _personalizationRepository.upsertProfile(
                                updated,
                              );
                              await _personalizationController.refresh();
                              if (!sheetContext.mounted) return;
                              Navigator.of(sheetContext).pop();
                              await _speak(
                                widget.appLanguage == AppLanguage.kk
                                    ? 'Баптаулар сақталды.'
                                    : 'Настройки сохранены.',
                              );
                            },
                            child: Text(
                              widget.appLanguage == AppLanguage.kk
                                  ? 'Сақтау'
                                  : 'Сохранить',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              if (!sheetContext.mounted) return;
                              Navigator.of(sheetContext).pop();
                              await _startOnboardingFlow();
                            },
                            child: Text(
                              widget.appLanguage == AppLanguage.kk
                                  ? 'Опрос қайта'
                                  : 'Пройти опрос',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    nameController.dispose();
  }

  String _responseLengthLabel(ResponseLength value) {
    switch (value) {
      case ResponseLength.short:
        return widget.appLanguage == AppLanguage.kk ? 'Қысқа' : 'Коротко';
      case ResponseLength.medium:
        return widget.appLanguage == AppLanguage.kk ? 'Орташа' : 'Средне';
      case ResponseLength.detailed:
        return widget.appLanguage == AppLanguage.kk ? 'Толық' : 'Подробно';
    }
  }

  String _toneStyleLabel(ToneStyle value) {
    switch (value) {
      case ToneStyle.neutral:
        return widget.appLanguage == AppLanguage.kk
            ? 'Бейтарап'
            : 'Нейтральный';
      case ToneStyle.warm:
        return widget.appLanguage == AppLanguage.kk ? 'Жылы' : 'Теплый';
      case ToneStyle.direct:
        return widget.appLanguage == AppLanguage.kk ? 'Тік' : 'Прямой';
    }
  }

  Widget _buildNavigationPanel(NavigationModeState navState) {
    final route = navState.activeRoute;
    final status = _navigationStatusLabel(navState.navStatus);
    final currentLocation = navState.currentLocation;

    return Column(
      children: [
        if (_embeddedMapEnabled) ...[
          SizedBox(
            height: 220,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: YandexMap(
                onMapCreated: (controller) {
                  _yandexMapController = controller;
                  final focusPoint =
                      currentLocation ?? route?.destination.point;
                  if (focusPoint != null) {
                    unawaited(
                      controller.moveCamera(
                        CameraUpdate.newCameraPosition(
                          CameraPosition(
                            target: _toYandexPoint(focusPoint),
                            zoom: 15.8,
                          ),
                        ),
                      ),
                    );
                  }
                },
                mapObjects: _buildNavigationMapObjects(navState),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ] else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              _l10n.embeddedMapDisabled,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            '${_l10n.panelStatusPrefix}: $status'
            '${route == null ? '' : '\n${_l10n.panelTargetPrefix}: ${route.destination.displayLabel}'}'
            '${navState.lastInstruction == null ? '' : '\n${navState.lastInstruction}'}'
            '${navState.error == null ? '' : '\n${_l10n.panelErrorPrefix}: ${navState.error}'}',
            style: const TextStyle(fontSize: 13, color: Colors.white),
          ),
        ),
      ],
    );
  }

  List<MapObject> _buildNavigationMapObjects(NavigationModeState navState) {
    final mapObjects = <MapObject>[];
    final route = navState.activeRoute;

    if (route != null && route.polyline.length >= 2) {
      mapObjects.add(
        PolylineMapObject(
          mapId: const MapObjectId('nav_route_polyline'),
          polyline: Polyline(
            points: route.polyline.map(_toYandexPoint).toList(growable: false),
          ),
          strokeColor: const Color(0xFF22D3EE),
          strokeWidth: 5,
          outlineWidth: 2,
          outlineColor: Colors.black.withOpacity(0.45),
        ),
      );
      mapObjects.add(
        PlacemarkMapObject(
          mapId: const MapObjectId('nav_destination'),
          point: _toYandexPoint(route.destination.point),
          text: PlacemarkText(
            text: _l10n.markerFinish,
            style: const PlacemarkTextStyle(
              size: 14,
              color: Colors.white,
              outlineColor: Colors.black,
            ),
          ),
          opacity: 1,
        ),
      );
    }

    if (navState.currentLocation != null) {
      mapObjects.add(
        PlacemarkMapObject(
          mapId: const MapObjectId('nav_current_location'),
          point: _toYandexPoint(navState.currentLocation!),
          text: PlacemarkText(
            text: _l10n.markerYou,
            style: const PlacemarkTextStyle(
              size: 14,
              color: Color(0xFF67E8F9),
              outlineColor: Colors.black,
            ),
          ),
          opacity: 1,
        ),
      );
    }

    return mapObjects;
  }

  Point _toYandexPoint(NavPoint point) {
    return Point(latitude: point.latitude, longitude: point.longitude);
  }

  String _navigationStatusLabel(NavigationStatus status) {
    switch (status) {
      case NavigationStatus.idle:
        return _l10n.navStatusIdle;
      case NavigationStatus.resolvingDestination:
        return _l10n.navStatusResolvingDestination;
      case NavigationStatus.awaitingChoice:
        return _l10n.navStatusAwaitingChoice;
      case NavigationStatus.buildingRoute:
        return _l10n.navStatusBuildingRoute;
      case NavigationStatus.navigating:
        return _l10n.navStatusNavigating;
      case NavigationStatus.rerouting:
        return _l10n.navStatusRerouting;
      case NavigationStatus.completed:
        return _l10n.navStatusCompleted;
      case NavigationStatus.error:
        return _l10n.navStatusError;
    }
  }
}

enum _InfoTone { ok, warning }

class _InfoCard extends StatelessWidget {
  final String title;
  final String text;
  final _InfoTone tone;

  const _InfoCard({
    required this.title,
    required this.text,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final color = tone == _InfoTone.ok
        ? Colors.greenAccent.withOpacity(0.2)
        : Colors.orangeAccent.withOpacity(0.2);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(text),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onPressed;
  final bool enabled;
  final String semanticLabel;

  const _BigButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    required this.enabled,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: SizedBox(
        height: 56,
        child: FilledButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: Icon(icon),
          label: Text(text, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }
}

class _AssistantOrbTheme {
  final List<Color> gradient;
  final Color glow;
  final Color inner;
  final Color accent;
  final double pulseFactor;

  const _AssistantOrbTheme({
    required this.gradient,
    required this.glow,
    required this.inner,
    required this.accent,
    required this.pulseFactor,
  });
}

class _AssistantOrb extends StatelessWidget {
  final CircleState state;
  final String label;
  final _AssistantOrbTheme theme;

  const _AssistantOrb({
    required this.state,
    required this.label,
    required this.theme,
  });

  IconData _iconForState() {
    switch (state) {
      case CircleState.wake:
        return Icons.hearing_rounded;
      case CircleState.listening:
        return Icons.mic_rounded;
      case CircleState.thinking:
        return Icons.psychology_alt_rounded;
      case CircleState.speaking:
        return Icons.record_voice_over_rounded;
      case CircleState.end:
        return Icons.check_circle_rounded;
      case CircleState.idle:
      default:
        return Icons.radio_button_checked_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      height: 210,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 210,
            height: 210,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: theme.gradient,
                center: const Alignment(-0.3, -0.4),
                radius: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.glow.withOpacity(0.5),
                  blurRadius: 45,
                  spreadRadius: 10,
                ),
              ],
            ),
          ),
          Container(
            width: 164,
            height: 164,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.inner,
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_iconForState(), size: 44, color: theme.accent),
                  const SizedBox(height: 10),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (state == CircleState.listening)
            Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.accent.withOpacity(0.8),
                  width: 3,
                ),
              ),
            ),
          if (state == CircleState.speaking)
            Container(
              width: 188,
              height: 188,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.accent.withOpacity(0.55),
                  width: 2.4,
                ),
              ),
            ),
          if (state == CircleState.thinking)
            SizedBox(
              width: 140,
              height: 140,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                valueColor: AlwaysStoppedAnimation<Color>(theme.accent),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModePickerSheet extends StatelessWidget {
  const _ModePickerSheet({
    required this.menuItems,
    required this.currentMode,
    required this.appLanguage,
    required this.modeDescriptorFor,
    required this.onModeSelected,
    required this.onActionSelected,
  });

  final List<_ModeMenuEntry> menuItems;
  final AssistantMode currentMode;
  final AppLanguage appLanguage;
  final ModeDescriptor Function(AssistantMode) modeDescriptorFor;
  final ValueChanged<AssistantMode> onModeSelected;
  final ValueChanged<String> onActionSelected;

  @override
  Widget build(BuildContext context) {
    final isKazakh = appLanguage == AppLanguage.kk;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 40,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ...menuItems.map((item) {
                final isSelected = item.isMode && item.mode == currentMode;
                final subtitle = (item.isMode && item.mode != null)
                    ? modeDescriptorFor(
                        item.mode!,
                      ).ui.shortLabel(isKazakh: isKazakh)
                    : null;

                return ListTile(
                  leading: Icon(
                    item.icon,
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(
                    item.label,
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  subtitle: subtitle != null ? Text(subtitle) : null,
                  onTap: () {
                    if (item.isMode && item.mode != null) {
                      onModeSelected(item.mode!);
                    } else if (item.actionId != null) {
                      onActionSelected(item.actionId!);
                    }
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
