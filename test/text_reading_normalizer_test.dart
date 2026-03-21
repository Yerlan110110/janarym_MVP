import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/services/text_reading_normalizer.dart';

void main() {
  group('TextReadingNormalizer', () {
    test('detects scripts correctly', () {
      expect(
        TextReadingNormalizer.detectScript('Полностью перезапусти приложение'),
        DetectedTextScript.cyrillic,
      );
      expect(
        TextReadingNormalizer.detectScript('Upgrade to Dev Mode'),
        DetectedTextScript.latin,
      );
      expect(
        TextReadingNormalizer.detectScript('Что сделать Dev Mode'),
        DetectedTextScript.mixed,
      );
    });

    test('normalizes cyrillic lookalikes conservatively', () {
      expect(
        TextReadingNormalizer.normalizeCyrillicLookalikes('KAMEPA'),
        'КАМЕРА',
      );
      expect(
        TextReadingNormalizer.normalizeCyrillicLookalikes('CAXAP'),
        'САХАР',
      );
      expect(
        TextReadingNormalizer.normalizeForManualSpeech(
          'Upgrade to Dev Mode',
          script: DetectedTextScript.latin,
        ),
        'Upgrade to Dev Mode',
      );
      expect(
        TextReadingNormalizer.normalizeForRussianSpeech('Upgrade to Dev Mode'),
        'Upgrade to Dev Mode',
      );
    });

    test('uses english tts only for clearly english text', () {
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('Upgrade to Dev Mode'),
        isTrue,
      );
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('Toyota service mode'),
        isTrue,
      );
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('YTO CAenaTb ceiyac'),
        isFalse,
      );
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('KAMEPA'),
        isFalse,
      );
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('Что сделать сейчас'),
        isFalse,
      );
      expect(
        TextReadingNormalizer.shouldUseEnglishTts('Dev Мode'),
        isFalse,
      );
    });

    test('detects pseudo-russian latin OCR correctly', () {
      expect(
        TextReadingNormalizer.looksLikePseudoRussianOcr(
          'YTO CAenaTb ceivac MonHOCTbIO NepesanycTM',
        ),
        isTrue,
      );
      expect(
        TextReadingNormalizer.looksLikePseudoRussianOcr(
          'Upgrade to Dev Mode and restart the app',
        ),
        isFalse,
      );
    });
  });
}
