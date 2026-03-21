import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/services/on_device_text_reader_service.dart';
import 'package:janarym_app2/services/text_reading_normalizer.dart';
import 'package:janarym_app2/text_reader/text_reader_engine.dart';
import 'package:janarym_app2/text_reader/text_reader_types.dart';

void main() {
  group('TextReaderEngine', () {
    const engine = TextReaderEngine();

    OnDeviceTextReadResult buildResult({
      required String rawText,
      required List<String> lines,
      DetectedTextScript script = DetectedTextScript.cyrillic,
      bool safe = true,
      double? price,
      int? calories,
    }) {
      return OnDeviceTextReadResult(
        rawText: rawText,
        blocks: lines,
        manualFallbackText: rawText,
        rawDominantScript: script,
        looksPseudoRussianOcr: false,
        isAutoSpeakSafe: safe,
        price: price,
        calories: calories,
      );
    }

    test('builds full-frame text in input order and stable signature', () {
      final scan = engine.fromOnDevice(
        buildResult(
          rawText: 'Заголовок\nВторая строка',
          lines: const ['Заголовок', 'Вторая строка'],
        ),
      );

      expect(scan, isNotNull);
      expect(scan!.orderedLines, const ['Заголовок', 'Вторая строка']);
      expect(scan.fullText, 'Заголовок\nВторая строка');
      expect(scan.signature, isNotEmpty);
      expect(
        scan.quality,
        anyOf(TextReaderQuality.acceptable, TextReaderQuality.strong),
      );
    });

    test('prefers repeated acceptable burst candidate over weak one', () {
      final burst = <OnDeviceTextReadResult>[
        buildResult(rawText: 'ап', lines: const ['ап'], safe: false),
        buildResult(
          rawText: 'Режим чтения работает',
          lines: const ['Режим чтения работает'],
        ),
        buildResult(
          rawText: 'Режим чтения работает',
          lines: const ['Режим чтения работает'],
        ),
      ];

      final best = engine.selectBestBurst(burst);

      expect(best, isNotNull);
      expect(best!.fullText, 'Режим чтения работает');
      expect(best.isAcceptable, isTrue);
    });

    test('extracts structured data from fallback text', () {
      final scan = engine.fromVisionText('Цена 350 тг\n120 ккал');

      expect(scan, isNotNull);
      expect(scan!.source, TextReaderScanSource.gptFallback);
      expect(scan.structuredData.price, 350);
      expect(scan.structuredData.calories, 120);
    });
  });
}
