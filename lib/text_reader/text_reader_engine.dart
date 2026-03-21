import '../services/on_device_text_reader_service.dart';
import '../services/text_reading_normalizer.dart';
import 'text_reader_types.dart';

class TextReaderEngine {
  const TextReaderEngine();

  TextReaderScanResult? fromOnDevice(OnDeviceTextReadResult raw) {
    final lines = _normalizeLines(
      raw.orderedLines.isNotEmpty ? raw.orderedLines : raw.blocks,
    );
    final fullText = _buildFullText(lines, fallback: raw.rawText);
    if (fullText.isEmpty && raw.price == null && raw.calories == null) {
      return null;
    }
    final structuredData = TextReaderStructuredData(
      price: raw.price ?? _extractPrice(fullText),
      calories: raw.calories ?? _extractCalories(fullText),
    );
    final signature = buildSignature(fullText);
    if (signature.isEmpty && !structuredData.hasAny) {
      return null;
    }
    return TextReaderScanResult(
      fullText: fullText,
      orderedLines: lines,
      signature: signature,
      source: TextReaderScanSource.onDevice,
      quality: _assessQuality(
        text: fullText,
        structuredData: structuredData,
        rawDominantScript: raw.rawDominantScript,
        looksPseudoRussianOcr: raw.looksPseudoRussianOcr,
      ),
      structuredData: structuredData,
    );
  }

  TextReaderScanResult? fromVisionText(String rawText) {
    final lines = _normalizeLines(rawText.split(RegExp(r'[\r\n]+')));
    final fullText = _buildFullText(lines, fallback: rawText);
    if (fullText.isEmpty) return null;
    final structuredData = TextReaderStructuredData(
      price: _extractPrice(fullText),
      calories: _extractCalories(fullText),
    );
    final signature = buildSignature(fullText);
    if (signature.isEmpty && !structuredData.hasAny) {
      return null;
    }
    return TextReaderScanResult(
      fullText: fullText,
      orderedLines: lines,
      signature: signature,
      source: TextReaderScanSource.gptFallback,
      quality: _assessQuality(
        text: fullText,
        structuredData: structuredData,
        rawDominantScript: TextReadingNormalizer.detectScript(fullText),
        looksPseudoRussianOcr: TextReadingNormalizer.looksLikePseudoRussianOcr(
          fullText,
        ),
      ),
      structuredData: structuredData,
    );
  }

  TextReaderScanResult? selectBestBurst(
    Iterable<OnDeviceTextReadResult> rawResults,
  ) {
    final candidates = rawResults
        .map(fromOnDevice)
        .whereType<TextReaderScanResult>()
        .toList(growable: false);
    if (candidates.isEmpty) return null;

    final grouped = <String, List<TextReaderScanResult>>{};
    for (final candidate in candidates) {
      final key = candidate.signature.isEmpty
          ? '__empty__:${candidate.fullText}'
          : candidate.signature;
      grouped.putIfAbsent(key, () => <TextReaderScanResult>[]).add(candidate);
    }

    TextReaderScanResult? best;
    var bestRepeats = -1;
    for (final group in grouped.values) {
      final strongest = group.reduce(_preferBetterQuality);
      final safeRepeats = group.where((item) => item.isAcceptable).length;
      if (best == null) {
        best = strongest;
        bestRepeats = safeRepeats;
        continue;
      }
      if (safeRepeats > bestRepeats) {
        best = strongest;
        bestRepeats = safeRepeats;
        continue;
      }
      if (safeRepeats == bestRepeats) {
        best = _preferBetterQuality(best, strongest);
      }
    }
    return best;
  }

  bool shouldSpeakAuto({
    required String candidateSignature,
    required int stableRepeats,
    required String lastSpokenSignature,
  }) {
    if (candidateSignature.trim().isEmpty) return false;
    if (stableRepeats < 2) return false;
    return candidateSignature != lastSpokenSignature;
  }

  int stableCountForSignature({
    required String signature,
    required String pendingSignature,
    required int pendingCount,
  }) {
    if (signature.trim().isEmpty) return 0;
    return signature == pendingSignature ? pendingCount + 1 : 1;
  }

  String buildSignature(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return '';
    final normalized = TextReadingNormalizer.normalizeCyrillicLookalikes(
      compact,
    ).toLowerCase().replaceAll('4', 'ч');
    final tokens = RegExp(r'[a-zа-яё0-9]+', unicode: true)
        .allMatches(normalized)
        .map((match) => match.group(0) ?? '')
        .map(
          (token) => token.replaceAllMapped(
            RegExp(r'(.)\1+', unicode: true),
            (match) => match.group(1) ?? '',
          ),
        )
        .where((token) => token.length >= 2)
        .toList(growable: false);
    if (tokens.isEmpty) return '';
    return tokens.take(6).join('_');
  }

