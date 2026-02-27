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

class OpenAiPersonalizationContext {
  const OpenAiPersonalizationContext({
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

class OpenAiChatMessage {
  const OpenAiChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

class OpenAiClient {
  OpenAiClient({http.Client? httpClient, AppLanguage language = AppLanguage.ru})
    : _httpClient = httpClient ?? http.Client(),
      _language = language;

  static const String _defaultModel = 'gpt-4o-mini';
  static const String _openAiHost = 'api.openai.com';
  static const Duration _requestTimeout = Duration(seconds: 35);

  final http.Client _httpClient;
  AppLanguage _language;

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  String buildSystemPrompt({
    String? basePrompt,
    OpenAiPersonalizationContext? personalization,
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
    List<OpenAiChatMessage> history = const [],
    int maxOutputTokens = 300,
  }) async {
    final apiKey = _resolveOpenAiApiKey();
    if (apiKey.isEmpty) {
      throw Exception(_l10n.errorOpenAiKeyMissing);
    }

    final model = (dotenv.env['OPENAI_MODEL'] ?? _defaultModel).trim();
    final messages = <Map<String, dynamic>>[
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        {'role': 'system', 'content': systemPrompt.trim()},
      ..._buildHistoryMessages(history),
      {'role': 'user', 'content': userText.trim()},
    ];
    final body = <String, dynamic>{
      'model': model.isEmpty ? _defaultModel : model,
      'messages': messages,
      'max_tokens': maxOutputTokens.clamp(64, 4096),
      'temperature': 0.4,
    };

    final res = await _postWithRetry(
      _buildChatCompletionsUri(),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(body),
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
    List<OpenAiChatMessage> history = const [],
    int maxOutputTokens = 220,
  }) async {
    final apiKey = _resolveOpenAiApiKey();
    if (apiKey.isEmpty) {
      throw Exception(_l10n.errorOpenAiKeyMissing);
    }
    if (imageBytes.isEmpty) {
      throw Exception(_l10n.errorEmptyImageFrame);
    }

    final model =
        (dotenv.env['OPENAI_VISION_MODEL'] ??
                dotenv.env['OPENAI_MODEL'] ??
                _defaultModel)
            .trim();

    final messages = <Map<String, dynamic>>[
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        {'role': 'system', 'content': systemPrompt.trim()},
      ..._buildHistoryMessages(history),
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': userText.trim()},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
              'detail': 'auto',
            },
          },
        ],
      },
    ];
    final body = <String, dynamic>{
      'model': model.isEmpty ? _defaultModel : model,
      'messages': messages,
      'max_tokens': maxOutputTokens.clamp(64, 4096),
      'temperature': 0.2,
    };

    final res = await _postWithRetry(
      _buildChatCompletionsUri(),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwApiError(res);
    }

    return _extractText(_decodeJsonBody(res));
  }

  List<Map<String, dynamic>> _buildHistoryMessages(
    List<OpenAiChatMessage> history,
  ) {
    if (history.isEmpty) return const [];
    final result = <Map<String, dynamic>>[];
    for (final turn in history) {
      final role = turn.role.trim().toLowerCase();
      if (role != 'user' && role != 'assistant') continue;
      final content = turn.content.trim();
      if (content.isEmpty) continue;
      result.add({'role': role, 'content': content});
    }
    return result;
  }

  Future<http.Response> _postWithRetry(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    const maxAttempts = 3;
    var attempt = 0;
    Duration? nextDelay;
    while (true) {
      attempt++;
      try {
        final response = await _httpClient
            .post(uri, headers: headers, body: body)
            .timeout(_requestTimeout);
        if (_isRetriableStatus(response.statusCode) && attempt < maxAttempts) {
          nextDelay = _retryDelayForAttempt(
            attempt,
            retryAfter: _extractRetryAfter(response),
          );
          await Future.delayed(nextDelay);
          continue;
        }
        return response;
      } on Exception {
        if (attempt >= maxAttempts) rethrow;
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

    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map<String, dynamic>) {
        final message = first['message'];
        if (message is Map<String, dynamic>) {
          final content = message['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content.trim();
          }
          if (content is List) {
            final buffer = StringBuffer();
            for (final item in content) {
              if (item is! Map<String, dynamic>) continue;
              if (item['type'] == 'text' && item['text'] is String) {
                final value = (item['text'] as String).trim();
                if (value.isNotEmpty) {
                  buffer.writeln(value);
                }
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

  Uri _buildChatCompletionsUri() {
    return Uri.https(_openAiHost, '/v1/chat/completions');
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
    throw Exception('OpenAI HTTP ${response.statusCode}: $body');
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
      r'Please retry in ([0-9]+(?:\.[0-9]+)?)s',
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

  String _resolveOpenAiApiKey() {
    final candidates = [dotenv.env['OPENAI_API_KEY'], dotenv.env['OPENAI_KEY']];
    for (final candidate in candidates) {
      final value = _sanitizeApiKey(candidate);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _sanitizeApiKey(String? raw) {
    if (raw == null) return '';
    return raw.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
  }

  void dispose() {
    _httpClient.close();
  }
}
