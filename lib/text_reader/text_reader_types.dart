enum TextReaderState { idle, scanning, speaking, paused, failed }

enum TextReaderReadSource { voice, tap, auto }

enum TextReaderScanSource { onDevice, gptFallback }

enum TextReaderQuality { strong, acceptable, weak }

class TextReaderStructuredData {
  const TextReaderStructuredData({this.price, this.calories});

  final double? price;
  final int? calories;

  bool get hasAny => price != null || calories != null;
}

class TextReaderScanResult {
  const TextReaderScanResult({
    required this.fullText,
    required this.orderedLines,
    required this.signature,
    required this.source,
    required this.quality,
    this.structuredData = const TextReaderStructuredData(),
  });

  final String fullText;
  final List<String> orderedLines;
  final String signature;
  final TextReaderScanSource source;
  final TextReaderQuality quality;
  final TextReaderStructuredData structuredData;

  bool get hasStructuredData => structuredData.hasAny;
  bool get isStrong => quality == TextReaderQuality.strong;
  bool get isAcceptable => quality != TextReaderQuality.weak;
}

class TextReaderAttemptResult {
  const TextReaderAttemptResult({
    required this.state,
    this.result,
    this.failureReason,
    this.skipped = false,
  });

  final TextReaderState state;
  final TextReaderScanResult? result;
  final String? failureReason;
  final bool skipped;

  bool get hasResult => result != null;
}
