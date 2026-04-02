import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:janarym_app2/gemini_client.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/l10n/app_localizations.dart';

void main() {
  setUp(() {
    dotenv.clean();
  });

  tearDown(() {
    dotenv.clean();
  });

  group('GeminiClient.askTextOnly', () {
    test(
      'sends Gemini generateContent body with system instruction and history',
      () async {
        dotenv.loadFromString(
          envString: '''
GEMINI_API_KEY=test-gemini-key
GEMINI_MODEL=gemini-test-flash
''',
        );

        late Uri requestUri;
        late Map<String, dynamic> requestBody;
        final client = GeminiClient(
          httpClient: MockClient((request) async {
            requestUri = request.url;
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'candidates': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'content': <String, dynamic>{
                        'parts': <Map<String, dynamic>>[
                          <String, dynamic>{'text': 'Готово'},
                        ],
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }),
          language: AppLanguage.ru,
        );

        final response = await client.askTextOnly(
          'Привет',
          systemPrompt: 'Ты ассистент.',
          history: const <LlmChatMessage>[
            LlmChatMessage(role: 'user', content: 'Как дела?'),
            LlmChatMessage(role: 'assistant', content: 'Нормально.'),
          ],
          contextMode: 'general',
          safetyContext: 'safe',
          sceneSummary: 'indoors',
          maxOutputTokens: 111,
        );

        expect(response, 'Готово');
        expect(
          requestUri.path,
          '/v1beta/models/gemini-test-flash:generateContent',
        );
        expect(requestUri.queryParameters['key'], 'test-gemini-key');

        final systemInstruction =
            ((requestBody['system_instruction']
                            as Map<String, dynamic>)['parts']
                        as List<dynamic>)
                    .cast<Map<String, dynamic>>()
                    .first['text']
                as String;
        expect(systemInstruction, contains('Ты ассистент.'));
        expect(systemInstruction, contains('Runtime context:'));
        expect(systemInstruction, contains('context_mode=general'));
        expect(systemInstruction, contains('safety_context=safe'));
        expect(systemInstruction, contains('scene_summary=indoors'));

        final contents = (requestBody['contents'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(contents, hasLength(3));
        expect(contents[0]['role'], 'user');
        expect(contents[1]['role'], 'model');
        expect(contents[2]['role'], 'user');

        final generationConfig =
            requestBody['generation_config'] as Map<String, dynamic>;
        expect(generationConfig['temperature'], 0.4);
        expect(generationConfig['max_output_tokens'], 111);
      },
    );

    test(
      'fails with Gemini-specific key error and ignores OpenAI key',
      () async {
        dotenv.loadFromString(envString: 'OPENAI_API_KEY=openai-only');
        final client = GeminiClient(
          httpClient: MockClient((_) async {
            throw StateError('network should not be called');
          }),
          language: AppLanguage.ru,
        );

        expect(
          () => client.askTextOnly('Привет'),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains(
                lookupAppLocalizations(
                  AppLanguage.ru.locale,
                ).errorGeminiKeyMissing,
              ),
            ),
          ),
        );
      },
    );
  });

  group('GeminiClient.askWithImage', () {
    test(
      'sends inline_data image payload and parses multipart text response',
      () async {
        dotenv.loadFromString(
          envString: '''
GEMINI_API_KEY=test-gemini-key
GEMINI_VISION_MODEL=gemini-vision-flash
''',
        );

        late Map<String, dynamic> requestBody;
        final client = GeminiClient(
          httpClient: MockClient((request) async {
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'candidates': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'content': <String, dynamic>{
                        'parts': <Map<String, dynamic>>[
                          <String, dynamic>{'text': 'Первая строка'},
                          <String, dynamic>{'text': 'Вторая строка'},
                        ],
                      },
                    },
                  ],
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }),
          language: AppLanguage.ru,
        );

        final response = await client.askWithImage(
          'Опиши кадр',
          Uint8List.fromList(const <int>[1, 2, 3]),
          systemPrompt: 'Опиши кратко.',
          history: const <LlmChatMessage>[
            LlmChatMessage(role: 'assistant', content: 'Предыдущий ответ'),
          ],
          taskMode: 'vision_describe',
          perceptionSnapshot: const <String, Object?>{'hazard': 'stairs'},
          maxOutputTokens: 150,
        );

        expect(response, 'Первая строка\nВторая строка');

        final contents = (requestBody['contents'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(contents, hasLength(2));
        expect(contents.first['role'], 'model');
        final lastParts = (contents.last['parts'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(lastParts[0]['text'], 'Опиши кадр');
        expect(lastParts[1]['inline_data'], <String, dynamic>{
          'mime_type': 'image/jpeg',
          'data': 'AQID',
        });

        final systemInstruction =
            ((requestBody['system_instruction']
                            as Map<String, dynamic>)['parts']
                        as List<dynamic>)
                    .cast<Map<String, dynamic>>()
                    .first['text']
                as String;
        expect(systemInstruction, contains('Опиши кратко.'));
        expect(systemInstruction, contains('Vision runtime context:'));
        expect(systemInstruction, contains('task_mode=vision_describe'));
        expect(systemInstruction, contains('"hazard":"stairs"'));
      },
    );

    test(
      'throws rate limit exception with retry delay from Google-style body',
      () async {
        dotenv.loadFromString(envString: 'GEMINI_API_KEY=test-gemini-key');
        final client = GeminiClient(
          httpClient: MockClient((_) async {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'error': <String, dynamic>{
                    'message': 'Quota exceeded',
                    'details': <Map<String, dynamic>>[
                      <String, dynamic>{'retryDelay': '7s'},
                    ],
                  },
                }),
              ),
              429,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }),
          language: AppLanguage.ru,
        );

        await expectLater(
          () => client.askWithImage(
            'Опиши кадр',
            Uint8List.fromList(const <int>[1]),
          ),
          throwsA(
            isA<LlmRateLimitException>()
                .having((e) => e.message, 'message', contains('Quota exceeded'))
                .having((e) => e.retryAfter?.inSeconds, 'retryAfter', 7),
          ),
        );
      },
    );
  });
}
