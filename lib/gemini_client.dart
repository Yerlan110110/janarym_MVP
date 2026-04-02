import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'l10n/app_locale_controller.dart';
import 'l10n/app_localizations.dart';

class LlmRateLimitException implements Exception {
  LlmRateLimitException({required this.message, this.retryAfter});

  final String message;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class LlmPersonalizationContext {
  const LlmPersonalizationContext({
    this.responseLength = 'medium',
    this.toneStyle = 'warm',
    this.warningIntensity = 2,
    this.activeFearTriggers = const [],
  });

  final String responseLength;
  final String toneStyle;
  final int warningIntensity;
  final List<String> activeFearTriggers;
}

class LlmChatMessage {
  const LlmChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

class GeminiClient {
  GeminiClient({http.Client? httpClient, AppLanguage language = AppLanguage.ru})
    : _httpClient = httpClient ?? http.Client(),
      _language = language;

  static const String _defaultModel = 'gemini-2.5-flash';
  static const String _geminiHost = 'generativelanguage.googleapis.com';
  static const String _apiVersion = 'v1beta';
  static const Duration _requestTimeout = Duration(seconds: 35);

  final http.Client _httpClient;
  AppLanguage _language;

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  String buildSystemPrompt({
    String? basePrompt,
    LlmPersonalizationContext? personalization,
  }) {
    final buffer = StringBuffer();
    if (basePrompt != null && basePrompt.trim().isNotEmpty) {
      buffer.writeln(basePrompt.trim());
    }

    if (personalization == null) {
      return buffer.toString().trim();
    }

    buffer.writeln();
    buffer.writeln(
      _language == AppLanguage.kk
          ? 'Пайдаланушыға бейімделу ережелері:'
          : 'Правила персонализации пользователя:',
    );
    buffer.writeln(
      _language == AppLanguage.kk
          ? '- Жауап ұзақтығы: ${personalization.responseLength}.'
          : '- Длина ответа: ${personalization.responseLength}.',
    );
    buffer.writeln(
      _language == AppLanguage.kk
          ? '- Сөйлесу тоны: ${personalization.toneStyle}.'
          : '- Тон общения: ${personalization.toneStyle}.',
    );
    buffer.writeln(
      _language == AppLanguage.kk
          ? '- Ескерту қарқындылығы: ${personalization.warningIntensity}/3.'
          : '- Интенсивность предупреждений: ${personalization.warningIntensity}/3.',
    );

    if (personalization.activeFearTriggers.isNotEmpty) {
      final joined = personalization.activeFearTriggers
          .where((item) => item.trim().isNotEmpty)
          .take(8)
          .join(', ');
      if (joined.isNotEmpty) {
        buffer.writeln(
          _language == AppLanguage.kk
              ? '- Ерекше назар аударатын триггерлер: $joined.'
              : '- Особые триггеры для осторожных формулировок: $joined.',
        );
      }
    }

    return buffer.toString().trim();
  }

  Future<String> askTextOnly(
    String userText, {
    String? systemPrompt,
    List<LlmChatMessage> history = const [],
    String? contextMode,
    String? safetyContext,
    String? sceneSummary,
    int maxOutputTokens = 300,
    Duration? requestTimeout,
    int maxAttempts = 2,
  }) async {
    final apiKey = _resolveGeminiApiKey();
    if (apiKey.isEmpty) {
      throw Exception(_l10n.errorGeminiKeyMissing);
    }

    final model = (dotenv.env['GEMINI_MODEL'] ?? _defaultModel).trim();
    final runtimeContextPrompt = _buildRuntimeContextPrompt(
      contextMode: contextMode,
      safetyContext: safetyContext,
      sceneSummary: sceneSummary,
    );
    final mergedSystemInstruction = _mergeSystemInstruction(
      systemPrompt,
      runtimeContextPrompt,
    );
    final body = <String, dynamic>{
      if (mergedSystemInstruction.isNotEmpty)
        'system_instruction': <String, dynamic>{
          'parts': <Map<String, String>>[
            <String, String>{'text': mergedSystemInstruction},
          ],
        },
      'contents': <Map<String, dynamic>>[
        ..._buildHistoryContents(history),
        _buildTextContent(role: 'user', text: userText.trim()),
      ],
      'generation_config': <String, dynamic>{
        'temperature': 0.4,
        'max_output_tokens': maxOutputTokens.clamp(64, 4096),
      },
    };

    final res = await _postWithRetry(
      _buildGenerateContentUri(model.isEmpty ? _defaultModel : model, apiKey),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(body),
      requestTimeout: requestTimeout,
      maxAttempts: maxAttempts,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwApiError(res);
    }

    return _extractText(_decodeJsonBody(res));
  }

