import 'text_reading_normalizer.dart';

enum TextReaderCandidateDisposition {
  reject,
  speakOnDevice,
  approximate,
  structuredOnly,
  visionFallback,
}

class TextReaderCandidateAssessment {
  const TextReaderCandidateAssessment({
    required this.score,
    required this.suspicious,
    required this.weakAccepted,
    required this.structuredOnlyAccepted,
    required this.disposition,
  });

  final double score;
  final bool suspicious;
  final bool weakAccepted;
  final bool structuredOnlyAccepted;
  final TextReaderCandidateDisposition disposition;

  bool get acceptsDirectSpeech =>
      disposition == TextReaderCandidateDisposition.speakOnDevice;
  bool get acceptsApproximateSpeech =>
      disposition == TextReaderCandidateDisposition.approximate;
  bool get requiresVisionFallback =>
      disposition == TextReaderCandidateDisposition.visionFallback;
}

double scoreManualTextReadCandidate({
  required String text,
  required int manualSpeechLinesCount,
  required DetectedTextScript dominantScript,
  required bool hasStructuredData,
  bool aggressiveShortText = false,
}) {
  final trimmed = text.trim();
  var score = 0.0;
  final lengthDivisor = aggressiveShortText ? 3.0 : 4.0;
  final shortTextPenaltyThreshold = aggressiveShortText ? 6 : 12;

  if (hasStructuredData) score += 40.0;
  if (trimmed.isNotEmpty) {
    score += (trimmed.length.clamp(0, 120) / lengthDivisor);
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
  if (trimmed.isNotEmpty && trimmed.length < shortTextPenaltyThreshold) {
    score -= aggressiveShortText ? 8.0 : 10.0;
  }
  if (dominantScript == DetectedTextScript.mixed && !hasStructuredData) {
    score -= 12.0;
  }
  if (!hasStructuredData && !TextReadingNormalizer.isSpeechSafe(trimmed)) {
    score -= 18.0;
  }
  if (!hasStructuredData &&
      TextReadingNormalizer.looksLikePseudoRussianOcr(trimmed)) {
    score -= 30.0;
  }

  return score;
}

bool isSuspiciousTextReadCandidate({
  required String rawText,
  required String resolvedText,
  required DetectedTextScript rawDominantScript,
  required DetectedTextScript effectiveScript,
}) {
  final raw = rawText.trim();
  final resolved = resolvedText.trim();
  if (raw.isEmpty && resolved.isEmpty) return true;
  if (TextReadingNormalizer.looksLikePseudoRussianOcr(raw) ||
      TextReadingNormalizer.looksLikePseudoRussianOcr(resolved)) {
    return true;
  }
  if (rawDominantScript == DetectedTextScript.mixed ||
      effectiveScript == DetectedTextScript.mixed) {
    return true;
  }
  return rawDominantScript == DetectedTextScript.unknown &&
      effectiveScript == DetectedTextScript.unknown;
}

TextReaderCandidateAssessment assessTextReaderCandidate({
  required String rawText,
  required String resolvedText,
  required int manualSpeechLinesCount,
  required DetectedTextScript rawDominantScript,
  required DetectedTextScript effectiveScript,
  required bool hasStructuredData,
  required int stableRepeats,
  required double acceptScore,
  required bool allowVisionFallback,
  bool aggressiveShortText = false,
}) {
  final score = scoreManualTextReadCandidate(
    text: resolvedText,
    manualSpeechLinesCount: manualSpeechLinesCount,
    dominantScript: effectiveScript,
    hasStructuredData: hasStructuredData,
    aggressiveShortText: aggressiveShortText,
  );
  final suspicious = isSuspiciousTextReadCandidate(
    rawText: rawText,
    resolvedText: resolvedText,
    rawDominantScript: rawDominantScript,
    effectiveScript: effectiveScript,
  );
  final structuredOnlyAccepted =
      hasStructuredData &&
      (score < acceptScore || suspicious || resolvedText.trim().isEmpty);
  final weakAccepted =
      !structuredOnlyAccepted &&
      shouldAcceptWeakManualCandidate(
        score: score,
        hasStructuredData: hasStructuredData,
        text: resolvedText,
        stableRepeats: stableRepeats,
        dominantScript: effectiveScript,
        looksPseudoRussianOcr: suspicious,
        aggressiveShortText: aggressiveShortText,
      );
  final safeText =
      resolvedText.trim().isNotEmpty &&
      TextReadingNormalizer.isSpeechSafe(resolvedText);

  if (structuredOnlyAccepted) {
    return TextReaderCandidateAssessment(
      score: score,
      suspicious: suspicious,
      weakAccepted: weakAccepted,
      structuredOnlyAccepted: true,
      disposition: TextReaderCandidateDisposition.structuredOnly,
    );
  }

  if (suspicious) {
    return TextReaderCandidateAssessment(
      score: score,
      suspicious: true,
      weakAccepted: weakAccepted,
      structuredOnlyAccepted: false,
      disposition: allowVisionFallback
          ? TextReaderCandidateDisposition.visionFallback
          : TextReaderCandidateDisposition.reject,
    );
  }

  if (safeText && score >= acceptScore) {
    return TextReaderCandidateAssessment(
      score: score,
      suspicious: false,
      weakAccepted: weakAccepted,
      structuredOnlyAccepted: false,
      disposition: TextReaderCandidateDisposition.speakOnDevice,
    );
  }

  if (safeText && weakAccepted) {
    return TextReaderCandidateAssessment(
      score: score,
      suspicious: false,
      weakAccepted: true,
      structuredOnlyAccepted: false,
      disposition: TextReaderCandidateDisposition.approximate,
    );
  }

  return TextReaderCandidateAssessment(
    score: score,
    suspicious: suspicious,
    weakAccepted: weakAccepted,
    structuredOnlyAccepted: false,
    disposition: TextReaderCandidateDisposition.reject,
  );
}

String buildManualFallbackText(
  String rawText, {
  bool aggressiveShortText = false,
}) {
  final compact = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return '';
  if (TextReadingNormalizer.looksLikePseudoRussianOcr(compact)) return '';

  final rawScript = TextReadingNormalizer.detectScript(compact);
  if (rawScript == DetectedTextScript.mixed ||
      rawScript == DetectedTextScript.unknown) {
    return '';
  }
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
  if (alnumCount < (aggressiveShortText ? 6 : 16)) return '';
  if (_noiseRatio(normalized) > (aggressiveShortText ? 0.35 : 0.25)) {
    return '';
  }

  if (script == DetectedTextScript.cyrillic &&
      normalized.length >= (aggressiveShortText ? 6 : 20)) {
    return normalized;
  }
  if (script == DetectedTextScript.latin &&
      normalized.length >= (aggressiveShortText ? 10 : 18) &&
      TextReadingNormalizer.isLikelyEnglishText(normalized)) {
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
  required DetectedTextScript dominantScript,
  bool looksPseudoRussianOcr = false,
  bool aggressiveShortText = false,
}) {
  final trimmed = text.trim();
  if (hasStructuredData) return true;
  if (trimmed.isEmpty) return false;
  if (stableRepeats < (aggressiveShortText ? 3 : 2)) return false;
  if (score < (aggressiveShortText ? 18.0 : 20.0)) return false;
  if (trimmed.length < (aggressiveShortText ? 8 : 12)) return false;
  if (looksPseudoRussianOcr ||
      dominantScript == DetectedTextScript.mixed ||
      dominantScript == DetectedTextScript.unknown) {
    return false;
  }
  if (aggressiveShortText) {
    final meaningfulTokens = RegExp(
      r'[A-Za-zА-Яа-яЁё0-9]{3,}',
      unicode: true,
    ).allMatches(trimmed).length;
    if (meaningfulTokens == 0) return false;
    if (meaningfulTokens < 2 && trimmed.length < 12) {
      return false;
    }
  }
  if (dominantScript == DetectedTextScript.latin) {
    return TextReadingNormalizer.isLikelyEnglishText(trimmed);
  }
  return true;
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
