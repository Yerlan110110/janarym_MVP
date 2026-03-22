import 'dart:async';

import '../services/on_device_text_reader_service.dart';
import 'text_reader_engine.dart';
import 'text_reader_types.dart';

typedef TextReaderOnDeviceRead =
    Future<OnDeviceTextReadResult?> Function({
      required bool force,
      required Duration timeout,
    });
typedef TextReaderVisionFallback =
    Future<String?> Function({
      required bool autoRead,
      required String reason,
      required int timeoutMs,
      required int maxAttempts,
    });

class TextReaderController {
  TextReaderController({
    required TextReaderEngine engine,
    required TextReaderOnDeviceRead readOnDevice,
    required TextReaderVisionFallback readVisionFallback,
    Duration autoFrameTimeout = const Duration(milliseconds: 260),
    Duration burstFrameTimeout = const Duration(milliseconds: 220),
    Duration staleValidationTimeout = const Duration(milliseconds: 180),
    int autoGptTimeoutMs = 2500,
    int manualGptTimeoutMs = 3500,
    int tapBurstCount = 3,
    int autoGptCooldownMs = 2500,
    DateTime Function()? now,
  }) : _engine = engine,
       _readOnDevice = readOnDevice,
       _readVisionFallback = readVisionFallback,
       _autoFrameTimeout = autoFrameTimeout,
       _burstFrameTimeout = burstFrameTimeout,
       _staleValidationTimeout = staleValidationTimeout,
       _autoGptTimeoutMs = autoGptTimeoutMs,
       _manualGptTimeoutMs = manualGptTimeoutMs,
       _tapBurstCount = tapBurstCount,
       _autoGptCooldownMs = autoGptCooldownMs,
       _now = now ?? DateTime.now;

  final TextReaderEngine _engine;
  final TextReaderOnDeviceRead _readOnDevice;
  final TextReaderVisionFallback _readVisionFallback;
  final Duration _autoFrameTimeout;
  final Duration _burstFrameTimeout;
  final Duration _staleValidationTimeout;
  final int _autoGptTimeoutMs;
  final int _manualGptTimeoutMs;
  final int _tapBurstCount;
  final int _autoGptCooldownMs;
  final DateTime Function() _now;

  TextReaderState _state = TextReaderState.idle;
  String _lastFailureReason = '';
  bool _paused = false;
  bool _busy = false;
  int _runGeneration = 0;
  String _pendingSignature = '';
  int _pendingStableCount = 0;
  String _lastSpokenSignature = '';
  String _lastAutoGptSignature = '';
  int _lastAutoGptMs = 0;

  TextReaderState get state => _state;
  String get lastFailureReason => _lastFailureReason;
  bool get isPaused => _paused;
  bool get isBusy => _busy;
  String get lastSpokenSignature => _lastSpokenSignature;

  void pause() {
    _runGeneration += 1;
    _paused = true;
    _state = TextReaderState.paused;
    _pendingSignature = '';
    _pendingStableCount = 0;
  }

  void resume({bool clearSpokenSignature = true}) {
    _runGeneration += 1;
    _paused = false;
    _state = TextReaderState.idle;
    _pendingSignature = '';
    _pendingStableCount = 0;
    if (clearSpokenSignature) {
      _lastSpokenSignature = '';
    }
  }

  void stop() {
    _runGeneration += 1;
    _paused = false;
    _state = TextReaderState.idle;
    _pendingSignature = '';
    _pendingStableCount = 0;
  }

  void markSpeaking() {
    _state = TextReaderState.speaking;
  }

  void markIdle() {
    if (_paused) {
      _state = TextReaderState.paused;
      return;
    }
    _state = TextReaderState.idle;
  }

  Future<TextReaderAttemptResult> runManual({
    required TextReaderReadSource source,
  }) async {
    if (_busy) {
      return TextReaderAttemptResult(
        state: _state,
        failureReason: _lastFailureReason,
        skipped: true,
      );
    }
    _busy = true;
    final runGeneration = _runGeneration;
    _state = TextReaderState.scanning;
    _lastFailureReason = '';
    try {
      final burst = <OnDeviceTextReadResult>[];
      final attempts = source == TextReaderReadSource.tap ? _tapBurstCount : 2;
      for (var i = 0; i < attempts; i++) {
        final result = await _readOnDevice(
          force: true,
          timeout: _burstFrameTimeout,
        );
        if (_isRunCanceled(runGeneration)) {
          return TextReaderAttemptResult(
            state: _state,
            failureReason: _lastFailureReason,
            skipped: true,
          );
        }
        if (result != null && result.hasRawText) {
          burst.add(result);
        }
      }

      final bestLocal = _engine.selectBestBurst(burst);
      if (bestLocal != null && bestLocal.isAcceptable) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, result: bestLocal);
      }

