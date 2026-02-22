import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../l10n/app_locale_controller.dart';
import '../l10n/app_localizations.dart';

enum CommandSttStatus { idle, listening, error }

class CommandSttState {
  final CommandSttStatus status;
  final String liveWords;
  final String finalWords;
  final String? lastError;

  const CommandSttState({
    required this.status,
    required this.liveWords,
    required this.finalWords,
    this.lastError,
  });

  bool get isListening => status == CommandSttStatus.listening;
}

class CommandSttService {
  CommandSttService({AppLanguage language = AppLanguage.ru})
    : _language = language;

  final ValueNotifier<CommandSttState> state = ValueNotifier(
    const CommandSttState(
      status: CommandSttStatus.idle,
      liveWords: '',
      finalWords: '',
    ),
  );

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _timeoutTimer;
  Timer? _silenceTimer;
  Completer<String?>? _completer;
  bool _finishing = false;
  String? _currentPath;
  DateTime? _recordingStartedAt;
  DateTime? _lastVoiceAt;
  DateTime? _lastFinishedAt;
  bool _voiceDetected = false;
  bool _amplitudeProbeRunning = false;
  AppLanguage _language;

  bool get isListening => state.value.isListening;
  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  Future<String?> startCommandListening({
    int durationSeconds = 6,
    int? minListenMs,
    int? silenceHoldMs,
    double? silenceDb,
    int? ampPollMs,
    int? restartCooldownMs,
    int? maxNoSpeechMs,
  }) async {
    if (_completer != null) return _completer!.future;
    _completer = Completer<String?>();
    final completer = _completer!;

    _setState(
      status: CommandSttStatus.listening,
      liveWords: '',
      finalWords: '',
      clearError: true,
    );

    try {
      final restartCooldownMsValue =
          (restartCooldownMs ?? _readIntEnv('STT_RESTART_COOLDOWN_MS', 450))
              .clamp(0, 5000);
      final lastFinishedAt = _lastFinishedAt;
      if (restartCooldownMsValue > 0 && lastFinishedAt != null) {
        final elapsedMs = DateTime.now()
            .difference(lastFinishedAt)
            .inMilliseconds;
        if (elapsedMs < restartCooldownMsValue) {
          await Future.delayed(
            Duration(milliseconds: restartCooldownMsValue - elapsedMs),
          );
        }
      }

      final canRecord = await _recorder.hasPermission();
      if (!canRecord) {
        _setError(_l10n.sttNoMicPermission);
        _complete(null);
        return completer.future;
      }

      final encoder = _readEncoderEnv();
      final extension = _extensionForEncoder(encoder);
      final path =
          '${Directory.systemTemp.path}/janarym_stt_${DateTime.now().millisecondsSinceEpoch}.$extension';
      _currentPath = path;

      await _recorder.start(
        RecordConfig(
          encoder: encoder,
          bitRate: _readIntEnv('STT_RECORD_BITRATE', 64000),
          sampleRate: _readIntEnv('STT_RECORD_SAMPLE_RATE', 16000),
          numChannels: _readIntEnv('STT_RECORD_CHANNELS', 1),
          autoGain: _readBoolEnv('STT_AUTO_GAIN', true),
          echoCancel: _readBoolEnv('STT_ECHO_CANCEL', true),
          noiseSuppress: _readBoolEnv('STT_NOISE_SUPPRESS', true),
          audioInterruption: AudioInterruptionMode.none,
          androidConfig: AndroidRecordConfig(
            useLegacy: _readBoolEnv('STT_ANDROID_USE_LEGACY', false),
            manageBluetooth: _readBoolEnv('STT_MANAGE_BLUETOOTH', false),
            audioSource: _readAndroidAudioSourceEnv(),
            audioManagerMode: _readAudioManagerModeEnv(),
          ),
        ),
        path: path,
      );

      final maxSeconds = durationSeconds.clamp(2, 30);
      _recordingStartedAt = DateTime.now();
      _lastVoiceAt = _recordingStartedAt;
      _voiceDetected = false;
      _startSilenceMonitor(
        pollMsOverride: ampPollMs,
        minListenMsOverride: minListenMs,
        silenceHoldMsOverride: silenceHoldMs,
        silenceDbOverride: silenceDb,
        maxNoSpeechMsOverride: maxNoSpeechMs,
      );

      _timeoutTimer = Timer(Duration(seconds: maxSeconds), () async {
        await stop();
      });
    } catch (e) {
      _setError(_l10n.sttStartFailed('$e'));
      await stop();
    }

    return completer.future;
  }

