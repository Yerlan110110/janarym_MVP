import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'camera_frame_service.dart';
import 'text_reader_decision_helper.dart';
import 'text_reading_normalizer.dart';

class OnDeviceTextReadResult {
  const OnDeviceTextReadResult({
    required this.rawText,
    required this.lines,
    required this.manualSpeechText,
    required this.manualSpeechLines,
    required this.autoSpeechText,
    required this.autoSpeechLines,
    required this.manualFallbackText,
    required this.dominantScript,
    required this.isAutoSpeakSafe,
    this.price,
    this.calories,
  });

  final String rawText;
  final List<String> lines;
  final String manualSpeechText;
  final List<String> manualSpeechLines;
  final String autoSpeechText;
  final List<String> autoSpeechLines;
  final String manualFallbackText;
  final DetectedTextScript dominantScript;
  final bool isAutoSpeakSafe;
  final double? price;
  final int? calories;

  bool get hasRawText => rawText.trim().isNotEmpty;

  bool get hasStructuredData => price != null || calories != null;

  bool get hasManualText =>
      manualSpeechText.trim().isNotEmpty ||
      manualFallbackText.trim().isNotEmpty ||
      hasStructuredData;

  bool get hasAutoText => autoSpeechText.trim().isNotEmpty || hasStructuredData;

  bool get hasText => hasManualText;

  String get kind {
    if (price != null) return 'price';
    if (calories != null) return 'nutrition';
    return 'document';
  }
}

class OnDeviceTextReaderService {
  OnDeviceTextReaderService() : _textRecognizer = TextRecognizer();

  static const Duration _defaultMinInterval = Duration(milliseconds: 700);
  static final RegExp _structuredReadingPattern = RegExp(
    r'(\d{1,5}(?:[.,]\d{1,2})?\s*(?:тг|тенге|kzt|сом|₸|р\b|₽|price))|'
    r'(\d{1,4}\s*(?:ккал|kcal|калор))|'
    r'((?:цена|стоимость|price|калория|калорийность|энергетическ|состав))',
    caseSensitive: false,
    unicode: true,
  );
  static final RegExp _digitPattern = RegExp(r'\d');
  static final RegExp _cyrillicPattern = RegExp(r'[А-Яа-яЁё]');
  static final RegExp _latinPattern = RegExp(r'[A-Za-z]');
  static final RegExp _manualLatinWordPattern = RegExp(r'[A-Za-z]{4,}');
  static final RegExp _manualCyrillicWordPattern = RegExp(
    r'[А-Яа-яЁё]{3,}',
    unicode: true,
  );
  static final RegExp _meaningfulTokenPattern = RegExp(
    r'[A-Za-zА-Яа-яЁё0-9]{3,}',
    unicode: true,
  );
  static final RegExp _autoSafeSpeechPattern = RegExp(
    r'^[А-Яа-яЁё0-9\s.,:;!?%№()\-+₸₽/]+$',
    unicode: true,
  );
  static final RegExp _alnumPattern = RegExp(r'[A-Za-zА-Яа-яЁё0-9]');
  static final RegExp _allowedNoiseFreeChar = RegExp(
    r"[A-Za-zА-Яа-яЁё0-9\s.,:;!?%№()\-+₸₽/'&]",
    unicode: true,
  );

  final TextRecognizer _textRecognizer;
  DateTime? _lastReadAt;
  OnDeviceTextReadResult? _lastResult;
  Future<OnDeviceTextReadResult?>? _inFlightRead;

  Future<OnDeviceTextReadResult?> readFrame(
    CameraFrameSnapshot frame, {
    Duration minInterval = _defaultMinInterval,
    bool force = false,
  }) async {
    if (frame.nv21Bytes.isEmpty) return null;
    final now = DateTime.now();
    if (!force &&
        _lastResult != null &&
        _lastReadAt != null &&
        now.difference(_lastReadAt!) < minInterval) {
      return _lastResult;
    }
    final inFlight = _inFlightRead;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _readFrameInternal(frame);
    _inFlightRead = future;
    try {
      final result = await future;
      _lastReadAt = DateTime.now();
      _lastResult = result;
      return result;
    } finally {
      if (identical(_inFlightRead, future)) {
        _inFlightRead = null;
      }
    }
  }