  Future<String> askWithImage(
    String userText,
    Uint8List imageBytes, {
    String? systemPrompt,
    List<LlmChatMessage> history = const [],
    Map<String, Object?>? perceptionSnapshot,
    String? taskMode,
    int maxOutputTokens = 220,
    Duration? requestTimeout,
    int maxAttempts = 2,
  }) async {
    final apiKey = _resolveGeminiApiKey();
    if (apiKey.isEmpty) {
      throw Exception(_l10n.errorGeminiKeyMissing);
    }
    if (imageBytes.isEmpty) {
      throw Exception(_l10n.errorEmptyImageFrame);
    }

    final model = (dotenv.env['GEMINI_VISION_MODEL'] ?? _defaultModel).trim();
    final visionContextPrompt = _buildVisionRuntimePrompt(
      taskMode: taskMode,
      perceptionSnapshot: perceptionSnapshot,
    );
    final mergedSystemInstruction = _mergeSystemInstruction(
      systemPrompt,
      visionContextPrompt,
    );
    final body = <String, dynamic>{
      if (mergedSystemInstruction.isNotEmpty)
        'system_instruction': <String, dynamic>{
          'parts': <Map<String, String>>[
            <String, String>{'text': mergedSystemInstruction},
          ],
        },
      'contents': <Map<String, dynamic>>[
        ..._buildHistoryContents(history),
        <String, dynamic>{
          'role': 'user',
          'parts': <Map<String, dynamic>>[
            <String, String>{'text': userText.trim()},
            <String, dynamic>{
              'inline_data': <String, String>{
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              },
            },
          ],
        },
      ],
      'generation_config': <String, dynamic>{
        'temperature': 0.2,
        'max_output_tokens': maxOutputTokens.clamp(64, 4096),
      },
    };

    final res = await _postWithRetry(
      _buildGenerateContentUri(model.isEmpty ? _defaultModel : model, apiKey),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(body),
      requestTimeout: requestTimeout,
      maxAttempts: maxAttempts,
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwApiError(res);
    }

    return _extractText(_decodeJsonBody(res));
  }

  List<Map<String, dynamic>> _buildHistoryContents(
    List<LlmChatMessage> history,
  ) {
    if (history.isEmpty) return const <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final turn in history) {
      final content = turn.content.trim();
      if (content.isEmpty) continue;
      result.add(_buildTextContent(role: turn.role, text: content));
    }
    return result;
  }

  Map<String, dynamic> _buildTextContent({
    required String role,
    required String text,
  }) {
    return <String, dynamic>{
      'role': _normalizeRole(role),
      'parts': <Map<String, String>>[
        <String, String>{'text': text},
      ],
    };
  }

  String _normalizeRole(String role) {
    final normalized = role.trim().toLowerCase();
    if (normalized == 'assistant' || normalized == 'model') return 'model';
    return 'user';
  }

  String _mergeSystemInstruction(String? primary, String? secondary) {
    final parts = <String>[];
    final first = primary?.trim() ?? '';
    final second = secondary?.trim() ?? '';
    if (first.isNotEmpty) parts.add(first);
    if (second.isNotEmpty) parts.add(second);
    return parts.join('\n\n').trim();
  }

  String _buildRuntimeContextPrompt({
    String? contextMode,
    String? safetyContext,
    String? sceneSummary,
  }) {
    final parts = <String>[];
    if (contextMode != null && contextMode.trim().isNotEmpty) {
      parts.add('context_mode=${contextMode.trim()}');
    }
    if (safetyContext != null && safetyContext.trim().isNotEmpty) {
      parts.add('safety_context=${safetyContext.trim()}');
    }
    if (sceneSummary != null && sceneSummary.trim().isNotEmpty) {
      parts.add('scene_summary=${sceneSummary.trim()}');
    }
    if (parts.isEmpty) return '';
    return 'Runtime context: ${parts.join('; ')}.';
  }

  String _buildVisionRuntimePrompt({
    String? taskMode,
    Map<String, Object?>? perceptionSnapshot,
  }) {
    final parts = <String>[];
    if (taskMode != null && taskMode.trim().isNotEmpty) {
      parts.add('task_mode=${taskMode.trim()}');
    }
    final snapshot = perceptionSnapshot ?? const <String, Object?>{};
    if (snapshot.isNotEmpty) {
      parts.add('perception_snapshot=${jsonEncode(snapshot)}');
    }
    if (parts.isEmpty) return '';
    return 'Vision runtime context: ${parts.join('; ')}.';
  }

