import 'text_reading_normalizer.dart';

double scoreManualTextReadCandidate({
  required String text,
  required int manualSpeechLinesCount,
  required DetectedTextScript dominantScript,
  required bool hasStructuredData,
}) {
  final trimmed = text.trim();
  var score = 0.0;

  if (hasStructuredData) score += 40.0;
  if (trimmed.isNotEmpty) {
    score += (trimmed.length.clamp(0, 120) / 4.0);
  }
  score += (manualSpeechLinesCount.clamp(0, 3) * 10).toDouble();

  switch (dominantScript) {
    case DetectedTextScript.cyrillic:
      score += 20.0;
      break;
    case DetectedTextScript.latin:
      score += 12.0;
      break;
    case DetectedTextScript.mixed:
      score -= 8.0;
      break;
    case DetectedTextScript.unknown:
      score -= 20.0;
      break;
  }

  if (trimmed.isEmpty) score -= 40.0;
  if (trimmed.isNotEmpty && trimmed.length < 12) score -= 10.0;
  if (dominantScript == DetectedTextScript.mixed && !hasStructuredData) {
    score -= 12.0;
  }

  return score;
}

String buildManualFallbackText(String rawText) {
  final compact = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return '';

  final rawScript = TextReadingNormalizer.detectScript(compact);
  final normalized = TextReadingNormalizer.normalizeForManualSpeech(
    compact,
    script: rawScript,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return '';

  final script = TextReadingNormalizer.detectScript(normalized);
  if (script == DetectedTextScript.unknown ||
      script == DetectedTextScript.mixed) {
    return '';
  }
  if (script == DetectedTextScript.latin) {
    final latinTokens = RegExp(r'[A-Za-z]{4,}')
        .allMatches(normalized)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (latinTokens.isEmpty) return '';
    final suspiciousCount = latinTokens
        .where(TextReadingNormalizer.looksLikeRussianishLatin)
        .length;
    if (suspiciousCount == latinTokens.length) {
      return '';
    }
  }

  final alnumCount = RegExp(
    r'[A-Za-zА-Яа-яЁё0-9]',
  ).allMatches(normalized).length;
  if (alnumCount < 16) return '';
  if (_noiseRatio(normalized) > 0.25) return '';

  if (script == DetectedTextScript.cyrillic && normalized.length >= 20) {
    return normalized;
  }
  if (script == DetectedTextScript.latin && normalized.length >= 24) {
    return normalized;
  }
  return '';
}

bool shouldAutoSpeakStructuredOnly({
  required bool hasStructuredData,
  required bool isAutoSpeakSafe,
}) {
  return hasStructuredData && isAutoSpeakSafe;
}

String buildManualCandidateSignature(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return '';
  final normalized = TextReadingNormalizer.normalizeCyrillicLookalikes(
    compact,
  ).toLowerCase().replaceAll('4', 'ч');
  final tokens = RegExp(r'[a-zа-яё0-9]+', unicode: true)
      .allMatches(normalized)
      .map((match) {
        final token = match.group(0) ?? '';
        // Keep vowels but collapse repeats and keep first vowel if possible
        // This is less destructive than stripping all vowels
        final collapsed = token.replaceAllMapped(
          RegExp(r'(.)\1+', unicode: true),
          (match) => match.group(1) ?? '',
        );
        return collapsed;
      })
      .where((token) => token.length >= 2)
      .toList(growable: false);
  final signature = tokens.take(4).join('_');
  if (signature.length <= 48) {
    return signature;
  }
  return signature.substring(0, 48);
}

bool shouldAcceptWeakManualCandidate({
  required double score,
  required bool hasStructuredData,
  required String text,
  required int stableRepeats,
}) {
  final trimmed = text.trim();
  if (hasStructuredData) return true;
  if (trimmed.isEmpty) return false;
  if (stableRepeats < 2) return false;
  if (score < 20.0) return false;
  if (trimmed.length < 12) return false;
  return !TextReadingNormalizer.shouldUseEnglishTts(trimmed);
}

double _noiseRatio(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return 0;
  var noisyChars = 0;
  final allowed = RegExp(
    r"[A-Za-zА-Яа-яЁё0-9\s.,:;!?%№()\-+₸₽/'&]",
    unicode: true,
  );
  for (final rune in compact.runes) {
    final char = String.fromCharCode(rune);
    if (!allowed.hasMatch(char)) {
      noisyChars += 1;
    }
  }
  return noisyChars / compact.length;
}
