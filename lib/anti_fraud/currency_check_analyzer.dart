import 'dart:convert';

enum CurrencyCheckVerdict { authentic, counterfeit, uncertain }

class CurrencyCheckResult {
  const CurrencyCheckResult({
    required this.verdict,
    required this.reasons,
    this.nominal,
    this.source = 'unknown',
  });

  final CurrencyCheckVerdict verdict;
  final List<String> reasons;
  final String? nominal;
  final String source;
}

class CurrencyCheckAnalyzer {
  static const List<String> _suspiciousMarkers = <String>[
    'не является платежным средством',
    'не является платежным',
    'сувенир',
    'souvenir',
    'not legal tender',
    'sample',
    'specimen',
    'үлгі',
    'кәдесый',
    'төлем құралы болып табылмайды',
  ];

  static const List<String> _counterfeitCues = <String>[
    'counterfeit',
    'fake',
    'forgery',
    'подделк',
    'фальш',
    'сувенир',
    'кәдесый',
    'жалған',
  ];

  static const List<String> _authenticCues = <String>[
    'authentic',
    'genuine',
    'real banknote',
    'настоящ',
    'подлин',
    'түпнұсқа',
    'шынайы',
  ];

  static List<String> suspiciousMarkers(String rawText) {
    final normalized = _normalize(rawText);
    if (normalized.isEmpty) {
      return const <String>[];
    }
    return _suspiciousMarkers
        .where((marker) => normalized.contains(marker))
        .toList(growable: false);
  }

  static String? extractNominal(String rawText) {
    final match = RegExp(
      r'\b(200|500|1000|2000|5000|10000|20000)\b',
      caseSensitive: false,
      unicode: true,
    ).firstMatch(rawText);
    return match?.group(1);
  }

  static CurrencyCheckResult analyze({
    String ocrText = '',
    String visualResponse = '',
  }) {
    final ocrMarkers = suspiciousMarkers(ocrText);
    final nominal = extractNominal('$ocrText $visualResponse');
    if (ocrMarkers.isNotEmpty) {
      return CurrencyCheckResult(
        verdict: CurrencyCheckVerdict.counterfeit,
        reasons: ocrMarkers,
        nominal: nominal,
        source: 'ocr',
      );
    }

    final visual = _parseVisualResponse(visualResponse);
    if (visual != null) {
      return CurrencyCheckResult(
        verdict: visual.verdict,
        reasons: visual.reasons,
        nominal: visual.nominal ?? nominal,
        source: visual.source,
      );
    }

    return CurrencyCheckResult(
      verdict: CurrencyCheckVerdict.uncertain,
      reasons: const <String>['insufficient_evidence'],
      nominal: nominal,
      source: 'fallback',
    );
  }

  static CurrencyCheckResult? _parseVisualResponse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final verdict = _parseVerdict((decoded['verdict'] ?? '').toString());
        if (verdict != null) {
          final nominal = (decoded['nominal'] ?? '').toString().trim();
          final reason = (decoded['reason'] ?? '').toString().trim();
          return CurrencyCheckResult(
            verdict: verdict,
            reasons: reason.isEmpty ? const <String>[] : <String>[reason],
            nominal: nominal.isEmpty ? null : nominal,
            source: 'vision_json',
          );
        }
      }
    } catch (_) {}

    final normalized = _normalize(trimmed);
    if (normalized.isEmpty) return null;
    final counterfeit = _counterfeitCues.any(normalized.contains);
    final authentic = _authenticCues.any(normalized.contains);
    if (counterfeit && !authentic) {
      return CurrencyCheckResult(
        verdict: CurrencyCheckVerdict.counterfeit,
        reasons: const <String>['visual_counterfeit_cue'],
        nominal: extractNominal(trimmed),
        source: 'vision_text',
      );
    }
    if (authentic && !counterfeit) {
      return CurrencyCheckResult(
        verdict: CurrencyCheckVerdict.authentic,
        reasons: const <String>['visual_authentic_cue'],
        nominal: extractNominal(trimmed),
        source: 'vision_text',
      );
    }
    return CurrencyCheckResult(
      verdict: CurrencyCheckVerdict.uncertain,
      reasons: const <String>['visual_ambiguous'],
      nominal: extractNominal(trimmed),
      source: 'vision_text',
    );
  }

  static CurrencyCheckVerdict? _parseVerdict(String raw) {
    switch (_normalize(raw)) {
      case 'authentic':
      case 'genuine':
        return CurrencyCheckVerdict.authentic;
      case 'counterfeit':
      case 'fake':
      case 'souvenir':
        return CurrencyCheckVerdict.counterfeit;
      case 'uncertain':
      case 'unknown':
      case 'inconclusive':
        return CurrencyCheckVerdict.uncertain;
    }
    return null;
  }

  static String _normalize(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