  Future<OnDeviceTextReadResult?> _readFrameInternal(
    CameraFrameSnapshot frame,
  ) async {
    final inputImage = InputImage.fromBytes(
      bytes: frame.nv21Bytes,
      metadata: InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation: _rotationFromDegrees(frame.rotationDegrees),
        format: InputImageFormat.nv21,
        bytesPerRow: frame.width,
      ),
    );
    final recognized = await _textRecognizer.processImage(inputImage);
    final rawText = recognized.text.trim();
    if (rawText.isEmpty) return null;

    final lines = recognized.blocks
        .expand((block) => block.lines)
        .map((line) => _cleanWhitespace(line.text))
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return null;

    final normalizedText = TextReadingNormalizer.normalizeForAutoSpeech(
      rawText,
    );
    final dominantScript = TextReadingNormalizer.detectScript(normalizedText);
    final manualSpeechLines = _buildManualSpeechLines(lines);
    final manualSpeechText = manualSpeechLines.join('. ');
    final autoSpeechLines = _buildAutoSpeechLines(lines);
    final autoSpeechText = autoSpeechLines.join('. ');
    final price = _extractPrice(normalizedText);
    final calories = _extractCalories(normalizedText);
    final manualFallbackText = buildManualFallbackText(rawText);

    return OnDeviceTextReadResult(
      rawText: rawText,
      lines: lines,
      manualSpeechText: manualSpeechText,
      manualSpeechLines: manualSpeechLines,
      autoSpeechText: autoSpeechText,
      autoSpeechLines: autoSpeechLines,
      manualFallbackText: manualFallbackText,
      dominantScript: dominantScript,
      isAutoSpeakSafe: _isAutoSpeakSafe(
        dominantScript: dominantScript,
        autoSpeechText: autoSpeechText,
        price: price,
        calories: calories,
      ),
      price: price,
      calories: calories,
    );
  }

  List<String> _buildManualSpeechLines(List<String> rawLines) {
    final filtered = <String>[];
    final seen = <String>{};
    for (final rawLine in rawLines) {
      final compactRaw = _cleanWhitespace(rawLine);
      if (compactRaw.isEmpty) continue;
      final rawScript = TextReadingNormalizer.detectScript(compactRaw);
      final normalizedLine = TextReadingNormalizer.normalizeForManualSpeech(
        compactRaw,
        script: rawScript,
      );
      final compactNormalized = _cleanWhitespace(normalizedLine);
      final normalizedScript = TextReadingNormalizer.detectScript(
        compactNormalized,
      );
      final effectiveScript = normalizedScript != DetectedTextScript.unknown
          ? normalizedScript
          : rawScript;
      if (!_isUsableManualLine(
        compactRaw,
        compactNormalized,
        effectiveScript,
      )) {
        continue;
      }
      final key = compactNormalized.toLowerCase();
      if (seen.add(key)) {
        filtered.add(compactNormalized);
      }
    }
    return filtered;
  }

  List<String> _buildAutoSpeechLines(List<String> rawLines) {
    final filtered = <String>[];
    final seen = <String>{};
    for (final rawLine in rawLines) {
      final compactRaw = _cleanWhitespace(rawLine);
      if (compactRaw.isEmpty) continue;
      final normalizedLine = TextReadingNormalizer.normalizeForAutoSpeech(
        compactRaw,
      );
      final compactNormalized = _cleanWhitespace(normalizedLine);
      final normalizedScript = TextReadingNormalizer.detectScript(
        compactNormalized,
      );
      if (!_isUsableAutoLine(compactNormalized, normalizedScript)) {
        continue;
      }
      final key = compactNormalized.toLowerCase();
      if (seen.add(key)) {
        filtered.add(compactNormalized);
      }
    }
    return filtered;
  }

  bool _isUsableManualLine(
    String rawLine,
    String normalizedLine,
    DetectedTextScript script,
  ) {
    if (normalizedLine.isEmpty) return false;
    if (_structuredReadingPattern.hasMatch(normalizedLine)) return true;
    if (!_containsLetterOrDigit(normalizedLine)) return false;

    final alnumCount = _countMatches(normalizedLine, _alnumPattern);
    if (alnumCount < 4) return false;
    if (_noiseRatio(rawLine) > 0.45) return false;

    final meaningfulTokens = _extractMeaningfulTokens(normalizedLine);
    if (meaningfulTokens.isEmpty) return false;

    switch (script) {
      case DetectedTextScript.latin:
        final latinTokens = _extractLatinTokens(normalizedLine);
        if (latinTokens.isEmpty) return false;
        final suspiciousCount = latinTokens
            .where(TextReadingNormalizer.looksLikeRussianishLatin)
            .length;
        if (suspiciousCount == latinTokens.length) {
          return false;
        }
        if (latinTokens.length >= 2) return true;
        return latinTokens.first.length >= 5 && alnumCount >= 6;
      case DetectedTextScript.cyrillic:
        final cyrillicWords = _extractCyrillicWords(normalizedLine);
        if (cyrillicWords.length >= 2) return true;
        if (cyrillicWords.length == 1 &&
            cyrillicWords.first.length >= 3 &&
            alnumCount >= 6) {
          return true;
        }
        if (normalizedLine.length >= 12 && cyrillicWords.isNotEmpty) {
          return true;
        }
        return cyrillicWords.isNotEmpty &&
            _digitPattern.hasMatch(normalizedLine);
      case DetectedTextScript.mixed:
        if (meaningfulTokens.length < 2) return false;
        if (alnumCount < 8) return false;
        if (_noiseRatio(rawLine) > 0.25) return false;
        final hasUsefulCyrillic = _extractCyrillicWords(
          normalizedLine,
        ).any((word) => word.length >= 3);
        final hasUsefulLatin = _extractLatinTokens(
          normalizedLine,
        ).any((word) => word.length >= 5);
        return hasUsefulCyrillic || hasUsefulLatin;
      case DetectedTextScript.unknown:
        return false;
    }
  }

  bool _isUsableAutoLine(String normalizedLine, DetectedTextScript script) {
    if (normalizedLine.isEmpty) return false;
    if (_structuredReadingPattern.hasMatch(normalizedLine)) return true;
    if (script == DetectedTextScript.latin ||
        script == DetectedTextScript.unknown) {
      return false;
    }
    if (!TextReadingNormalizer.looksMostlyCyrillic(normalizedLine)) {
      return false;
    }
    if (!_autoSafeSpeechPattern.hasMatch(normalizedLine)) {
      return false;
    }
    final cyrillicWords = _extractCyrillicWords(normalizedLine);
    return cyrillicWords.length >= 2;
  }

  bool _isAutoSpeakSafe({
    required DetectedTextScript dominantScript,
    required String autoSpeechText,
    required double? price,
    required int? calories,
  }) {
    if (price != null || calories != null) return true;
    if (autoSpeechText.trim().isEmpty) return false;
    return dominantScript != DetectedTextScript.latin;
  }

  Future<void> dispose() async {
    _inFlightRead = null;
    _lastResult = null;
    _lastReadAt = null;
    await _textRecognizer.close();
  }

  double? _extractPrice(String text) {
    final currencyMatches = RegExp(
      r'(\d{1,5}(?:[.,]\d{1,2})?)\s*(?:тг|тенге|kzt|rub|сом|₸|р\b)',
      caseSensitive: false,
      unicode: true,
    ).allMatches(text);
    if (currencyMatches.isNotEmpty) {
      final raw = currencyMatches.first.group(1)?.replaceAll(',', '.');
      return double.tryParse(raw ?? '');
    }

    final labeledLine = RegExp(
      r'(?:цена|стоимость|price)\D{0,12}(\d{1,5}(?:[.,]\d{1,2})?)',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(text);
    final raw = labeledLine?.group(1)?.replaceAll(',', '.');
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

  InputImageRotation _rotationFromDegrees(int degrees) {
    switch (degrees) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      case 0:
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  bool _containsLetterOrDigit(String text) {
    return _countMatches(text, _alnumPattern) > 0;
  }

  List<String> _extractMeaningfulTokens(String text) {
    return _meaningfulTokenPattern
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _extractLatinTokens(String text) {
    return _manualLatinWordPattern
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _extractCyrillicWords(String text) {
    return _manualCyrillicWordPattern
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
  }

  int _countMatches(String text, RegExp pattern) {
    return pattern.allMatches(text).length;
  }

  double _noiseRatio(String text) {
    final compact = text.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return 0;
    var noisyChars = 0;
    for (final rune in compact.runes) {
      final char = String.fromCharCode(rune);
      if (!_allowedNoiseFreeChar.hasMatch(char)) {
        noisyChars += 1;
      }
    }
    return noisyChars / compact.length;
  }

  String _cleanWhitespace(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
