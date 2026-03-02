import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/voice/spoken_language_detector.dart';

void main() {
  group('SpokenLanguageDetector', () {
    test('detects kazakh by specific letters', () {
      final result = SpokenLanguageDetector.detect(
        'Жанарым, не көріп тұрсың?',
        fallbackLanguage: AppLanguage.ru,
      );

      expect(result.language, AppLanguage.kk);
      expect(result.confidence, SpokenLanguageConfidence.high);
      expect(result.reason, 'kazakh_letters');
    });

    test('detects explicit kazakh language switch', () {
      final result = SpokenLanguageDetector.detect(
        'қазақша жауап бер',
        fallbackLanguage: AppLanguage.ru,
      );

      expect(result.language, AppLanguage.kk);
      expect(result.confidence, SpokenLanguageConfidence.high);
      expect(result.explicitSwitch, isTrue);
    });

    test('detects russian by lexicon', () {
      final result = SpokenLanguageDetector.detect(
        'что видишь справа',
        fallbackLanguage: AppLanguage.kk,
      );

      expect(result.language, AppLanguage.ru);
      expect(result.confidence, SpokenLanguageConfidence.high);
      expect(result.reason, contains('lexicon_score_ru'));
    });

    test('falls back when transcript is ambiguous', () {
      final result = SpokenLanguageDetector.detect(
        'ok',
        fallbackLanguage: AppLanguage.kk,
      );

      expect(result.language, AppLanguage.kk);
      expect(result.confidence, SpokenLanguageConfidence.low);
    });
  });
}
