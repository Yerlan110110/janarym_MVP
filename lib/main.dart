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
  static const int _maxFrameAgeMs = 8000;
  bool _followUpActive = false;
  bool _followUpPending = false;
  bool _wakeHandling = false;
  bool _thinkingSoundPlayed = false;
  bool _vibrationAvailable = false;
  bool _isSpeaking = false;
  int _requestId = 0;
  late final AnimationController _circleController;
  late final Animation<double> _circlePulse;
  CircleState _circleState = CircleState.idle;
  Timer? _cameraKeepAliveTimer;
  bool _wakeFallbackActive = false;
  bool _wakeFallbackLoopRunning = false;
  bool _wakeFallbackStopRequested = false;
  bool _wakeWordOnlyMode = false;
  AssistantMode _assistantMode = AssistantMode.general;
  NavPoint? _lastNavCameraTarget;
  final bool _alwaysDialogMode = _readEnvBool(
    'ALWAYS_DIALOG_MODE',
    fallback: false,
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
    _navigationController = NavigationModeController(
      speak: _speak,
      log: debugPrint,
      language: widget.appLanguage,
    );
    _sttService = CommandSttService(language: widget.appLanguage);
    _wakeService = WakeWordService(onWakeWordDetected: _handleWakeDetected);
    _openAi.setLanguage(widget.appLanguage);
    _micMessage = _l10n.checkingMic;
    _cameraMessage = _l10n.checkingCamera;
    _navigationController.state.addListener(_handleNavigationStateChange);
    _sttService.state.addListener(_handleSttStateChange);
    _wakeService.state.addListener(_handleWakeStateChange);
    _initTts();
    _initVibration();
    _initMicAndWake();
    _startCameraKeepAlive();
    unawaited(_initCameraLive());
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
      unawaited(_applyTtsLanguage(widget.appLanguage));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWakeFallbackLoop();
    _navigationController.state.removeListener(_handleNavigationStateChange);
    _sttService.state.removeListener(_handleSttStateChange);
    _wakeService.state.removeListener(_handleWakeStateChange);
    unawaited(_navigationController.dispose());
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
    await _applyTtsLanguage(widget.appLanguage);
    await _tts.setSpeechRate(0.45);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
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

  Future<void> _initVibration() async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      _vibrationAvailable = hasVibrator ?? false;
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
        await _startCameraStream();
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

  Future<void> _startCameraStream() async {
    if (_cameraStreaming || _cameraStartInProgress) return;
    _cameraStartInProgress = true;
    try {
      final existing = _cameraController;
      if (existing != null &&
          existing.value.isInitialized &&
          !existing.value.isStreamingImages) {
        await existing.startImageStream(_onCameraImage);
        if (!mounted) return;
        setState(() {
          _cameraStreaming = true;
          _cameraMessage = _l10n.cameraLiveOn;
          _cameraError = '';
        });
        return;
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

      if (existing != null) {
        try {
          await existing.dispose();
        } catch (_) {}
      }
      _lastFrame = null;
      _lastFrameAt = null;
      _lastFrameMs = 0;
      _cameraController = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();
      await _cameraController!.startImageStream(_onCameraImage);

      if (!mounted) return;
      setState(() {
        _cameraStreaming = true;
        _cameraMessage = _l10n.cameraLiveOn;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraStreaming = false;
        _cameraError = _l10n.cameraStartFailed('$e');
        _cameraMessage = _l10n.cameraLiveOff;
      });
    } finally {
      _cameraStartInProgress = false;
    }
  }

  Future<void> _stopCameraStream() async {
    final controller = _cameraController;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
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
      unawaited(_startCameraStream());
    });
  }

  void _onCameraImage(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrameMs < 400) return;
    _lastFrameMs = now;
    if (image.planes.length < 3) return;

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
    if (mounted) {
      setState(() {});
    }
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
      _stopCameraStream();
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
            _sttService.isListening) {
          await Future.delayed(_wakeFallbackIdleWait);
          continue;
        }

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
            debugPrint('[Dialog] barge-in detected: $heard');
            final stripped = _router.stripWakeWords(_router.normalize(heard));
            if (stripped.isEmpty) {
              await _handleWakeDetected();
            } else {
              await _handleDirectFallbackCommand(heard);
            }
          } else if (_shouldProcessSpeechInterruption(heard)) {
            debugPrint('[Dialog] nav interruption: $heard');
            await _handleDirectFallbackCommand(heard);
          }
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (_containsWakeWordCandidate(heard)) {
          debugPrint('[Dialog] wake phrase: $heard');
          final stripped = _router.stripWakeWords(_router.normalize(heard));
          if (stripped.isEmpty) {
            await _handleWakeDetected();
          } else {
            await _handleDirectFallbackCommand(heard);
          }
          await Future.delayed(_wakeFallbackAfterListenWait);
          continue;
        }

        if (_isDirectFallbackCommand(heard)) {
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
      case AssistantModeIntent.navStop:
      case AssistantModeIntent.navStatus:
      case AssistantModeIntent.navNextStep:
      case AssistantModeIntent.navRejectChoice:
      case AssistantModeIntent.exitNavMode:
      case AssistantModeIntent.enterNavMode:
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

    if (_assistantMode == AssistantMode.navigation) {
      final navState = _navigationController.state.value;
      final decision = _router.route(normalized);
      if (decision.candidateChoiceIndex != null &&
          navState.navStatus == NavigationStatus.awaitingChoice) {
        return true;
      }
      switch (decision.modeIntent) {
        case AssistantModeIntent.navStart:
        case AssistantModeIntent.navStop:
        case AssistantModeIntent.navStatus:
        case AssistantModeIntent.navNextStep:
        case AssistantModeIntent.navRejectChoice:
        case AssistantModeIntent.exitNavMode:
        case AssistantModeIntent.enterNavMode:
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
      _setCircleState(CircleState.wake);
      await _handleUserText(text);
    } catch (e) {
      debugPrint('[WakeFallback] direct command failed: $e');
      await _speak(_l10n.commandProcessingFailed);
    } finally {
      _commandInFlight = false;
    }
  }

  Future<void> _handleWakeDetected() async {
    final canBargeIn =
        _isSpeaking || _gptStatus == GptStatus.loading || _followUpActive;
    if (_wakeHandling && !canBargeIn) return;
    _wakeHandling = true;
    _wakeWordOnlyMode = false;
    debugPrint('[Wake] detected');
    setState(() => _lastWakeAt = DateTime.now());
    _requestId++;
    await _tts.stop();
    await _playWakeCue();
    await _vibrateStart();
    if (_followUpActive) {
      await _sttService.stop();
      _followUpActive = false;
    }
    _commandInFlight = false;
    _setCircleState(CircleState.listening);
    await _runCommandFlow(reason: 'wake');
    _wakeHandling = false;
  }

  Future<void> _armWakeWordWaiting() async {
    if (!_micGranted) return;
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
        _setCircleState(CircleState.end);
      } else if (cleaned.isNotEmpty) {
        await _handleUserText(cleaned);
      } else {
        await _playEndCue();
        await _vibrateEnd();
        _setCircleState(CircleState.end);
      }
    } finally {
      _commandInFlight = false;
    }
  }

  Future<void> _handleUserText(String text) async {
    final decision = _router.route(text);
    if (decision.modeIntent == AssistantModeIntent.enterNavMode) {
      await _enterNavigationMode();
      return;
    }
    if (decision.modeIntent == AssistantModeIntent.exitNavMode) {
      await _exitNavigationMode();
      return;
    }

    if (_assistantMode == AssistantMode.general) {
      await _handleGeneralModeCommand(text, decision);
      return;
    }

    await _handleNavigationModeCommand(text, decision);
  }

  Future<void> _handleGeneralModeCommand(
    String rawText,
    CommandDecision decision,
  ) async {
    switch (decision.modeIntent) {
      case AssistantModeIntent.navStart:
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
        await _describeWithVision(describeText);
        return;
      case AssistantModeIntent.unknown:
        final userText = decision.cleanedText.isEmpty
            ? rawText.trim()
            : decision.cleanedText.trim();
        if (userText.isEmpty) {
          await _speak(_l10n.didntHearCommandRepeat);
          return;
        }
        await _describeWithVision(userText);
        return;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
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
        final destination = decision.destinationQuery?.trim() ?? '';
        if (destination.isEmpty) {
          await _speak(_l10n.sayAddressAfterRoutePhrase);
          return;
        }
        await _startRouteWithConfirmation(destination);
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
        if (_looksLikeFreeDestination(freeText)) {
          await _startRouteWithConfirmation(freeText);
          return;
        }
        if (freeText.isNotEmpty) {
          await _speak(_l10n.unknownRouteCommandHelp);
        }
        return;
      case AssistantModeIntent.enterNavMode:
      case AssistantModeIntent.exitNavMode:
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
      final answer = await _openAi.askTextOnly(
        text,
        systemPrompt: systemPrompt,
      );
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_l10n.followUpNeedAnythingElse);
        await _startFollowUpWindow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] error: $e');
    }
    _thinkingSoundPlayed = false;
  }

  Future<void> _askGptWithImage(
    String text,
    Uint8List imageBytes, {
    String? systemPrompt,
  }) async {
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
      final answer = await _openAi.askWithImage(
        text,
        imageBytes,
        systemPrompt: systemPrompt,
        maxOutputTokens: 120,
      );
      if (!mounted) return;
      if (localRequestId != _requestId) return;
      setState(() {
        _gptStatus = GptStatus.ok;
        _lastAnswer = answer;
      });
      debugPrint('[GPT] vision ok');
      _setCircleState(CircleState.speaking);
      await _speak(answer);
      if (_micGranted) {
        await _speak(_l10n.followUpNeedAnythingElse);
        await _startFollowUpWindow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gptStatus = GptStatus.error;
        _gptError = e.toString();
      });
      debugPrint('[GPT] vision error: $e');
    }
    _thinkingSoundPlayed = false;
  }

  Future<void> _describeWithVision(String text) async {
    if (!_cameraGranted) {
      await _initCameraLive();
      if (!_cameraGranted) {
        await _speak(_l10n.noCameraAccess);
        return;
      }
    }

    if (!_cameraStreaming) {
      await _startCameraStream();
    }

    var frameReady = await _waitForFreshFrame(
      timeout: const Duration(milliseconds: 1400),
    );
    if (!frameReady) {
      await _startCameraStream();
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
      systemPrompt: CommandRouter.visionSystemPromptFor(widget.appLanguage),
    );
  }

  Future<void> _repeatLastAnswer() async {
    if (_lastAnswer.trim().isEmpty) {
      await _speak(_l10n.noAnswerToRepeat);
      return;
    }
    await _speak(_lastAnswer);
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

  bool _isNegativeResponse(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    return t == 'нет' ||
        t.startsWith('нет ') ||
        t.contains('неправильно') ||
        t.contains('не верно') ||
        t.contains('не нужно') ||
        t.contains('не надо') ||
        t.contains('спасибо') ||
        t.contains('не хочу') ||
        t == 'жоқ' ||
        t.startsWith('жоқ ') ||
        t.contains('қате') ||
        t.contains('қажет емес') ||
        t.contains('керек емес') ||
        t.contains('рахмет') ||
        t.contains('қаламаймын');
  }

  bool _isAffirmativeResponse(String text) {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return false;
    return t == 'да' ||
        t.startsWith('да ') ||
        t.contains('правильно') ||
        t.contains('верно') ||
        t.contains('подтвержда') ||
        t == 'иә' ||
        t.startsWith('иә ') ||
        t == 'ия' ||
        t.startsWith('ия ') ||
        t.contains('дұрыс') ||
        t.contains('раста');
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

  Future<void> _startRouteWithConfirmation(String rawDestination) async {
    if (!_micGranted) {
      await _navigationController.startRoute(rawDestination);
      return;
    }

    var destination = _extractDestinationCandidate(rawDestination);
    if (destination.isEmpty) {
      await _speak(_l10n.navSayDestinationAfterRouteWords);
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
          await _navigationController.startRoute(destination);
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
          continue;
        }

        final implicitDestination = _extractDestinationCandidate(response);
        if (implicitDestination.isNotEmpty) {
          destination = implicitDestination;
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
    } finally {
      _followUpActive = false;
      if (_followUpPending && mounted) {
        _followUpPending = false;
        unawaited(_startFollowUpWindow());
      }
    }
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    debugPrint('[TTS] speak');
    _isSpeaking = true;
    await _tts.stop();
    await _tts.speak(t);
    _isSpeaking = false;
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
