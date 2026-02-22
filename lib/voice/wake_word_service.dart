import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

enum WakeWordStatus { armed, listening, error }

class WakeWordState {
  final WakeWordStatus status;
  final String? lastError;
  final String keywordMode;
  final String keywordLabel;

  const WakeWordState({
    required this.status,
    required this.keywordMode,
    required this.keywordLabel,
    this.lastError,
  });

  bool get isListening => status == WakeWordStatus.listening;
}

class WakeWordService {
  WakeWordService({required this.onWakeWordDetected});

  final VoidCallback onWakeWordDetected;
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
      keywordMode: 'jarvis',
      keywordLabel: 'jarvis',
    ),
  );

  PorcupineManager? _manager;
  bool _initializing = false;
  List<String> _activeKeywordLabels = const <String>[];

  Future<void> start() async {
    if (_initializing) return;
    if (_manager == null) {
      await _initManager();
    }
    if (_manager == null) return;

    try {
      await _manager!.start();
      _setState(status: WakeWordStatus.listening);
    } on PorcupineException catch (e) {
      _setError(e.message ?? 'Porcupine error');
    } catch (e) {
      _setError('Porcupine start failed: $e');
    }
  }

  Future<void> stop() async {
    if (_manager == null) return;
    try {
      await _manager!.stop();
      _setState(status: WakeWordStatus.armed);
    } catch (e) {
      _setError('Porcupine stop failed: $e');
    }
  }

  Future<void> dispose() async {
    try {
      await _manager?.delete();
    } catch (_) {}
  }

  Future<void> _initManager() async {
    if (_initializing) return;
    _initializing = true;
    var mode = 'custom';
    try {
      final accessKey = (dotenv.env['PICOVOICE_ACCESS_KEY'] ?? '').trim();
      if (accessKey.isEmpty) {
        _setError(
          'PICOVOICE_ACCESS_KEY не задан (проверь .env)',
          keywordMode: 'custom',
          keywordLabel: '-',
        );
        return;
      }

      mode = (dotenv.env['KEYWORD_MODE'] ?? 'custom').toLowerCase().trim();
      final clampedSensitivity = _parseSensitivity(
        dotenv.env['WAKE_SENSITIVITY'],
      );
      debugPrint(
        '[Wake] init mode=$mode sensitivity=$clampedSensitivity '
        'accessKeyLen=${accessKey.length}',
      );

      if (mode == 'custom') {
        final configuredAssets = _readCustomKeywordAssets();
        debugPrint(
          '[Wake] custom assets configured: ${configuredAssets.join(', ')}',
        );
        final availableAssets = <String>[];
        for (final assetPath in configuredAssets) {
          if (await _assetExists(assetPath)) {
            availableAssets.add(assetPath);
          }
        }
        if (availableAssets.isNotEmpty) {
          _activeKeywordLabels = availableAssets
              .map(_keywordLabelFromAssetPath)
              .toList(growable: false);
          debugPrint(
            '[Wake] custom assets available: ${availableAssets.join(', ')}',
          );
          _manager = await PorcupineManager.fromKeywordPaths(
            accessKey,
            availableAssets,
            _onWakeWord,
            sensitivities: List<double>.filled(
              availableAssets.length,
              clampedSensitivity,
            ),
            errorCallback: _onError,
          );
          _setState(
            status: WakeWordStatus.armed,
            keywordMode: 'custom',
            keywordLabel: _activeKeywordLabels.join(', '),
            clearError: true,
          );
          return;
        } else {
          final expected = configuredAssets.join(', ');
          _setError(
            'Custom keyword not found. Expected one of: $expected',
            keywordMode: 'custom',
            keywordLabel: '-',
          );
          return;
        }
      }

      debugPrint('[Wake] built-in keyword mode=jarvis');
      _activeKeywordLabels = const <String>['jarvis'];
      _manager = await PorcupineManager.fromBuiltInKeywords(
        accessKey,
        [BuiltInKeyword.JARVIS],
        _onWakeWord,
        sensitivities: [clampedSensitivity],
        errorCallback: _onError,
      );
      _setState(
        status: WakeWordStatus.armed,
        keywordMode: 'jarvis',
        keywordLabel: 'jarvis',
        clearError: true,
      );
    } on PorcupineException catch (e) {
      _setError(
        e.message ?? 'Porcupine error',
        keywordMode: mode == 'custom' ? 'custom' : 'jarvis',
      );
    } catch (e) {
      _setError(
        'Porcupine init failed: $e',
        keywordMode: mode == 'custom' ? 'custom' : 'jarvis',
      );
    } finally {
      _initializing = false;
    }
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
    if (raw.isEmpty) {
      return _defaultCustomKeywordAssets;
    }

    final normalized = raw
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
        });

    final deduped = <String>[];
    for (final token in normalized) {
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

  double _parseSensitivity(String? rawValue) {
    final parsed = double.tryParse((rawValue ?? '0.75').trim()) ?? 0.75;
    final normalized = parsed > 1.0 ? parsed / 100.0 : parsed;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  void _onWakeWord(int keywordIndex) {
    final label =
        keywordIndex >= 0 && keywordIndex < _activeKeywordLabels.length
        ? _activeKeywordLabels[keywordIndex]
        : 'unknown';
    debugPrint('[Wake] detected keyword=$label index=$keywordIndex');
    onWakeWordDetected();
  }

  void _onError(PorcupineException error) {
    _setError(error.message ?? 'Porcupine error');
  }

  void _setError(String? message, {String? keywordMode, String? keywordLabel}) {
    final resolvedLabel =
        keywordLabel ??
        (_activeKeywordLabels.isEmpty ? '-' : _activeKeywordLabels.join(', '));
    _setState(
      status: WakeWordStatus.error,
      keywordMode: keywordMode,
      keywordLabel: resolvedLabel,
      lastError: message ?? 'Porcupine error',
    );
  }

  void _setState({
    required WakeWordStatus status,
    String? keywordMode,
    String? keywordLabel,
    String? lastError,
    bool clearError = false,
  }) {
    final current = state.value;
    state.value = WakeWordState(
      status: status,
      keywordMode: keywordMode ?? current.keywordMode,
      keywordLabel: keywordLabel ?? current.keywordLabel,
      lastError: clearError ? null : (lastError ?? current.lastError),
    );
  }
}