  Future<void> stop() async {
    await _finish();
  }

  Future<void> dispose() async {
    await _finish();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;

    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _recordingStartedAt = null;
    _lastVoiceAt = null;
    _voiceDetected = false;
    _amplitudeProbeRunning = false;
    _lastFinishedAt = DateTime.now();

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    final path = _currentPath;
    _currentPath = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        try {
          final text = await _transcribeFile(file);
          _setState(finalWords: text ?? '', liveWords: '');
        } catch (e) {
          _setError(_l10n.sttGenericError('$e'));
        }
        try {
          await file.delete();
        } catch (_) {}
      }
    }

    _setState(status: CommandSttStatus.idle, liveWords: '');
    _complete(state.value.finalWords.isEmpty ? null : state.value.finalWords);

    _finishing = false;
  }

  void _startSilenceMonitor({
    int? pollMsOverride,
    int? minListenMsOverride,
    int? silenceHoldMsOverride,
    double? silenceDbOverride,
    int? maxNoSpeechMsOverride,
  }) {
    _silenceTimer?.cancel();
    final pollMs = (pollMsOverride ?? _readIntEnv('STT_AMP_POLL_MS', 140))
        .clamp(60, 600);
    final minListenMs =
        (minListenMsOverride ?? _readIntEnv('STT_MIN_LISTEN_MS', 1500)).clamp(
          300,
          12000,
        );
    final silenceHoldMs =
        (silenceHoldMsOverride ?? _readIntEnv('STT_SILENCE_HOLD_MS', 2400))
            .clamp(300, 12000);
    final silenceDb =
        (silenceDbOverride ?? _readDoubleEnv('STT_SILENCE_DB', -52.0)).clamp(
          -90.0,
          -8.0,
        );
    final maxNoSpeechMs = maxNoSpeechMsOverride?.clamp(300, 30000);

    _silenceTimer = Timer.periodic(Duration(milliseconds: pollMs), (_) async {
      if (_finishing || _completer == null) return;
      if (_amplitudeProbeRunning) return;
      _amplitudeProbeRunning = true;
      try {
        if (!await _recorder.isRecording()) return;
        final now = DateTime.now();
        final amplitude = await _recorder.getAmplitude();
        final currentDb = amplitude.current.isFinite
            ? amplitude.current
            : -160.0;
        final maxDb = amplitude.max.isFinite ? amplitude.max : currentDb;
        if (currentDb > silenceDb || maxDb > silenceDb) {
          _voiceDetected = true;
          _lastVoiceAt = now;
        }

        final startedAt = _recordingStartedAt ?? now;
        final lastVoiceAt = _lastVoiceAt ?? startedAt;
        final listenedMs = now.difference(startedAt).inMilliseconds;
        final silenceMs = now.difference(lastVoiceAt).inMilliseconds;
        if (!_voiceDetected &&
            maxNoSpeechMs != null &&
            listenedMs >= maxNoSpeechMs) {
          await stop();
          return;
        }
        if (_voiceDetected &&
            listenedMs >= minListenMs &&
            silenceMs >= silenceHoldMs) {
          await stop();
        }
      } catch (_) {
        // Ignore amplitude probe issues; timeout will still finish recording.
      } finally {
        _amplitudeProbeRunning = false;
      }
    });
  }

  void _setError(String message) {
    _setState(status: CommandSttStatus.error, lastError: message);
  }

  void _setState({
    CommandSttStatus? status,
    String? liveWords,
    String? finalWords,
    String? lastError,
    bool clearError = false,
  }) {
    final current = state.value;
    state.value = CommandSttState(
      status: status ?? current.status,
      liveWords: liveWords ?? current.liveWords,
      finalWords: finalWords ?? current.finalWords,
      lastError: clearError ? null : (lastError ?? current.lastError),
    );
  }

  void _complete(String? text) {
    if (_completer == null) return;
    final completer = _completer!;
    _completer = null;
    if (!completer.isCompleted) {
      completer.complete(text);
    }
  }

  Future<String?> _transcribeFile(File file) async {
    final apiKey = (dotenv.env['OPENAI_API_KEY'] ?? '').trim();
    if (apiKey.isEmpty) {
      throw Exception(_l10n.errorOpenAiKeyMissing);
    }

    final model = (dotenv.env['OPENAI_STT_MODEL'] ?? 'gpt-4o-mini-transcribe')
        .trim();
    final language = (dotenv.env['OPENAI_STT_LANGUAGE'] ?? 'auto').trim();
    final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = model
      ..fields['response_format'] = 'json'
      ..files.add(await http.MultipartFile.fromPath('file', file.path));
    if (language.isNotEmpty && language.toLowerCase() != 'auto') {
      request.fields['language'] = language;
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final rawBody = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('OpenAI STT HTTP ${response.statusCode}: $rawBody');
    }

    final data = jsonDecode(rawBody) as Map<String, dynamic>;
    final text = (data['text'] as String?)?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  AudioEncoder _readEncoderEnv() {
    final raw = (dotenv.env['STT_RECORD_ENCODER'] ?? '').trim().toLowerCase();
    switch (raw) {
      case 'aac':
      case 'aaclc':
      case 'm4a':
        return AudioEncoder.aacLc;
      case 'wav':
      default:
        return AudioEncoder.wav;
    }
  }

  String _extensionForEncoder(AudioEncoder encoder) {
    switch (encoder) {
      case AudioEncoder.wav:
        return 'wav';
      default:
        return 'm4a';
    }
  }

  int _readIntEnv(String key, int fallback) {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  double _readDoubleEnv(String key, double fallback) {
    final raw = (dotenv.env[key] ?? '').trim();
    if (raw.isEmpty) return fallback;
    return double.tryParse(raw) ?? fallback;
  }

  bool _readBoolEnv(String key, bool fallback) {
    final raw = (dotenv.env[key] ?? '').trim().toLowerCase();
    if (raw.isEmpty) return fallback;
    if (raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on') {
      return true;
    }
    if (raw == '0' || raw == 'false' || raw == 'no' || raw == 'off') {
      return false;
    }
    return fallback;
  }

  AndroidAudioSource _readAndroidAudioSourceEnv() {
    final raw = (dotenv.env['STT_ANDROID_AUDIO_SOURCE'] ?? '')
        .trim()
        .toLowerCase();
    switch (raw) {
      case 'mic':
        return AndroidAudioSource.mic;
      case 'voicecommunication':
      case 'voice_communication':
      case 'voice-communication':
        return AndroidAudioSource.voiceCommunication;
      case 'camcorder':
        return AndroidAudioSource.camcorder;
      case 'unprocessed':
        return AndroidAudioSource.unprocessed;
      case 'default':
      case 'defaultsource':
      case 'default_source':
      case 'default-source':
        return AndroidAudioSource.defaultSource;
      case 'voicerecognition':
      case 'voice_recognition':
      case 'voice-recognition':
      default:
        return AndroidAudioSource.voiceRecognition;
    }
  }

  AudioManagerMode _readAudioManagerModeEnv() {
    final raw = (dotenv.env['STT_ANDROID_AUDIO_MANAGER_MODE'] ?? '')
        .trim()
        .toLowerCase();
    switch (raw) {
      case 'modeincommunication':
      case 'mode_in_communication':
      case 'mode-in-communication':
      case 'communication':
        return AudioManagerMode.modeInCommunication;
      case 'modeincall':
      case 'mode_in_call':
      case 'mode-in-call':
      case 'incall':
        return AudioManagerMode.modeInCall;
      case 'moderingtone':
      case 'mode_ringtone':
      case 'mode-ringtone':
      case 'ringtone':
        return AudioManagerMode.modeRingtone;
      case 'modenormal':
      case 'mode_normal':
      case 'mode-normal':
      case 'normal':
      default:
        return AudioManagerMode.modeNormal;
    }
  }
}