      final fallback = await _readVisionFallback(
        autoRead: false,
        reason: bestLocal == null ? 'manual_no_text' : 'manual_weak_text',
        timeoutMs: _manualGptTimeoutMs,
        maxAttempts: 1,
      );
      if (_isRunCanceled(runGeneration)) {
        return TextReaderAttemptResult(
          state: _state,
          failureReason: _lastFailureReason,
          skipped: true,
        );
      }
      final visionResult = fallback == null
          ? null
          : _engine.fromVisionText(fallback);
      if (visionResult != null && visionResult.isAcceptable) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, result: visionResult);
      }

      _lastFailureReason = bestLocal == null ? 'no_text' : 'unreadable';
      _state = TextReaderState.failed;
      return TextReaderAttemptResult(
        state: _state,
        failureReason: _lastFailureReason,
      );
    } finally {
      _busy = false;
    }
  }

  Future<TextReaderAttemptResult> runAutoTick() async {
    if (_paused) {
      _state = TextReaderState.paused;
      return TextReaderAttemptResult(state: _state, skipped: true);
    }
    if (_busy) {
      return TextReaderAttemptResult(state: _state, skipped: true);
    }

    _busy = true;
    final runGeneration = _runGeneration;
    _state = TextReaderState.scanning;
    _lastFailureReason = '';
    try {
      final raw = await _readOnDevice(force: false, timeout: _autoFrameTimeout);
      if (_isRunCanceled(runGeneration)) {
        return TextReaderAttemptResult(state: _state, skipped: true);
      }
      final local = raw == null ? null : _engine.fromOnDevice(raw);
      if (local != null && local.signature.isNotEmpty) {
        _pendingStableCount = _engine.stableCountForSignature(
          signature: local.signature,
          pendingSignature: _pendingSignature,
          pendingCount: _pendingStableCount,
        );
        _pendingSignature = local.signature;
      } else {
        _pendingSignature = '';
        _pendingStableCount = 0;
      }

      if (local != null &&
          local.isAcceptable &&
          _engine.shouldSpeakAuto(
            candidateSignature: local.signature,
            stableRepeats: _pendingStableCount,
            lastSpokenSignature: _lastSpokenSignature,
          )) {
        _lastSpokenSignature = local.signature;
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, result: local);
      }

      if (local != null && local.isAcceptable) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }

      final localSignature = local?.signature ?? '';
      final requestSignature = localSignature.isNotEmpty
          ? localSignature
          : '__empty__:${_now().millisecondsSinceEpoch ~/ _autoGptCooldownMs}';
      if (!_shouldUseAutoGptFor(requestSignature: requestSignature)) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }

      _lastAutoGptSignature = requestSignature;
      _lastAutoGptMs = _now().millisecondsSinceEpoch;
      final fallback = await _readVisionFallback(
        autoRead: true,
        reason: local == null ? 'auto_no_text' : 'auto_weak_text',
        timeoutMs: _autoGptTimeoutMs,
        maxAttempts: 1,
      );
      if (_isRunCanceled(runGeneration)) {
        return TextReaderAttemptResult(state: _state, skipped: true);
      }
      if (fallback == null) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }

      if (localSignature.isNotEmpty &&
          await _isStaleVisionResponse(localSignature)) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }

      final visionResult = _engine.fromVisionText(fallback);
      if (visionResult == null || !visionResult.isAcceptable) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }
      if (!_engine.shouldSpeakAuto(
        candidateSignature: visionResult.signature,
        stableRepeats: 2,
        lastSpokenSignature: _lastSpokenSignature,
      )) {
        _state = TextReaderState.idle;
        return TextReaderAttemptResult(state: _state, skipped: true);
      }
      _lastSpokenSignature = visionResult.signature;
      _state = TextReaderState.idle;
      return TextReaderAttemptResult(state: _state, result: visionResult);
    } finally {
      _busy = false;
    }
  }

  bool _shouldUseAutoGptFor({required String requestSignature}) {
    final nowMs = _now().millisecondsSinceEpoch;
    if (requestSignature == _lastSpokenSignature) return false;
    if (requestSignature == _lastAutoGptSignature &&
        nowMs - _lastAutoGptMs < _autoGptCooldownMs) {
      return false;
    }
    return true;
  }

  bool _isRunCanceled(int runGeneration) => runGeneration != _runGeneration;

  Future<bool> _isStaleVisionResponse(String requestSignature) async {
    if (requestSignature.trim().isEmpty) return false;
    final current = await _readOnDevice(
      force: true,
      timeout: _staleValidationTimeout,
    );
    if (current == null) return false;
    final currentResult = _engine.fromOnDevice(current);
    if (currentResult == null || currentResult.signature.isEmpty) {
      return false;
    }
    return currentResult.signature != requestSignature;
  }
}
