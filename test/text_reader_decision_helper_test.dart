import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/services/text_reader_decision_helper.dart';
import 'package:janarym_app2/services/text_reading_normalizer.dart';

void main() {
  group('TextReaderDecisionHelper', () {
    test('scores strong cyrillic candidate above acceptance threshold', () {
      final score = scoreManualTextReadCandidate(
        text: 'Что сделать сейчас полностью перезапусти приложение',
        manualSpeechLinesCount: 2,
        dominantScript: DetectedTextScript.cyrillic,
        hasStructuredData: false,
      );

      expect(score, greaterThanOrEqualTo(35));
    });

    test('scores mixed garbage below acceptance threshold', () {
      final score = scoreManualTextReadCandidate(
        text: 'УТо каенатб',
        manualSpeechLinesCount: 1,
        dominantScript: DetectedTextScript.mixed,
        hasStructuredData: false,
      );

      expect(score, lessThan(35));
    });

    test('builds fallback for long cyrillic text', () {
      final fallback = buildManualFallbackText(
        'Что сделать сейчас полностью перезапусти приложение и открой его заново',
      );

      expect(fallback, isNotEmpty);
      expect(
        TextReadingNormalizer.detectScript(fallback),
        DetectedTextScript.cyrillic,
      );
    });

    test('does not build fallback for mixed garbage', () {
      final fallback = buildManualFallbackText(
        'YTO CAenaTb nepesanycTM npunoKeHMe',
      );

      expect(fallback, isEmpty);
    });

    test('builds stable signature for weak repeated candidates', () {
      final first = buildManualCandidateSignature('УТО CAenaTb сеńуас:');
      final second = buildManualCandidateSignature('УТО CnenaTb сеń4ас:');

      expect(first, isNotEmpty);
      expect(first, equals(second));
    });

    test('accepts weak manual candidate when it is stable', () {
      expect(
        shouldAcceptWeakManualCandidate(
          score: 26.8,
          hasStructuredData: false,
          text: 'УТО CAenaTb сеńуас:',
          stableRepeats: 3,
        ),
        isTrue,
      );
    });

    test('structured-only auto speak policy allows structured data only', () {
      expect(
        shouldAutoSpeakStructuredOnly(
          hasStructuredData: true,
          isAutoSpeakSafe: true,
        ),
        isTrue,
      );
      expect(
        shouldAutoSpeakStructuredOnly(
          hasStructuredData: false,
          isAutoSpeakSafe: true,
        ),
        isFalse,
      );
    });
  });
}
