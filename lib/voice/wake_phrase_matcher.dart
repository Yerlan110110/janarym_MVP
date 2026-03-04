import 'dart:math' as math;

enum WakeMatchStrength { none, weak, probable, strong }

class WakeMatchResult {
  const WakeMatchResult({
    required this.strength,
    required this.score,
    required this.normalized,
    required this.reason,
  });

  final WakeMatchStrength strength;
  final double score;
  final String normalized;
  final String reason;
}

class WakePhraseMatcher {
  static const List<String> _strongForms = <String>[
    'жанарым',
    'жан арым',
    'жан а рым',
    'janarym',
    'zhanarym',
    'zhan a rym',
    'zhan-a-rym',
  ];

  static const List<String> _acceptableForms = <String>[
    'жанарим',
    'жанарум',
    'жанар',
    'жанара',
    'жанарм',
    'жанрым',
    'janarim',
    'janarum',
    'janar',
    'zhanarim',
    'zhanarum',
    'zhanar',
  ];

  static WakeMatchResult match(String transcript, {bool isPartial = false}) {
    final normalized = _normalize(transcript);
    if (normalized.isEmpty) {
      return const WakeMatchResult(
        strength: WakeMatchStrength.none,
        score: 0,
        normalized: '',
        reason: 'empty',
      );
    }
    final compact = normalized.replaceAll(' ', '');
    for (final strong in _strongForms) {
      final strongNormalized = _normalize(strong);
      final strongCompact = strongNormalized.replaceAll(' ', '');
      if (normalized.contains(strongNormalized) ||
          compact.contains(strongCompact)) {
        return WakeMatchResult(
          strength: WakeMatchStrength.strong,
          score: 1,
          normalized: normalized,
          reason: 'strong_contains',
        );
      }
    }

    if (isPartial) {
      final tokens = normalized
          .split(' ')
          .where((token) => token.isNotEmpty)
          .toList(growable: false);
      if (tokens.length == 1) {
        final token = tokens.first;
        if (_isWakeRoot(token) && normalized.length <= 8) {
          return WakeMatchResult(
            strength: WakeMatchStrength.strong,
            score: 0.92,
            normalized: normalized,
            reason: 'partial_root',
          );
        }
      }
      return WakeMatchResult(
        strength: WakeMatchStrength.none,
        score: 0,
        normalized: normalized,
        reason: 'partial_no_match',
      );
    }

    if (_isProbable(normalized)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.probable,
        score: 0.72,
        normalized: normalized,
        reason: 'probable_match',
      );
    }

    if (_isWeak(normalized)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.weak,
        score: 0.45,
        normalized: normalized,
        reason: 'weak_match',
      );
    }

    return WakeMatchResult(
      strength: WakeMatchStrength.none,
      score: 0,
      normalized: normalized,
      reason: 'no_match',
    );
  }

  static bool _isProbable(String normalized) {
    final compact = normalized.replaceAll(' ', '');
    if (_isWakeRoot(compact)) {
      return true;
    }
    final tokens = normalized
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isNotEmpty && _isWakeRoot(tokens.first) && tokens.length <= 2) {
      final extra = tokens.length == 2 ? tokens.last : '';
      if (extra.isEmpty || extra.length <= 3) {
        return true;
      }
    }
    for (final form in <String>[..._strongForms, ..._acceptableForms]) {
      final formCompact = _normalize(form).replaceAll(' ', '');
      if (_levenshtein(compact, formCompact) <= 1) {
        return true;
      }
    }
    return false;
  }

  static bool _isWeak(String normalized) {
    final compact = normalized.replaceAll(' ', '');
    return compact.contains('жан') ||
        compact.contains('jan') ||
        compact.contains('zhan');
  }

  static bool _isWakeRoot(String token) {
    return token.startsWith('жанар') ||
        token.startsWith('janar') ||
        token.startsWith('zhanar');
  }

  static String _normalize(String input) {
    if (input.trim().isEmpty) return '';
    final lower = input.toLowerCase();
    final lookalike = lower
        .replaceAll('a', 'а')
        .replaceAll('o', 'о')
        .replaceAll('p', 'р')
        .replaceAll('c', 'с')
        .replaceAll('y', 'у')
        .replaceAll('x', 'х');
    final cleaned = lookalike
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      var current = i + 1;
      var diagonal = i;
      for (var j = 0; j < b.length; j++) {
        final insert = current + 1;
        final delete = previous[j + 1] + 1;
        final replace = diagonal + (a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1);
        diagonal = previous[j + 1];
        previous[j + 1] = current = math.min(math.min(insert, delete), replace);
      }
      previous[0] = i + 1;
    }
    return previous[b.length];
  }
}