  List<String> normalizeOrderedLines(Iterable<String> lines) {
    return _normalizeLines(lines);
  }

  TextReaderQuality _assessQuality({
    required String text,
    required TextReaderStructuredData structuredData,
    required DetectedTextScript rawDominantScript,
    required bool looksPseudoRussianOcr,
  }) {
    if (structuredData.hasAny && text.trim().isEmpty) {
      return TextReaderQuality.acceptable;
    }

    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.isEmpty) return TextReaderQuality.weak;
    if (looksPseudoRussianOcr) return TextReaderQuality.weak;

    final script = TextReadingNormalizer.detectScript(compact);
    if (script == DetectedTextScript.mixed &&
        !TextReadingNormalizer.shouldUseEnglishTts(compact)) {
      return TextReaderQuality.weak;
    }
    if (script == DetectedTextScript.unknown &&
        rawDominantScript == DetectedTextScript.unknown &&
        !structuredData.hasAny) {
      return TextReaderQuality.weak;
    }

    final safe = TextReadingNormalizer.isSpeechSafe(compact);
    final meaningfulTokens = RegExp(
      r'[A-Za-zА-Яа-яЁё0-9]{3,}',
      unicode: true,
    ).allMatches(compact).length;
    final alnumCount = RegExp(
      r'[A-Za-zА-Яа-яЁё0-9]',
      unicode: true,
    ).allMatches(compact).length;
    if (!safe && !structuredData.hasAny) {
      return TextReaderQuality.weak;
    }
    if (meaningfulTokens >= 2 && alnumCount >= 8) {
      return TextReaderQuality.strong;
    }
    if (structuredData.hasAny) {
      return TextReaderQuality.acceptable;
    }
    if (meaningfulTokens >= 1 && compact.length >= 6 && alnumCount >= 5) {
      return TextReaderQuality.acceptable;
    }
    return TextReaderQuality.weak;
  }

  TextReaderScanResult _preferBetterQuality(
    TextReaderScanResult left,
    TextReaderScanResult right,
  ) {
    final qualityScore = <TextReaderQuality, int>{
      TextReaderQuality.strong: 3,
      TextReaderQuality.acceptable: 2,
      TextReaderQuality.weak: 1,
    };
    final leftScore = qualityScore[left.quality] ?? 0;
    final rightScore = qualityScore[right.quality] ?? 0;
    if (leftScore != rightScore) {
      return leftScore >= rightScore ? left : right;
    }
    return left.fullText.length >= right.fullText.length ? left : right;
  }

  List<String> _normalizeLines(Iterable<String> sourceLines) {
    return sourceLines
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .map(TextReadingNormalizer.normalizeCyrillicLookalikes)
        .where((line) => line.isNotEmpty)
        .where(
          (line) =>
              RegExp(r'[A-Za-zА-Яа-яЁё0-9]', unicode: true).hasMatch(line),
        )
        .toList(growable: false);
  }

  String _buildFullText(List<String> lines, {required String fallback}) {
    if (lines.isNotEmpty) {
      return lines.join('\n').trim();
    }
    return fallback.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  double? _extractPrice(String text) {
    final currencyMatches = RegExp(
      r'(\d{1,5}(?:[.,]\d{1,2})?)\s*(?:тг|тенге|kzt|rub|сом|₸|р\b|₽)',
      caseSensitive: false,
      unicode: true,
    ).allMatches(text);
    if (currencyMatches.isNotEmpty) {
      final raw = currencyMatches.first.group(1)?.replaceAll(',', '.');
      return double.tryParse(raw ?? '');
    }

    final labeled = RegExp(
      r'(?:цена|стоимость|price)\D{0,12}(\d{1,5}(?:[.,]\d{1,2})?)',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text);
    final raw = labeled?.group(1)?.replaceAll(',', '.');
    return double.tryParse(raw ?? '');
  }

  int? _extractCalories(String text) {
    final match = RegExp(
      r'(\d{1,4})\s*(?:ккал|kcal|калор)',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '');
    }
    final labeled = RegExp(
      r'(?:энергетическ\w*\s+ценност\w*|калорийн\w*)\D{0,20}(\d{1,4})',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text);
    return int.tryParse(labeled?.group(1) ?? '');
  }
}
