import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:yandex_mapkit/yandex_mapkit.dart';

import 'l10n/app_locale_controller.dart';
import 'l10n/app_localizations.dart';
import 'logic/command_router.dart';
import 'navigation/navigation_mode_controller.dart';
import 'navigation/models/navigation_mode_state.dart';
import 'openai_client.dart';
import 'personalization/data/personalization_database.dart';
import 'personalization/models/personalization_models.dart';
import 'personalization/personalization_controller.dart';
import 'personalization/personalization_repository.dart';
import 'voice/command_stt_service.dart';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
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

enum AssistantMode { general, navigation }

enum _OnboardingTurnResult { advanced, retry, paused, completed }

enum _DialogBrevityMode { auto, short, detailed }

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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _sfxPlayer = AudioPlayer();
  final CommandRouter _router = CommandRouter();
  final OpenAiClient _openAi = OpenAiClient();
  final PersonalizationDatabase _personalizationDatabase =
      PersonalizationDatabase();
  late final PersonalizationRepository _personalizationRepository;
  late final PersonalizationController _personalizationController;
  late AppLocalizations _l10n;
  late final NavigationModeController _navigationController;
  late final CommandSttService _sttService;
  late final WakeWordService _wakeService;
  YandexMapController? _yandexMapController;

  DateTime? _lastWakeAt;
  bool _micGranted = false;
  String _micMessage = '';
  CameraController? _cameraController;
  bool _cameraGranted = false;
  bool _cameraStreaming = false;
  bool _cameraInitInProgress = false;
  bool _cameraStartInProgress = false;
  String _cameraMessage = '';
  String _cameraError = '';
  List<CameraDescription>? _cachedCameras;
  DateTime? _lastFrameAt;
  _YuvFrame? _lastFrame;
  int _lastFrameMs = 0;
  GptStatus _gptStatus = GptStatus.idle;
  String _gptError = '';
  String _lastAnswer = '';

  bool _commandInFlight = false;
  String _lastLoggedFinal = '';
  String _lastLoggedWakeSignature = '';
  bool _personalizationReady = false;
  bool _showOnboardingOverlay = true;
  bool _onboardingDialogInProgress = false;
  static const int _maxFrameAgeMs = 8000;
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
  CircleState _circleState = CircleState.idle;
  Timer? _cameraKeepAliveTimer;
  bool _wakeFallbackActive = false;
  bool _wakeFallbackLoopRunning = false;
  bool _wakeFallbackStopRequested = false;
  bool _wakeWordOnlyMode = false;
  AssistantMode _assistantMode = AssistantMode.general;
  _DialogBrevityMode _dialogBrevityMode = _DialogBrevityMode.auto;
  final List<_DialogTurn> _dialogHistory = <_DialogTurn>[];
  NavPoint? _lastNavCameraTarget;
  final bool _alwaysDialogMode = _readEnvBool(
    'ALWAYS_DIALOG_MODE',
    fallback: true,
  );
  final bool _requireWakeWord = _readEnvBool(
    'ASSISTANT_REQUIRE_WAKE_WORD',
    fallback: true,
  );
  final bool _wakeReplyEnabled = _readEnvBool(
    'ASSISTANT_WAKE_REPLY_ENABLED',
    fallback: true,
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
  final String _wakeReplyTextRu = _readEnvString(
    'ASSISTANT_WAKE_REPLY_TEXT_RU',
  );
  final String _wakeReplyTextKk = _readEnvString(
    'ASSISTANT_WAKE_REPLY_TEXT_KK',
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
  static const Duration _wakeFallbackIdleWait = Duration(milliseconds: 520);
  static const Duration _wakeFallbackAfterListenWait = Duration(
    milliseconds: 520,
  );
  static const Duration _wakeFallbackNoSpeechWait = Duration(
    milliseconds: 1200,
  );

  @override
  void initState() {
    super.initState();
    _l10n = lookupAppLocalizations(widget.appLanguage.locale);
    WidgetsBinding.instance.addObserver(this);
    _circleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _circlePulse = Tween<double>(begin: 0.95, end: 1.15).animate(
      CurvedAnimation(parent: _circleController, curve: Curves.easeInOutQuad),
    );
    _personalizationRepository = PersonalizationRepository(
      database: _personalizationDatabase,
    );
    _personalizationController = PersonalizationController(
      repository: _personalizationRepository,
    );
    _navigationController = NavigationModeController(
      speak: _speak,
      log: debugPrint,
      language: widget.appLanguage,
      instructionAdapter: _adaptNavigationInstruction,
      onRouteBuilt: _handleRouteBuilt,
    );
    _sttService = CommandSttService(language: widget.appLanguage);
    _wakeService = WakeWordService(onWakeWordDetected: _handleWakeDetected);
    _openAi.setLanguage(widget.appLanguage);
    _dialogBrevityMode = _parseInitialBrevityMode(_dialogBrevityDefaultRaw);
    _micMessage = _l10n.checkingMic;
    _cameraMessage = _l10n.checkingCamera;
    _navigationController.state.addListener(_handleNavigationStateChange);
    _sttService.state.addListener(_handleSttStateChange);
    _wakeService.state.addListener(_handleWakeStateChange);
    _personalizationController.addListener(_handlePersonalizationChange);
    _initTts();
    _initVibration();
    _initMicAndWake();
    _startCameraKeepAlive();
    unawaited(_initCameraLive());
    unawaited(_initPersonalization());
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
      _openAi.setLanguage(widget.appLanguage);
      _sttService.setLanguage(widget.appLanguage);
      _navigationController.setLanguage(widget.appLanguage);
      unawaited(_configureTtsForLanguage(widget.appLanguage));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWakeFallbackLoop();
    _navigationController.state.removeListener(_handleNavigationStateChange);
    _sttService.state.removeListener(_handleSttStateChange);
    _wakeService.state.removeListener(_handleWakeStateChange);
    _personalizationController.removeListener(_handlePersonalizationChange);
    unawaited(_navigationController.dispose());
    unawaited(_personalizationRepository.close());
    _personalizationController.dispose();
    _sttService.dispose();
    _wakeService.dispose();
    _openAi.dispose();
    _cameraKeepAliveTimer?.cancel();
    _cameraKeepAliveTimer = null;
    _disposeCamera();
    _sfxPlayer.dispose();
    _tts.stop();
    _circleController.dispose();
    super.dispose();
  }

  Future<void> _initTts() async {
    await _configureTtsForLanguage(widget.appLanguage);
    await _tts.setSpeechRate(_ttsSpeechRate);
    await _tts.setPitch(_ttsPitch);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _configureTtsForLanguage(AppLanguage language) async {
    await _applyTtsLanguage(language);
    await _applyPreferredVoice(language);
  }

  Future<void> _applyTtsLanguage(AppLanguage language) async {
    const fallback = 'ru-RU';
    final preferred = language == AppLanguage.kk ? 'kk-KZ' : 'ru-RU';
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
      final hasPreferred =
          available.isEmpty ||
          available.any(
            (value) =>
                value == preferredLower || value.startsWith(preferredLower),
          );
      await _tts.setLanguage(hasPreferred ? preferred : fallback);
    } catch (_) {
      try {
        await _tts.setLanguage(fallback);
      } catch (_) {}
    }
  }

  Future<void> _applyPreferredVoice(AppLanguage language) async {
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

      final selected = _selectBestVoice(voices, language);
      if (selected == null) return;
      await _tts.setVoice(selected);
      debugPrint(
        '[TTS] voice selected: ${selected['name']} (${selected['locale']})',
      );
    } catch (_) {}
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
      if (name.contains('neural') || name.contains('natural')) score += 35;
      if (name.contains('premium') || name.contains('enhanced')) score += 20;

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

  Future<void> _playStartCue() async {
    if (!_audioCuesEnabled) return;
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/start.wav'), volume: 0.7);
    } catch (_) {}
  }

  Future<void> _playWakeCue() async {
    if (!_wakeCueEnabled) return;
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/start.wav'), volume: 0.85);
    } catch (_) {}
  }

  Future<void> _playEndCue() async {
    if (!_audioCuesEnabled) return;
    try {
      await _sfxPlayer.stop();
      await _sfxPlayer.play(AssetSource('sounds/end.wav'), volume: 0.7);
    } catch (_) {}
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
    _setCircleState(CircleState.wake);
  }

  Future<void> _initMicAndWake() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;

    if (status.isGranted) {
      setState(() {
        _micGranted = true;
        _micMessage = _l10n.micAvailable;
      });
      if (_alwaysDialogMode) {
        await _wakeService.stop();
        _startWakeFallbackLoop();
      } else {
        _setCircleState(CircleState.wake);
        await _wakeService.start();
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
    if (_cameraInitInProgress) return;
    _cameraInitInProgress = true;
    try {
      var status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await Permission.camera.request();
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
          debugPrint('[Camera] stream already running (reason=$reason)');
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
            debugPrint(
              '[Camera] stream started on existing controller (reason=$reason)',
            );
            return;
          } catch (e) {
            debugPrint(
              '[Camera] existing controller start failed; recreating '
              '(reason=$reason): $e',
            );
          }
        } else {
          debugPrint(
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
      createdController = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
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
      debugPrint('[Camera] stream started on new controller (reason=$reason)');
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
      debugPrint('[Camera] stream start failed (reason=$reason): $e');
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
      debugPrint('[Camera] stream stopped (reason=$reason)');
    } catch (e) {
      debugPrint('[Camera] stream stop error (reason=$reason): $e');
    }
    if (mounted) {
      setState(() {
        _cameraStreaming = false;
        _cameraMessage = _l10n.cameraLiveOff;
      });
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    _cameraStreaming = false;
    _cameraStartInProgress = false;
    _lastFrame = null;
    _lastFrameAt = null;
    _lastFrameMs = 0;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  void _startCameraKeepAlive() {
    _cameraKeepAliveTimer?.cancel();
    _cameraKeepAliveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      if (_assistantMode != AssistantMode.general) return;
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

    // ── Existing vision/LLM frame capture (400ms throttle) ────────────
    if (now - _lastFrameMs < 400) return;
    _lastFrameMs = now;

    final yPlane = Uint8List.fromList(image.planes[0].bytes);
    final uPlane = Uint8List.fromList(image.planes[1].bytes);
    final vPlane = Uint8List.fromList(image.planes[2].bytes);

    _lastFrame = _YuvFrame(
      width: image.width,
      height: image.height,
      y: yPlane,
      u: uPlane,
      v: vPlane,
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes[1].bytesPerRow,
      uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
    );
    _lastFrameAt = DateTime.now();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if ((_alwaysDialogMode ||
              _wakeService.state.value.status == WakeWordStatus.error) &&
          _micGranted) {
        _startWakeFallbackLoop();
      }
      unawaited(_initCameraLive());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_stopCameraStream(reason: 'lifecycle_${state.name}'));
      _stopWakeFallbackLoop();
    } else if (state == AppLifecycleState.inactive) {
      _stopWakeFallbackLoop();
    }
  }

  void _handleSttStateChange() {
    final current = _sttService.state.value;
    if (current.finalWords.isNotEmpty &&
        current.finalWords != _lastLoggedFinal) {
      _lastLoggedFinal = current.finalWords;
      debugPrint('[STT] final: ${current.finalWords}');
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _handleWakeStateChange() {
    final wake = _wakeService.state.value;
    final signature =
        '${wake.status}|${wake.keywordMode}|${wake.keywordLabel}|${wake.lastError ?? ''}';
    if (signature != _lastLoggedWakeSignature) {
      _lastLoggedWakeSignature = signature;
      debugPrint(
        '[Wake] state=${wake.status.name} mode=${wake.keywordMode} '
        'keywords=${wake.keywordLabel} error=${wake.lastError ?? '-'}',
      );
    }
    _syncWakeFallbackMode(wake);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initPersonalization() async {
    try {
      await _personalizationController.init();
      if (!mounted) return;
      setState(() {
        _personalizationReady = true;
      });
      if (_personalizationController.onboardingRequired) {
        await _personalizationController.startOrResumeOnboarding();
        _maybeStartOnboardingDialog();
      }
    } catch (e) {
      debugPrint('[Personalization] init error: $e');
    }
  }

  void _handlePersonalizationChange() {
    if (!mounted) return;
    setState(() {});
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
      debugPrint('[Personalization] route record error: $e');
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
      if (widget.appLanguage == AppLanguage.kk) {
        return 'Абай болыңыз, $firstFear қа байланысты: $text';
      }
      return 'Внимание, учитываю ваш риск "$firstFear": $text';
    }
    if (widget.appLanguage == AppLanguage.kk) {
      return 'Ескерту: $text';
    }
    return 'Предупреждение: $text';
  }

  void _handleNavigationStateChange() {
    final navState = _navigationController.state.value;
    if (_assistantMode == AssistantMode.navigation && !navState.modeEnabled) {
      _assistantMode = AssistantMode.general;
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
    if (_wakeFallbackActive || !_micGranted || _wakeWordOnlyMode) return;
    _wakeFallbackActive = true;
    _wakeFallbackStopRequested = false;
    _setCircleState(CircleState.wake);
    debugPrint('[WakeFallback] start');
    unawaited(_runWakeFallbackLoop());
  }

  void _stopWakeFallbackLoop() {
    if (!_wakeFallbackActive && !_wakeFallbackLoopRunning) return;
    _wakeFallbackActive = false;
    _wakeFallbackStopRequested = true;
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
            _sttService.isListening) {
          await Future.delayed(_wakeFallbackIdleWait);
          continue;
        }
        _setCircleState(CircleState.wake);

        final text = await _sttService.startCommandListening(
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
            debugPrint('[Dialog] wake phrase during speaking: $heard');
            await _handleWakeDetected();
          } else if (!_requireWakeWord &&
              _shouldProcessSpeechInterruption(heard)) {
            debugPrint('[Dialog] nav interruption: $heard');
            await _handleDirectFallbackCommand(heard);
          }
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (_containsWakeWordCandidate(heard)) {
          debugPrint('[Dialog] wake phrase: $heard');
          await _handleWakeDetected();
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (!_requireWakeWord &&
            _alwaysDialogMode &&
            _isDirectFallbackCommand(heard)) {
          debugPrint('[Dialog] direct command: $heard');
          await _handleDirectFallbackCommand(heard);
        }

        await Future.delayed(_wakeFallbackAfterListenWait);
      }
    } finally {
      _wakeFallbackLoopRunning = false;
      if (_wakeFallbackStopRequested) {
        debugPrint('[WakeFallback] stop');
      }
    }
  }

  bool _containsWakeWordCandidate(String text) {
    final normalized = _router.normalize(text).replaceAll('-', ' ');
    final compact = normalized.replaceAll(' ', '');
    for (final wake in CommandRouter.wakeWordVariants) {
      final wakeNormalized = _router.normalize(wake).replaceAll('-', ' ');
      final wakeCompact = wakeNormalized.replaceAll(' ', '');
      if (wakeNormalized.isNotEmpty && normalized.contains(wakeNormalized)) {
        return true;
      }
      if (wakeCompact.isNotEmpty && compact.contains(wakeCompact)) {
        return true;
      }
    }
    return false;
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
    if (CommandRouter.exitNavModeTriggers.any(normalized.contains))
      return false;
    if (CommandRouter.navStopTriggers.any(normalized.contains)) return false;
    if (CommandRouter.navStatusTriggers.any(normalized.contains)) return false;
    if (CommandRouter.navNextStepTriggers.any(normalized.contains))
      return false;
    if (CommandRouter.navRejectChoiceTriggers.any(normalized.contains))
      return false;
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
        CommandRouter.repeatTriggers.any(normalized.contains);
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
      await _playStartCue();
      await _vibrateStart();
      _setCircleState(CircleState.listening);
      await _handleUserText(text);
    } catch (e) {
      debugPrint('[WakeFallback] direct command failed: $e');
      await _speak(_l10n.commandProcessingFailed);
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
    _setCircleState(CircleState.listening);
    try {
      _wakeWordOnlyMode = false;
      debugPrint('[Wake] detected');
      setState(() => _lastWakeAt = DateTime.now());
      _requestId++;
      await _tts.stop();
      unawaited(_playWakeCue());
      unawaited(_vibrateStart());
      final wakeReply = _resolvedWakeReplyText();
      if (wakeReply.isNotEmpty) {
        await _speakWakeReply(wakeReply);
      }
      if (_followUpActive) {
        await _sttService.stop();
        _followUpActive = false;
      }
      _commandInFlight = false;
      await _runCommandFlow(reason: 'wake');
    } finally {
      _wakeHandling = false;
      _restoreWakeStateIfIdle();
    }
  }

  String _resolvedWakeReplyText() {
    if (!_wakeReplyEnabled) return '';
    if (widget.appLanguage == AppLanguage.kk) {
      if (_wakeReplyTextKk.trim().isNotEmpty) return _wakeReplyTextKk.trim();
      return _l10n.wakeReplyListening;
    }
    if (_wakeReplyTextRu.trim().isNotEmpty) return _wakeReplyTextRu.trim();
    return _l10n.wakeReplyListening;
  }

  Future<void> _speakWakeReply(String text) async {
    final line = text.trim();
    if (line.isEmpty) return;
    _setCircleState(CircleState.listening);
    _isSpeaking = true;
    try {
      await _tts.stop();
      await _tts.speak(line);
    } finally {
      _isSpeaking = false;
      _setCircleState(CircleState.listening);
    }
  }

  Future<void> _armWakeWordWaiting() async {
    if (!_micGranted) return;
    if (_alwaysDialogMode) {
      _wakeWordOnlyMode = false;
      _startWakeFallbackLoop();
      _setCircleState(CircleState.wake);
      return;
    }
    _wakeWordOnlyMode = true;
    _stopWakeFallbackLoop();
    _setCircleState(CircleState.wake);
    if (_wakeService.state.value.status != WakeWordStatus.error) {
      await _wakeService.start();
    } else {
      _wakeWordOnlyMode = false;
      _startWakeFallbackLoop();
    }
  }

  Future<void> _runCommandFlow({required String reason}) async {
    if (_commandInFlight) return;
    if (!_micGranted) return;

    _commandInFlight = true;
    final localRequestId = _requestId;
    final wakeHealthy =
        (_wakeWordOnlyMode || !_alwaysDialogMode) &&
        _wakeService.state.value.status != WakeWordStatus.error;
    try {
      if (wakeHealthy) {
        await _wakeService.stop();
      }
      debugPrint('[STT] start ($reason)');
      _setCircleState(CircleState.listening);

      final navMode = _assistantMode == AssistantMode.navigation;
      final text = await _sttService.startCommandListening(
        durationSeconds: navMode ? 10 : 7,
        minListenMs: navMode ? 1100 : 420,
        silenceHoldMs: navMode ? 1700 : 820,
        ampPollMs: navMode ? 120 : 100,
        restartCooldownMs: navMode ? 300 : 200,
      );

      // Restart wake-word immediately after STT to allow barge-in
      if (wakeHealthy) {
        await _wakeService.start();
      }

      if (localRequestId != _requestId) return;
      final cleaned = (text ?? '').trim();
      final normalized = _router.normalize(cleaned);
      final strippedWake = _router.stripWakeWords(normalized);
      final wakeOnlyPhrase =
          cleaned.isNotEmpty &&
          _containsWakeWordCandidate(cleaned) &&
          strippedWake.isEmpty;

      if (wakeOnlyPhrase) {
        debugPrint('[STT] ignore wake-only phrase after activation: $cleaned');
        await _playEndCue();
        await _vibrateEnd();
        _setCircleState(CircleState.wake);
      } else if (cleaned.isNotEmpty) {
        await _handleUserText(cleaned);
      } else {
        await _playEndCue();
        await _vibrateEnd();
        _setCircleState(CircleState.wake);
      }
    } finally {
      _commandInFlight = false;
      _restoreWakeStateIfIdle();
    }
  }

  Future<void> _handleUserText(String text) async {
    final directive = _applyDialogStyleDirective(text);
    final userText = directive.cleanedText.isEmpty
        ? text.trim()
        : directive.cleanedText;
    if (directive.onlyDirective) {
      await _speak(_dialogStyleConfirmationText());
      return;
    }
    if (_isContextResetCommand(userText)) {
      _clearDialogHistory();
      await _speak(_l10n.dialogContextCleared);
      return;
    }

    final decision = _router.route(userText);
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

    if (_assistantMode == AssistantMode.general) {
      await _handleGeneralModeCommand(userText, decision);
      return;
    }

    await _handleNavigationModeCommand(userText, decision);
  }

  Future<void> _startOnboardingFlow() async {
    if (!_personalizationReady) return;
    if (!_showOnboardingOverlay) {
      setState(() {
        _showOnboardingOverlay = true;
      });
    }
    await _personalizationController.startOrResumeOnboarding();
    _maybeStartOnboardingDialog();
  }

  Future<void> _restartOnboardingFlow() async {
    if (!_personalizationReady) return;
    setState(() {
      _showOnboardingOverlay = true;
    });
    await _personalizationController.restartOnboardingFromScratch();
    await _speakOnboardingLine(
      widget.appLanguage == AppLanguage.kk
          ? 'Жақсы, опрос қайта басталды.'
          : 'Хорошо, начинаем опрос заново.',
    );
    _maybeStartOnboardingDialog();
  }

  Future<_OnboardingTurnResult> _handleOnboardingInput(
    String rawText,
    CommandDecision decision, {
    bool promptNextQuestion = true,
  }) async {
    final normalized = _router.normalize(rawText);
    final pauseRequested =
        normalized.contains('позже') ||
        normalized.contains('потом') ||
        normalized.contains('кейін');
    if (pauseRequested) {
      _personalizationController.pauseOnboarding();
      setState(() {
        _showOnboardingOverlay = false;
      });
      await _speakOnboardingLine(
        widget.appLanguage == AppLanguage.kk
            ? 'Жақсы, кейін жалғастырамыз.'
            : 'Хорошо, продолжим позже.',
      );
      return _OnboardingTurnResult.paused;
    }

    final answer = decision.cleanedText.trim().isEmpty
        ? rawText.trim()
        : decision.cleanedText.trim();
    if (answer.isEmpty) {
      await _speakOnboardingLine(_l10n.didntHearCommandRepeat);
      return _OnboardingTurnResult.retry;
    }

    await _personalizationController.answerOnboardingQuestion(answer);
    if (!_personalizationController.onboardingRequired) {
      setState(() {
        _showOnboardingOverlay = false;
      });
      await _speakOnboardingLine(
        widget.appLanguage == AppLanguage.kk
            ? 'Персонализация аяқталды. Енді дайынмын.'
            : 'Персонализация завершена. Я готова к работе.',
      );
      return _OnboardingTurnResult.completed;
    }
    if (promptNextQuestion) {
      final nextQuestion = _personalizationController.currentQuestionText(
        widget.appLanguage,
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
    await _wakeService.stop();
    try {
      while (mounted &&
          _showOnboardingOverlay &&
          _personalizationController.onboardingRequired &&
          _personalizationController.onboardingActive) {
        final question = _personalizationController.currentQuestionText(
          widget.appLanguage,
        );
        if (question.isEmpty) break;
        await _speakOnboardingLine(question);
        if (!mounted) return;

        _setCircleState(CircleState.listening);
        final heard = await _sttService.startCommandListening(
          durationSeconds: 8,
          minListenMs: 240,
          silenceHoldMs: 720,
          ampPollMs: 95,
          restartCooldownMs: 120,
          maxNoSpeechMs: 4500,
        );
        if (!mounted) return;

        final rawText = (heard ?? '').trim();
        final decision = _router.route(rawText);
        if (decision.modeIntent == AssistantModeIntent.restartOnboarding) {
          await _personalizationController.restartOnboardingFromScratch();
          await _speakOnboardingLine(
            widget.appLanguage == AppLanguage.kk
                ? 'Жақсы, опрос қайта басталды.'
                : 'Хорошо, начинаем опрос заново.',
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
        if (_alwaysDialogMode ||
            _wakeService.state.value.status == WakeWordStatus.error) {
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
        widget.appLanguage == AppLanguage.kk
            ? 'Неден қорқатыныңызды айтыңыз.'
            : 'Скажите, чего вы боитесь, и я запомню.',
      );
      return;
    }
    await _personalizationController.updateFromDirectUserFact(fearText);
    await _speak(
      widget.appLanguage == AppLanguage.kk
          ? 'Жақсы, сақтап қойдым.'
          : 'Поняла, запомнила это как важный риск.',
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
        widget.appLanguage == AppLanguage.kk
            ? 'Қандай атаумен сақтау керек? Мысалы: үй.'
            : 'Скажите название метки. Например: дом.',
      );
      return;
    }

    while (mounted) {
      if (addressText.isEmpty) {
        await _speak(
          widget.appLanguage == AppLanguage.kk
              ? '"$labelName" меткасы үшін мекенжайды айтыңыз.'
              : 'Продиктуйте адрес для метки "$labelName".',
        );
        _setCircleState(CircleState.listening);
        final answer = await _sttService.startCommandListening(
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
          await _speak(_l10n.didntHearCommandRepeat);
          continue;
        }
      }

      final candidate = await _navigationController.resolveDestinationCandidate(
        addressText,
      );
      if (candidate == null) {
        await _speak(
          widget.appLanguage == AppLanguage.kk
              ? 'Бұл мекенжайды таба алмадым. Қалай дұрыс сақтау керегін айтыңыз.'
              : 'Не смогла найти этот адрес. Скажите, как сохранить правильно.',
        );
        _setCircleState(CircleState.listening);
        final corrected = await _sttService.startCommandListening(
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
          await _speak(_l10n.didntHearCommandRepeat);
          continue;
        }
        labelName = (correction.labelName ?? labelName).trim();
        addressText = (correction.addressText ?? '').trim();
        continue;
      }

      await _speak(
        widget.appLanguage == AppLanguage.kk
            ? '"$labelName" меткасын "${candidate.displayLabel}" мекенжайымен сақтайын ба?'
            : 'Сохранить метку "$labelName" с адресом "${candidate.displayLabel}"?',
      );
      _setCircleState(CircleState.listening);
      final confirmAnswer = await _sttService.startCommandListening(
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
        await _speak(_l10n.didntHearCommandRepeat);
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
          widget.appLanguage == AppLanguage.kk
              ? '"$labelName" меткасы сақталды.'
              : 'Сохранила метку "$labelName".',
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
          widget.appLanguage == AppLanguage.kk
              ? 'Дұрысын айтыңыз. Мысалы: "сақта үй мекенжайы Абай 10".'
              : 'Скажите как правильно. Например: "сохрани как дом адрес Абая 10".',
        );
        _setCircleState(CircleState.listening);
        final corrected = await _sttService.startCommandListening(
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
          widget.appLanguage == AppLanguage.kk
              ? 'Иә деп растаңыз немесе дұрыс атау мен мекенжайды айтыңыз.'
              : 'Скажите "да" для подтверждения или продиктуйте правильные метку и адрес.',
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
        widget.appLanguage == AppLanguage.kk
            ? 'Қай меткаға маршрут құру керек?'
            : 'К какой метке построить маршрут?',
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
        debugPrint('[Personalization] place label lookup error: $e');
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
      case AssistantModeIntent.routeToPlaceLabel:
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
        await _speak(_l10n.enableRouteModeFirst);
        return;
      case AssistantModeIntent.repeat:
        await _repeatLastAnswer();
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
          await _speak(_l10n.didntHearCommandRepeat);
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
        await _speak(_l10n.didntHearCommandRepeat);
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
      case AssistantModeIntent.routeToPlaceLabel:
        var destination = decision.destinationQuery?.trim() ?? '';
        if (destination.isEmpty) {
          destination = (decision.placeLabelName ?? '').trim();
        }
        if (destination.isEmpty) {
          await _speak(_l10n.sayAddressAfterRoutePhrase);
          return;
        }
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
        await _startRouteWithConfirmation(destination, routeSource: 'manual');
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
      case AssistantModeIntent.repeat:
      case AssistantModeIntent.visionDescribe:
        await _speak(_l10n.routeModeDescribeBlocked);
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
        await _speak(_l10n.navAnswerYesOrNoOrAddress);
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

  Future<void> _enterNavigationMode() async {
    if (_assistantMode == AssistantMode.navigation) {
      await _speak(_l10n.routeModeAlreadyEnabled);
      return;
    }
    await _tts.stop();
    await _navigationController.enterMode();
    if (!_navigationController.state.value.modeEnabled) {
      return;
    }
    _lastNavCameraTarget = null;
    await _disposeCamera();
    _assistantMode = AssistantMode.navigation;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _exitNavigationMode() async {
    if (_assistantMode == AssistantMode.general) {
      await _speak(_l10n.routeModeNotEnabled);
      return;
    }
    await _tts.stop();
    await _navigationController.exitMode();
    _lastNavCameraTarget = null;
    _assistantMode = AssistantMode.general;
    unawaited(_initCameraLive());
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _askGpt(String text, {String? systemPrompt}) async {
    if (await _speakLlmCooldownMessageIfNeeded()) return;
    setState(() {
      _gptStatus = GptStatus.loading;
      _gptError = '';
    });
    debugPrint('[GPT] start');
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
      debugPrint('[GPT] ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_l10n.followUpNeedAnythingElse);
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
      debugPrint('[GPT] rate limit: ${e.message}');
      await _speak(_llmRateLimitMessage());
    } catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] error: $e');
      await _speak(_l10n.commandProcessingFailed);
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
    debugPrint('[GPT] vision start');
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
        maxOutputTokens: _maxVisionOutputTokens(),
      );
      debugPrint('[GPT] vision raw: ${_truncateForLog(rawAnswer)}');
      var answer = _postprocessVisionAnswer(
        rawAnswer,
        allowNumbers: allowNumbers,
      );
      answer = _postprocessDialogAnswer(answer);
      debugPrint(
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
      debugPrint('[GPT] vision ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_l10n.followUpNeedAnythingElse);
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
      debugPrint('[GPT] vision rate limit: ${e.message}');
      await _speak(_llmRateLimitMessage());
    } catch (e) {
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] vision error: $e');
      await _speak(_l10n.commandProcessingFailed);
    }
    _thinkingSoundPlayed = false;
  }

  Future<void> _describeWithVision(String text, {String? systemPrompt}) async {
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) {
        await _speak(_l10n.noCameraAccess);
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
        await _speak(_l10n.fastFrameUnavailable);
        return;
      }
    }

    final frameAt = _lastFrameAt;
    if (frameAt == null) {
      await _speak(_l10n.frameUnavailable);
      return;
    }

    final ageMs = DateTime.now().difference(frameAt).inMilliseconds;
    if (ageMs > _maxFrameAgeMs &&
        !await _waitForFreshFrame(timeout: const Duration(milliseconds: 500))) {
      await _speak(_l10n.staleFrameUnavailable);
      return;
    }

    debugPrint('[VISION] send last frame to GPT');
    final frame = _lastFrame!;
    final jpegBytes = await compute(_convertYuvToJpeg, frame.toMap());
    await _askGptWithImage(
      text,
      jpegBytes,
      systemPrompt: systemPrompt ?? _buildVisionPrompt(),
    );
  }

  Future<void> _repeatLastAnswer() async {
    if (_lastAnswer.trim().isEmpty) {
      await _speak(_l10n.noAnswerToRepeat);
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
    if (widget.appLanguage == AppLanguage.kk) {
      return 'Кадр толық оқылмады. Камераны дәлдеп, "қайта сипатта" деп айтыңыз.';
    }
    return 'Не удалось полностью описать кадр. Наведите камеру точнее и скажите: "опиши ещё раз".';
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
    if (widget.appLanguage == AppLanguage.kk) {
      return 'Сұрау лимиті уақытша асып кетті. $seconds секунд күтіп, қайта айтыңыз.';
    }
    return 'Лимит запросов временно превышен. Подождите $seconds секунд и повторите.';
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
    debugPrint('[Dialog] context cleared');
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
    if (widget.appLanguage == AppLanguage.kk) {
      return 'Түсіндім. Қысқаша жауап берейін: JANARYM дауыспен жұмыс істейді, камерадан сипаттайды және маршрут режимін жүргізеді.';
    }
    return 'Поняла. Кратко: JANARYM работает голосом, описывает кадр с камеры и ведёт в режиме маршрута.';
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
    if (widget.appLanguage == AppLanguage.kk) {
      switch (_dialogBrevityMode) {
        case _DialogBrevityMode.short:
          return 'Түсіндім. Енді қысқа, тек маңыздысын айтамын.';
        case _DialogBrevityMode.detailed:
          return 'Жақсы, енді толығырақ жауап беремін.';
        case _DialogBrevityMode.auto:
          return 'Жақсы, енді әдеттегі форматта жауап беремін.';
      }
    }

    switch (_dialogBrevityMode) {
      case _DialogBrevityMode.short:
        return 'Поняла. Теперь отвечаю коротко и только по важному.';
      case _DialogBrevityMode.detailed:
        return 'Хорошо, теперь отвечаю подробнее.';
      case _DialogBrevityMode.auto:
        return 'Хорошо, возвращаю обычный формат ответа.';
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
    final mode = _assistantMode == AssistantMode.navigation
        ? (widget.appLanguage == AppLanguage.kk
              ? 'Қазір маршрут режиміндемін.'
              : 'Сейчас я в режиме маршрута.')
        : (widget.appLanguage == AppLanguage.kk
              ? 'Қазір жалпы режимдемін.'
              : 'Сейчас я в обычном режиме.');
    if (widget.appLanguage == AppLanguage.kk) {
      if (short) {
        return '$mode Мен JANARYM ішінде дауыспен жұмыс істеймін: камерадағы көріністі сипаттаймын, маршрут режимін жүргіземін және командаларыңызды орындаймын.';
      }
      return '$mode Мен JANARYM ішіндегі ассистентпін. Негізгі мүмкіндіктерім: ояту сөзімен дауыстық диалог, камерадағы көріністі қысқаша сипаттау, маршрут режимін қосу/өшіру, маршрут құру, келесі қадам мен маршрут күйін айту, сондай-ақ үй/жұмыс сияқты меткаларға маршрут бастау.';
    }
    if (short) {
      return '$mode Я ассистент JANARYM: работаю голосом, описываю кадр с камеры и веду в режиме маршрута.';
    }
    return '$mode Я ассистент внутри JANARYM. Могу: работать по wake-слову «Жанарым», описывать сцену с камеры, включать и вести режим маршрута, строить маршрут до адреса или метки, озвучивать статус и следующий шаг, и менять стиль ответа (коротко/подробно).';
  }

  String _identityAnswer() {
    if (widget.appLanguage == AppLanguage.kk) {
      return 'Менің атым JANARYM ассистенті. Мен осы қолданбаның ішінде сізге дауыспен, камерамен және маршрут режимімен көмектесемін.';
    }
    return 'Я ассистент JANARYM внутри этого приложения. Помогаю голосом, камерой и режимом маршрута.';
  }

  String _routeModeHelpAnswer(bool detailed) {
    final short = !detailed || _dialogBrevityMode == _DialogBrevityMode.short;
    final navState = _navigationController.state.value;
    final routeActive = navState.activeRoute != null;
    if (widget.appLanguage == AppLanguage.kk) {
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
    if (widget.appLanguage == AppLanguage.kk) {
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
    if (widget.appLanguage == AppLanguage.kk) {
      final modeLine = navigationMode
          ? 'Қазір маршрут режимі қосулы, навигация контекстін ұстан.'
          : 'Қазір жалпы режим қосулы.';
      return 'Сен JANARYM қолданбасының ішіндегі ассистентсің. '
          'Өзіңді ChatGPT немесе тілдік модель ретінде таныстырма. '
          'Пайдаланушы "не істей аласың?" деп сұраса, тек JANARYM мүмкіндіктерін айт: '
          '1) ояту сөзі "Жанарым" арқылы дауыс диалогы, '
          '2) камера кадрын қысқаша сипаттау, '
          '3) маршрут режимін қосу/өшіру, маршрут құру, маршрут күйі мен келесі қадамды айту, '
          '4) меткаларды сақтау (үй/жұмыс) және соларға маршрут құру, '
          '5) соңғы жауапты қайталау, '
          '6) қысқа/толық жауап стилін ауыстыру. '
          'Қолданбада жоқ мүмкіндікті ойдан шығарма. '
          'Егер сұраныс қолданба шегінен тыс болса, оны қысқа айт та осы функциялардың жақынын ұсын. '
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
        '4) сохранение меток (дом/работа и т.п.) и маршрут по меткам, '
        '5) повтор последнего ответа, '
        '6) переключение стиля ответа (коротко/подробно/обычно). '
        'Не выдумывай функции, которых нет в приложении. '
        'Если запрос вне возможностей приложения, скажи это коротко и предложи ближайший поддерживаемый сценарий. '
        '$modeLine';
  }

  String _runtimeProjectStatePrompt({required bool navigationMode}) {
    final navState = _navigationController.state.value;
    final route = navState.activeRoute;
    final routeActive = route != null;
    final navStatus = _navStatusLabel(navState.navStatus);
    final cameraState = _cameraGranted && _cameraStreaming ? 'on' : 'off';
    final micState = _micGranted ? 'on' : 'off';

    if (widget.appLanguage == AppLanguage.kk) {
      return 'Ағымдағы runtime-контекст: '
          'режим=${navigationMode ? 'navigation' : 'general'}, '
          'навигация-күйі=$navStatus, '
          'белсенді маршрут=${routeActive ? 'иә' : 'жоқ'}, '
          'камера=$cameraState, микрофон=$micState. '
          'Жауапта осы контекстті ескер.';
    }
    return 'Текущий runtime-контекст: '
        'режим=${navigationMode ? 'navigation' : 'general'}, '
        'навигационный статус=$navStatus, '
        'активный маршрут=${routeActive ? 'да' : 'нет'}, '
        'камера=$cameraState, микрофон=$micState. '
        'Учитывай это состояние в ответе.';
  }

  String _navStatusLabel(NavigationStatus status) => status.name;

  String _buildBlindPrompt({bool navigationMode = false}) {
    final parts = <String>[
      CommandRouter.blindSystemPromptFor(widget.appLanguage),
      _projectCapabilitiesPrompt(navigationMode: navigationMode),
      _runtimeProjectStatePrompt(navigationMode: navigationMode),
    ];
    final styleTail = _dialogStylePromptTail();
    if (styleTail.isNotEmpty) {
      parts.add(styleTail);
    }
    if (navigationMode) {
      parts.add(
        widget.appLanguage == AppLanguage.kk
            ? 'Пайдаланушы қазір маршрут режимінде.'
            : 'Пользователь сейчас в режиме маршрута.',
      );
    }
    return parts.join(' ');
  }

  String _buildVisionPrompt() {
    final parts = <String>[
      CommandRouter.visionSystemPromptFor(widget.appLanguage),
      _projectCapabilitiesPrompt(
        navigationMode: _assistantMode == AssistantMode.navigation,
      ),
      _runtimeProjectStatePrompt(
        navigationMode: _assistantMode == AssistantMode.navigation,
      ),
    ];
    final styleTail = _dialogStylePromptTail();
    if (styleTail.isNotEmpty) {
      parts.add(styleTail);
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
  }) async {
    if (!_micGranted) {
      await _navigationController.startRoute(
        rawDestination,
        source: routeSource,
      );
      return;
    }

    var destination = _extractDestinationCandidate(rawDestination);
    if (destination.isEmpty) {
      await _speak(_l10n.navSayDestinationAfterRouteWords);
      return;
    }

    var effectiveSource = routeSource;
    final confirmAddress =
        !_personalizationReady ||
        _personalizationController.snapshot.profile.confirmAddressBeforeRoute;

    if (_personalizationReady && routeSource == 'manual') {
      final similar = await _personalizationRepository.findBestSimilarRoute(
        destination,
      );
      if (similar != null) {
        await _speak(_l10n.navConfirmAddressQuestion(similar.resolvedAddress));
        _setCircleState(CircleState.listening);
        final similarAnswer = await _sttService.startCommandListening(
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
            await _navigationController.startRoute(
              destination,
              source: effectiveSource,
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
      await _navigationController.startRoute(
        destination,
        source: effectiveSource,
      );
      return;
    }

    final wakeHealthy =
        (_wakeWordOnlyMode || !_alwaysDialogMode) &&
        _wakeService.state.value.status != WakeWordStatus.error;

    try {
      if (wakeHealthy) {
        await _wakeService.stop();
      }

      while (mounted) {
        await _speak(_l10n.navConfirmAddressQuestion(destination));
        _setCircleState(CircleState.listening);
        final answer = await _sttService.startCommandListening(
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
          await _speak(_l10n.didntHearCommandRepeat);
          continue;
        }

        final normalized = _router.normalize(response);
        if (_isAffirmativeResponse(normalized)) {
          await _navigationController.startRoute(
            destination,
            source: effectiveSource,
          );
          return;
        }

        if (_isNegativeResponse(normalized)) {
          await _speak(_l10n.navSayCorrectAddressNow);
          _setCircleState(CircleState.listening);
          final corrected = await _sttService.startCommandListening(
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
            await _speak(_l10n.didntHearCommandRepeat);
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

        await _speak(_l10n.navAnswerYesOrNoOrAddress);
      }
    } finally {
      if (wakeHealthy) {
        await _wakeService.start();
      } else if (_alwaysDialogMode ||
          _wakeService.state.value.status == WakeWordStatus.error) {
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
      await _wakeService.stop();
      _setCircleState(CircleState.listening);
      debugPrint('[STT] post-speech listening');
      final text = await _sttService.startCommandListening(
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
      debugPrint('[STT] post-speech follow-up failed: $e');
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

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    debugPrint('[TTS] speak');
    _setCircleState(CircleState.speaking);
    _isSpeaking = true;
    await _tts.stop();
    await _tts.speak(t);
    _isSpeaking = false;
    if (_circleState == CircleState.speaking) {
      _restoreWakeStateIfIdle();
    }
  }

  Future<void> _stopAll() async {
    debugPrint('[Stop] pressed');
    await _sttService.stop();
    await _tts.stop();
    _followUpActive = false;
    await _playEndCue();
    await _vibrateEnd();
    if (_micGranted) {
      if (_alwaysDialogMode) {
        _startWakeFallbackLoop();
      } else if (_wakeService.state.value.status == WakeWordStatus.error) {
        _startWakeFallbackLoop();
      } else {
        await _wakeService.start();
      }
    }
    _restoreWakeStateIfIdle();
  }

  Future<void> _stopTtsOnly() async {
    await _tts.stop();
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

  @override
  Widget build(BuildContext context) {
    final theme = _orbThemeForState(_circleState);
    final navState = _navigationController.state.value;
    final statusText = _circleStatusText();
    final statusIcon = _circleStatusIcon();
    final statusColor = _circleStatusColor();
    final modeLabel = _assistantMode == AssistantMode.navigation
        ? _l10n.modeNavigation
        : _l10n.modeGeneral;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF020617),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF020617), Color(0xFF09021A), Color(0xFF140230)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: _assistantMode == AssistantMode.navigation
                            ? const Color(0xFF0E7490).withOpacity(0.24)
                            : Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        modeLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: widget.appLanguage == AppLanguage.kk
                          ? 'Жеке баптаулар'
                          : 'Персонализация',
                      onPressed: _personalizationReady
                          ? _openPersonalizationSettings
                          : null,
                      icon: const Icon(
                        Icons.settings_voice_rounded,
                        color: Colors.white70,
                      ),
                    ),
                    PopupMenuButton<AppLanguage>(
                      initialValue: widget.appLanguage,
                      onSelected: (language) {
                        unawaited(widget.onLanguageChanged(language));
                      },
                      color: const Color(0xFF0F172A),
                      itemBuilder: (context) => [
                        PopupMenuItem<AppLanguage>(
                          value: AppLanguage.ru,
                          child: Text(_l10n.languageRu),
                        ),
                        PopupMenuItem<AppLanguage>(
                          value: AppLanguage.kk,
                          child: Text(_l10n.languageKk),
                        ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.language_rounded,
                              color: Colors.white70,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _languageBadgeLabel(widget.appLanguage),
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (_personalizationReady &&
                    _showOnboardingOverlay &&
                    _personalizationController.onboardingRequired)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildOnboardingCard(),
                  ),
                if (_assistantMode == AssistantMode.navigation)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildNavigationPanel(navState),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: statusColor.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: statusColor.withOpacity(0.85),
                                width: 1.4,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(statusIcon, color: statusColor, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  statusText,
                                  style: TextStyle(
                                    color: statusColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_followUpActive)
                            Text(
                              _l10n.statusWaitingReply,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 14,
                              ),
                            ),
                          const SizedBox(height: 24),
                          GestureDetector(
                            onTap: () => _runCommandFlow(reason: 'manual'),
                            child: AnimatedBuilder(
                              animation: _circlePulse,
                              builder: (context, child) {
                                return Transform.scale(
                                  scale: _circlePulse.value,
                                  child: child,
                                );
                              },
                              child: _AssistantOrb(
                                state: _circleState,
                                label: _circleLabel(),
                                theme: theme,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
        ? 'Жауап беріңіз немесе "кейін" деңіз.'
        : 'Ответьте голосом или скажите "позже".';

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
                  _personalizationController.pauseOnboarding();
                  setState(() {
                    _showOnboardingOverlay = false;
                  });
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

class _YuvFrame {
  final int width;
  final int height;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  const _YuvFrame({
    required this.width,
    required this.height,
    required this.y,
    required this.u,
    required this.v,
    required this.yRowStride,
    required this.uvRowStride,
    required this.uvPixelStride,
  });

  Map<String, dynamic> toMap() => {
    'width': width,
    'height': height,
    'y': y,
    'u': u,
    'v': v,
    'yRowStride': yRowStride,
    'uvRowStride': uvRowStride,
    'uvPixelStride': uvPixelStride,
  };
}

Uint8List _convertYuvToJpeg(Map<String, dynamic> args) {
  final width = args['width'] as int;
  final height = args['height'] as int;
  final yPlane = args['y'] as Uint8List;
  final uPlane = args['u'] as Uint8List;
  final vPlane = args['v'] as Uint8List;
  final yRowStride = args['yRowStride'] as int;
  final uvRowStride = args['uvRowStride'] as int;
  final uvPixelStride = args['uvPixelStride'] as int;

  final image = img.Image(width: width, height: height);

  for (int y = 0; y < height; y++) {
    final yRow = yRowStride * y;
    final uvRow = uvRowStride * (y >> 1);
    for (int x = 0; x < width; x++) {
      final uvIndex = uvRow + (x >> 1) * uvPixelStride;
      final yp = yPlane[yRow + x];
      final up = uPlane[uvIndex];
      final vp = vPlane[uvIndex];

      int r = (yp + 1.370705 * (vp - 128)).round();
      int g = (yp - 0.337633 * (up - 128) - 0.698001 * (vp - 128)).round();
      int b = (yp + 1.732446 * (up - 128)).round();

      r = r.clamp(0, 255);
      g = g.clamp(0, 255);
      b = b.clamp(0, 255);

      image.setPixelRgba(x, y, r, g, b, 255);
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: 72));
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
