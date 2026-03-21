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

    test('builds non-empty fuzzy signatures for weak repeated candidates', () {
      final first = buildManualCandidateSignature('УТО CAenaTb сеńуас:');
      final second = buildManualCandidateSignature('УТО CnenaTb сеń4ас:');

      expect(first, isNotEmpty);
      expect(second, isNotEmpty);
      expect(first.split('_').first, equals(second.split('_').first));
      expect(first.split('_').length, equals(second.split('_').length));
    });

    test('rejects weak pseudo-russian candidate even when it is stable', () {
      expect(
        shouldAcceptWeakManualCandidate(
          score: 26.8,
          hasStructuredData: false,
          text: 'YTO CAenaTb ceńуас',
          stableRepeats: 3,
          dominantScript: DetectedTextScript.mixed,
          looksPseudoRussianOcr: true,
        ),
        isFalse,
      );
    });

    test('prefers vision fallback for suspicious mixed OCR', () {
      final assessment = assessTextReaderCandidate(
        rawText: 'YTO CAenaTb nepesanycTM npunoKeHMe',
        resolvedText: 'YTO CAenaTb nepesanycTM npunoKeHMe',
        manualSpeechLinesCount: 2,
        rawDominantScript: DetectedTextScript.mixed,
        effectiveScript: DetectedTextScript.mixed,
        hasStructuredData: false,
        stableRepeats: 2,
        acceptScore: 35,
        allowVisionFallback: true,
      );

      expect(assessment.suspicious, isTrue);
      expect(
        assessment.disposition,
        TextReaderCandidateDisposition.visionFallback,
      );
    });

    test('keeps suspicious structured OCR in structured-only mode', () {
      final assessment = assessTextReaderCandidate(
        rawText: 'YTO 350 KZT',
        resolvedText: 'Цена 350 тенге',
        manualSpeechLinesCount: 1,
        rawDominantScript: DetectedTextScript.mixed,
        effectiveScript: DetectedTextScript.cyrillic,
        hasStructuredData: true,
        stableRepeats: 1,
        acceptScore: 35,
        allowVisionFallback: true,
      );

      expect(assessment.structuredOnlyAccepted, isTrue);
      expect(
        assessment.disposition,
        TextReaderCandidateDisposition.structuredOnly,
      );
    });

    test('accepts clear cyrillic candidate for on-device speech', () {
      final assessment = assessTextReaderCandidate(
        rawText: 'Что сделать сейчас полностью перезапусти приложение',
        resolvedText: 'Что сделать сейчас полностью перезапусти приложение',
        manualSpeechLinesCount: 2,
        rawDominantScript: DetectedTextScript.cyrillic,
        effectiveScript: DetectedTextScript.cyrillic,
        hasStructuredData: false,
        stableRepeats: 2,
        acceptScore: 35,
        allowVisionFallback: true,
      );

      expect(assessment.acceptsDirectSpeech, isTrue);
      expect(
        assessment.disposition,
        TextReaderCandidateDisposition.speakOnDevice,
      );
    });

    test('aggressive short-text mode accepts short stable cyrillic text', () {
      final assessment = assessTextReaderCandidate(
        rawText: 'аптека',
        resolvedText: 'аптека',
        manualSpeechLinesCount: 1,
        rawDominantScript: DetectedTextScript.cyrillic,
        effectiveScript: DetectedTextScript.cyrillic,
        hasStructuredData: false,
        stableRepeats: 2,
        acceptScore: 24,
        allowVisionFallback: true,
        aggressiveShortText: true,
      );

      expect(assessment.acceptsDirectSpeech, isTrue);
      expect(
        assessment.disposition,
        TextReaderCandidateDisposition.speakOnDevice,
      );
    });

    test('aggressive fallback keeps short cyrillic text for manual speech', () {
      final fallback = buildManualFallbackText(
        'аптека',
        aggressiveShortText: true,
      );

      expect(fallback, equals('аптека'));
    });

    test('aggressive weak acceptance rejects short single-token OCR', () {
      expect(
        shouldAcceptWeakManualCandidate(
          score: 22,
          hasStructuredData: false,
          text: 'аптека',
          stableRepeats: 2,
          dominantScript: DetectedTextScript.cyrillic,
          aggressiveShortText: true,
        ),
        isFalse,
      );
    });

    test('aggressive weak acceptance keeps longer stable multi-token text', () {
      expect(
        shouldAcceptWeakManualCandidate(
          score: 24,
          hasStructuredData: false,
          text: 'режим чтения',
          stableRepeats: 3,
          dominantScript: DetectedTextScript.cyrillic,
          aggressiveShortText: true,
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
