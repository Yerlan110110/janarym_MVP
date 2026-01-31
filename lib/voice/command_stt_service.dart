import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

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
  CommandSttService();

  final ValueNotifier<CommandSttState> state = ValueNotifier(
    const CommandSttState(
      status: CommandSttStatus.idle,
      liveWords: '',
      finalWords: '',
    ),
  );

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _timeoutTimer;
  Completer<String?>? _completer;
  bool _finishing = false;
  String? _currentPath;

  bool get isListening => state.value.isListening;

  Future<String?> startCommandListening({int durationSeconds = 4}) async {
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
      final canRecord = await _recorder.hasPermission();
      if (!canRecord) {
        _setError('Нет доступа к микрофону для записи');
        _complete(null);
        return completer.future;
      }

      final path =
          '${Directory.systemTemp.path}/janarym_stt_${DateTime.now().millisecondsSinceEpoch}.m4a';
      _currentPath = path;

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 16000,
        ),
        path: path,
      );

      _timeoutTimer = Timer(Duration(seconds: durationSeconds), () async {
        await stop();
      });
    } catch (e) {
      _setError('STT start failed: $e');
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
          _setError('STT error: $e');
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
      throw Exception('OPENAI_API_KEY не задан (проверь .env)');
    }

    final model =
        (dotenv.env['OPENAI_STT_MODEL'] ?? 'gpt-4o-mini-transcribe').trim();
    final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = model
      ..fields['language'] = 'ru'
      ..fields['response_format'] = 'json'
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

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
}
