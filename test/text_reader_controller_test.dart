import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/services/on_device_text_reader_service.dart';
import 'package:janarym_app2/services/text_reading_normalizer.dart';
import 'package:janarym_app2/text_reader/text_reader_controller.dart';
import 'package:janarym_app2/text_reader/text_reader_engine.dart';
import 'package:janarym_app2/text_reader/text_reader_types.dart';

void main() {
  OnDeviceTextReadResult buildResult({
    required String rawText,
    required List<String> lines,
    DetectedTextScript script = DetectedTextScript.cyrillic,
    bool safe = true,
  }) {
    return OnDeviceTextReadResult(
      rawText: rawText,
      blocks: lines,
      manualFallbackText: rawText,
      rawDominantScript: script,
      looksPseudoRussianOcr: false,
      isAutoSpeakSafe: safe,
    );
  }

  group('TextReaderController', () {
    test('local OCR success path does not wait for GPT', () async {
      var onDeviceCalls = 0;
      var gptCalls = 0;
      final controller = TextReaderController(
        engine: const TextReaderEngine(),
        readOnDevice: ({required force, required timeout}) async {
          onDeviceCalls += 1;
          return buildResult(
            rawText: 'Режим чтения работает стабильно',
            lines: const ['Режим чтения работает стабильно'],
          );
        },
        readVisionFallback:
            ({
              required autoRead,
              required reason,
              required timeoutMs,
              required maxAttempts,
            }) async {
              gptCalls += 1;
              return 'GPT fallback should not run';
            },
      );

      final first = await controller.runAutoTick();
      final second = await controller.runAutoTick();

      expect(first.skipped, isTrue);
      expect(second.hasResult, isTrue);
      expect(second.result!.source, TextReaderScanSource.onDevice);
      expect(onDeviceCalls, 2);
      expect(gptCalls, 0);
    });

    test('weak OCR triggers GPT fallback once per signature', () async {
      var gptCalls = 0;
      final controller = TextReaderController(
        engine: const TextReaderEngine(),
        autoGptCooldownMs: 5000,
        readOnDevice: ({required force, required timeout}) async {
          return buildResult(rawText: 'ап', lines: const ['ап'], safe: false);
        },
        readVisionFallback:
            ({
              required autoRead,
              required reason,
              required timeoutMs,
              required maxAttempts,
            }) async {
              gptCalls += 1;
              return 'Режим чтения';
            },
      );

      final first = await controller.runAutoTick();
      final second = await controller.runAutoTick();

      expect(first.hasResult, isTrue);
      expect(first.result!.source, TextReaderScanSource.gptFallback);
      expect(second.skipped, isTrue);
      expect(gptCalls, 1);
    });

    test(
      'button path forces full-frame reads and prefers local burst result',
      () async {
        final forceValues = <bool>[];
        final queue = Queue<OnDeviceTextReadResult?>.from(
          <OnDeviceTextReadResult?>[
            buildResult(rawText: 'ре', lines: const ['ре'], safe: false),
            buildResult(
              rawText: 'Режим чтения работает',
              lines: const ['Режим чтения работает'],
            ),
            buildResult(
              rawText: 'Режим чтения работает',
              lines: const ['Режим чтения работает'],
            ),
          ],
        );
        var gptCalls = 0;
        final controller = TextReaderController(
          engine: const TextReaderEngine(),
          readOnDevice: ({required force, required timeout}) async {
            forceValues.add(force);
            return queue.removeFirst();
          },
          readVisionFallback:
              ({
                required autoRead,
                required reason,
                required timeoutMs,
                required maxAttempts,
              }) async {
                gptCalls += 1;
                return 'GPT fallback should not run';
              },
        );

        final result = await controller.runManual(
          source: TextReaderReadSource.tap,
        );

        expect(result.hasResult, isTrue);
        expect(result.result!.source, TextReaderScanSource.onDevice);
        expect(result.result!.fullText, 'Режим чтения работает');
        expect(forceValues, everyElement(isTrue));
        expect(forceValues.length, 3);
        expect(gptCalls, 0);
      },
    );

    test(
      'stale GPT response is discarded after frame signature changes',
      () async {
        final queue = Queue<OnDeviceTextReadResult?>.from(
          <OnDeviceTextReadResult?>[
            buildResult(rawText: 'ап', lines: const ['ап'], safe: false),
            buildResult(
              rawText: 'Новый текст в кадре',
              lines: const ['Новый текст в кадре'],
            ),
          ],
        );
        var gptCalls = 0;
        final controller = TextReaderController(
          engine: const TextReaderEngine(),
          readOnDevice: ({required force, required timeout}) async {
            return queue.removeFirst();
          },
          readVisionFallback:
              ({
                required autoRead,
                required reason,
                required timeoutMs,
                required maxAttempts,
              }) async {
                gptCalls += 1;
                return 'Старый GPT текст';
              },
        );

        final result = await controller.runAutoTick();

        expect(result.skipped, isTrue);
        expect(result.hasResult, isFalse);
        expect(gptCalls, 1);
      },
    );

    test('pause resume and stop preserve state transitions', () async {
      final controller = TextReaderController(
        engine: const TextReaderEngine(),
        readOnDevice: ({required force, required timeout}) async => null,
        readVisionFallback:
            ({
              required autoRead,
              required reason,
              required timeoutMs,
              required maxAttempts,
            }) async => null,
      );

      controller.pause();
      expect(controller.state, TextReaderState.paused);
      expect(controller.isPaused, isTrue);

      controller.resume();
      expect(controller.state, TextReaderState.idle);
      expect(controller.isPaused, isFalse);

      controller.markSpeaking();
      expect(controller.state, TextReaderState.speaking);

      controller.stop();
      expect(controller.state, TextReaderState.idle);
      expect(controller.isPaused, isFalse);
    });
  });
}