  Future<http.Response> _postWithRetry(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
    Duration? requestTimeout,
    int maxAttempts = 3,
  }) async {
    final effectiveMaxAttempts = maxAttempts.clamp(1, 3).toInt();
    var attempt = 0;
    Duration? nextDelay;
    while (true) {
      attempt++;
      try {
        final response = await _httpClient
            .post(uri, headers: headers, body: body)
            .timeout(requestTimeout ?? _requestTimeout);
        if (_isRetriableStatus(response.statusCode) &&
            attempt < effectiveMaxAttempts) {
          nextDelay = _retryDelayForAttempt(
            attempt,
            retryAfter: _extractRetryAfter(response),
          );
          await Future.delayed(nextDelay);
          continue;
        }
        return response;
      } on Exception {
        if (attempt >= effectiveMaxAttempts) rethrow;
        nextDelay = _retryDelayForAttempt(attempt);
        await Future.delayed(nextDelay);
      }
    }
  }

  bool _isRetriableStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 409 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  Duration _retryDelayForAttempt(int attempt, {Duration? retryAfter}) {
    if (retryAfter != null && retryAfter.inMilliseconds > 0) {
      return Duration(
        seconds: retryAfter.inSeconds.clamp(1, 15),
        milliseconds: 0,
      );
    }
    switch (attempt) {
      case 1:
        return const Duration(milliseconds: 450);
      case 2:
        return const Duration(milliseconds: 900);
      default:
        return const Duration(milliseconds: 1200);
    }
  }

  String _extractText(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) {
      return _l10n.errorExtractTextFailed;
    }

    final candidates = decoded['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final first = candidates.first;
      if (first is Map<String, dynamic>) {
        final content = first['content'];
        if (content is Map<String, dynamic>) {
          final parts = content['parts'];
          if (parts is List) {
            final buffer = StringBuffer();
            for (final item in parts) {
              if (item is! Map<String, dynamic>) continue;
              final value = (item['text'] as String?)?.trim() ?? '';
              if (value.isNotEmpty) {
                if (buffer.isNotEmpty) buffer.writeln();
                buffer.write(value);
              }
            }
            final value = buffer.toString().trim();
            if (value.isNotEmpty) return value;
          }
        }
      }
    }

    return _l10n.errorExtractTextFailed;
  }

  Uri _buildGenerateContentUri(String model, String apiKey) {
    return Uri.https(
      _geminiHost,
      '/$_apiVersion/models/$model:generateContent',
      <String, String>{'key': apiKey},
    );
  }

  dynamic _decodeJsonBody(http.Response response) {
    final rawBody = utf8.decode(response.bodyBytes);
    return jsonDecode(rawBody);
  }

  void _throwApiError(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode == 429) {
      throw LlmRateLimitException(
        message: _extractApiErrorMessage(body),
        retryAfter: _extractRetryAfter(response),
      );
    }
    throw Exception('Gemini HTTP ${response.statusCode}: $body');
  }

  String _extractApiErrorMessage(String rawBody) {
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = (error['message'] as String?)?.trim();
          if (message != null && message.isNotEmpty) return message;
        }
      }
    } catch (_) {}
    return rawBody.trim();
  }

  Duration? _extractRetryAfter(http.Response response) {
    final retryAfterHeader = response.headers['retry-after']?.trim();
    if (retryAfterHeader != null && retryAfterHeader.isNotEmpty) {
      final seconds = int.tryParse(retryAfterHeader);
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds);
      }
    }

    final rawBody = utf8.decode(response.bodyBytes);
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final details = error['details'];
          if (details is List) {
            for (final item in details) {
              if (item is! Map<String, dynamic>) continue;
              final retryDelay = (item['retryDelay'] as String?)?.trim();
              final parsed = _parseSecondsDuration(retryDelay);
              if (parsed != null) return parsed;
            }
          }
        }
      }
    } catch (_) {}

    final fromMessage = RegExp(
      r'retry in ([0-9]+(?:\.[0-9]+)?)s',
      caseSensitive: false,
    ).firstMatch(rawBody);
    if (fromMessage != null) {
      final seconds = double.tryParse(fromMessage.group(1) ?? '');
      if (seconds != null && seconds > 0) {
        return Duration(milliseconds: (seconds * 1000).round());
      }
    }
    return null;
  }

  Duration? _parseSecondsDuration(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)s$').firstMatch(value);
    if (match == null) return null;
    final seconds = double.tryParse(match.group(1) ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  String _resolveGeminiApiKey() {
    final value = _sanitizeApiKey(dotenv.env['GEMINI_API_KEY']);
    return value;
  }

  String _sanitizeApiKey(String? raw) {
    if (raw == null) return '';
    return raw.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  }

  void dispose() {
    _httpClient.close();
  }
}
