import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'camera_frame_service.dart';
import 'text_reader_decision_helper.dart';
import 'text_reading_normalizer.dart';

class OnDeviceTextReadResult {
  const OnDeviceTextReadResult({
    required this.rawText,
    required this.blocks,
    required this.manualFallbackText,
    required this.dominantScript,
    required this.isAutoSpeakSafe,
    this.price,
    this.calories,
  });

  final String rawText;
  final List<String> blocks;
  final String manualFallbackText;
  final DetectedTextScript dominantScript;
  final bool isAutoSpeakSafe;
  final double? price;
  final int? calories;

  bool get hasRawText => rawText.trim().isNotEmpty;
  bool get hasStructuredData => price != null || calories != null;

  bool get hasText => blocks.isNotEmpty || manualFallbackText.trim().isNotEmpty || hasStructuredData;

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
    if (rawText.isEmpty) {
      return null;
    }

    final spatialBlocks = _buildSpatialTextBlocks(recognized.blocks);
    final normalizedText = TextReadingNormalizer.normalizeForAutoSpeech(rawText);
    final dominantScript = TextReadingNormalizer.detectScript(normalizedText);
    
    final price = _extractPrice(normalizedText);
    final calories = _extractCalories(normalizedText);
    final manualFallbackText = buildManualFallbackText(rawText);

    final autoSpeechText = spatialBlocks.join(' ');

    return OnDeviceTextReadResult(
      rawText: rawText,
      blocks: spatialBlocks,
      manualFallbackText: manualFallbackText,
      dominantScript: dominantScript,
      isAutoSpeakSafe: _isAutoSpeakSafe(
        dominantScript: dominantScript,
        autoSpeechText: autoAnswerText(spatialBlocks),
        price: price,
        calories: calories,
      ),
      price: price,
      calories: calories,
    );
  }

  String autoAnswerText(List<String> blocks) {
    if (blocks.isEmpty) return '';
    return blocks.first;
  }

  List<String> _buildSpatialTextBlocks(List<TextBlock> rawBlocks) {
    if (rawBlocks.isEmpty) return const [];

    // 1. Extract all lines with their bounding boxes
    final allLines = rawBlocks.expand((b) => b.lines).toList();
    if (allLines.isEmpty) return const [];

    // 2. Sort primarily by Y, then by X
    allLines.sort((a, b) {
      final topDiff = a.boundingBox.top - b.boundingBox.top;
      if (topDiff.abs() > 15) return topDiff.toInt();
      return (a.boundingBox.left - b.boundingBox.left).toInt();
    });

    final groups = <List<TextLine>>[];
    for (final line in allLines) {
      // Filering out single/double char snippets early (often noise)
      if (line.text.trim().length < 3) continue;

      bool foundGroup = false;
      for (final group in groups) {
        final lastInGroup = group.last;
        final verticalDist = (line.boundingBox.top - lastInGroup.boundingBox.bottom).abs();
        final horizontalOverlap = _horizontalOverlap(line.boundingBox, lastInGroup.boundingBox);
        final height = lastInGroup.boundingBox.height;
        
        // Stricter grouping: lines must be very close vertically and overlapping horizontally.
        if (verticalDist < height * 0.7 && horizontalOverlap > 0) {
          group.add(line);
          foundGroup = true;
          break;
        }
      }
      if (!foundGroup) {
        groups.add([line]);
      }
    }

    // 3. Convert groups to normalized text blocks
    return groups.map((group) {
      final text = group.map((l) => l.text).join(' ');
      return TextReadingNormalizer.normalizeForAutoSpeech(text);
    }).where((t) {
      // Must be long enough to be meaningful and pass phonetic filter
      return t.length >= 8 && TextReadingNormalizer.isSpeechSafe(t);
    }).toList();
  }

  double _horizontalOverlap(Rect a, Rect b) {
    final overlap = (a.right < b.right ? a.right : b.right) - (a.left > b.left ? a.left : b.left);
    return overlap;
  }

  bool _isAutoSpeakSafe({
    required DetectedTextScript dominantScript,
    required String autoSpeechText,
    required double? price,
    required int? calories,
  }) {
    if (price != null || calories != null) return true;
    final text = autoSpeechText.trim();
    if (text.length < 12) return false;
    
    // Safety: never auto-read pure Latin unless it's structured data (handled above)
    // because most Latin on boxes in RU regions is technical gibberish.
    if (dominantScript == DetectedTextScript.latin) return false;
    
    return TextReadingNormalizer.isSpeechSafe(text);
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
