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
  static const String _canonicalWakeRoot = 'жанар';
  static const int _minWakeLength = 5;
  static const int _maxWakeLength = 8;

  static const List<String> _strongForms = <String>[
    'жанарым',
    'жанарим',
    'жанарум',
    'жанар',
    'жанара',
    'janarym',
    'janarim',
    'janarum',
    'janar',
    'janara',
    'zhanarym',
    'zhanarim',
    'zhanarum',
    'zhanar',
    'zhanara',
  ];

  static const List<String> _acceptableForms = <String>[
    'жан арым',
    'жан а рым',
    'жана рым',
    'жана рим',
    'жана рум',
    'женарым',
    'женарим',
    'женарум',
    'женар',
    'женара',
    'джанарым',
    'джанарим',
    'джанарум',
    'джанар',
    'джанара',
    'жанарэм',
    'женарэм',
    'джанарэм',
    'жанарм',
    'жанрым',
    'janary',
    'zhanary',
    'zhan a rym',
    'zhan-a-rym',
    'djanarym',
    'djanarim',
    'djanarum',
    'djanar',
  ];

  static final List<String> _wakeLookupForms = _buildWakeLookupForms();
  static final Set<String> _strongNormalizedForms = _buildNormalizedSet(
    _strongForms,
  );
  static final Set<String> _acceptedNormalizedForms = _buildNormalizedSet(
    <String>[..._strongForms, ..._acceptableForms],
  );
  static final Set<String> _acceptedPhoneticForms = _buildPhoneticSet(<String>[
    ..._strongForms,
    ..._acceptableForms,
  ]);
  static const List<String> _canonicalFullForms = <String>[
    'жанар',
    'жанара',
    'жанарым',
  ];

  static List<String> get wakeLookupForms =>
      List<String>.unmodifiable(_wakeLookupForms);

  static bool isAccepted(WakeMatchResult result) {
    return result.strength == WakeMatchStrength.strong ||
        result.strength == WakeMatchStrength.probable;
  }

  static bool containsAcceptedWakeWord(
    String transcript, {
    bool isPartial = false,
  }) {
    return isAccepted(match(transcript, isPartial: isPartial));
  }

  static String stripWakeWords(String input) {
    final normalized = _normalize(input);
    if (normalized.isEmpty) return '';
    final tokens = normalized
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return '';

    final kept = <String>[];
    var index = 0;
    while (index < tokens.length) {
      var consumed = 0;
      final maxWindow = math.min(3, tokens.length - index);
      for (var window = maxWindow; window >= 1; window--) {
        final candidate = tokens.sublist(index, index + window).join(' ');
        if (_isStandaloneAccepted(candidate)) {
          consumed = window;
          break;
        }
      }
      if (consumed > 0) {
        index += consumed;
        continue;
      }
      kept.add(tokens[index]);
      index += 1;
    }
    return kept.join(' ');
  }

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

    final direct = _matchStandalone(normalized, isPartial: isPartial);
    if (direct.strength == WakeMatchStrength.strong ||
        direct.strength == WakeMatchStrength.probable) {
      return direct;
    }

    final tokens = normalized
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    WakeMatchResult? bestWeak;
    WakeMatchResult? bestProbable;

    for (var start = 0; start < tokens.length; start++) {
      final maxWindow = math.min(3, tokens.length - start);
      for (var window = maxWindow; window >= 1; window--) {
        final candidate = tokens.sublist(start, start + window).join(' ');
        final result = _matchStandalone(candidate, isPartial: isPartial);
        if (result.strength == WakeMatchStrength.strong) {
          return result;
        }
        if (result.strength == WakeMatchStrength.probable) {
          if (bestProbable == null || result.score > bestProbable.score) {
            bestProbable = result;
          }
          continue;
        }
        if (result.strength == WakeMatchStrength.weak && bestWeak == null) {
          bestWeak = result;
        }
      }
    }

    if (bestProbable != null) {
      return bestProbable;
    }
    if (bestWeak != null) {
      return bestWeak;
    }
    if (direct.strength == WakeMatchStrength.weak) {
      return direct;
    }

    return WakeMatchResult(
      strength: WakeMatchStrength.none,
      score: 0,
      normalized: normalized,
      reason: isPartial ? 'partial_no_match' : 'no_match',
    );
  }

  static WakeMatchResult _matchStandalone(
    String transcript, {
    required bool isPartial,
  }) {
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
    final phonetic = _normalizePhonetic(compact);
    if (compact.isEmpty || phonetic.isEmpty) {
      return WakeMatchResult(
        strength: WakeMatchStrength.none,
        score: 0,
        normalized: normalized,
        reason: 'empty',
      );
    }

    if (_strongNormalizedForms.contains(normalized)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.strong,
        score: 1,
        normalized: normalized,
        reason: 'surface_strong',
      );
    }
    if (_acceptedNormalizedForms.contains(normalized) ||
        _acceptedPhoneticForms.contains(phonetic)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.strong,
        score: 0.98,
        normalized: normalized,
        reason: 'surface_accept',
      );
    }

    if (isPartial && _isCanonicalWakeShape(phonetic)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.strong,
        score: 0.92,
        normalized: normalized,
        reason: 'partial_root',
      );
    }
    if (_isCanonicalWakeShape(phonetic)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.probable,
        score: 0.86,
        normalized: normalized,
        reason: 'root_canonical',
      );
    }
    if (_isNearCanonicalWakeShape(phonetic)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.probable,
        score: 0.76,
        normalized: normalized,
        reason: 'edit_distance',
      );
    }
    if (_isWeakWakeHint(phonetic)) {
      return WakeMatchResult(
        strength: WakeMatchStrength.weak,
        score: 0.42,
        normalized: normalized,
        reason: isPartial ? 'partial_weak' : 'weak_root',
      );
    }

    return WakeMatchResult(
      strength: WakeMatchStrength.none,
      score: 0,
      normalized: normalized,
      reason: isPartial ? 'partial_no_match' : 'no_match',
    );
  }

  static bool _isStandaloneAccepted(String transcript) {
    return isAccepted(_matchStandalone(transcript, isPartial: false));
  }

  static bool _isCanonicalWakeShape(String phonetic) {
    return phonetic.startsWith(_canonicalWakeRoot) &&
        phonetic.length >= _minWakeLength &&
        phonetic.length <= _maxWakeLength;
  }

  static String _normalize(String input) {
    if (input.trim().isEmpty) return '';
    final lower = input.toLowerCase();
    return lower
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _normalizePhonetic(String input) {
    if (input.trim().isEmpty) return '';
    var value = _normalize(input).replaceAll(' ', '');
    if (value.isEmpty) return '';

    value = value
        .replaceAll('ё', 'е')
        .replaceAll('э', 'е')
        .replaceAll('dzh', 'дж')
        .replaceAll('zh', 'ж');

    const latinMap = <String, String>{
      'a': 'а',
      'b': 'б',
      'c': 'к',
      'd': 'д',
      'e': 'е',
      'f': 'ф',
      'g': 'г',
      'h': 'х',
      'i': 'и',
      'j': 'ж',
      'k': 'к',
      'l': 'л',
      'm': 'м',
      'n': 'н',
      'o': 'о',
      'p': 'п',
      'q': 'к',
      'r': 'р',
      's': 'с',
      't': 'т',
      'u': 'у',
      'v': 'в',
      'w': 'в',
      'x': 'кс',
      'y': 'ы',
      'z': 'з',
    };

    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(latinMap[char] ?? char);
    }
    value = buffer.toString();

    value = value
        .replaceFirst(RegExp(r'^джан'), 'жан')
        .replaceFirst(RegExp(r'^зхан'), 'жан')
        .replaceFirst(RegExp(r'^женар'), 'жанар')
        .replaceFirst(RegExp(r'^жанар[иеуы]м$'), 'жанарым');

    return value;
  }

  static bool _isNearCanonicalWakeShape(String phonetic) {
    if (phonetic.length < 4 || phonetic.length > (_maxWakeLength + 1)) {
      return false;
    }
    if (!_hasWakeStemHint(phonetic)) {
      return false;
    }
    for (final form in _canonicalFullForms) {
      if (_levenshtein(phonetic, form) <= 2) {
        return true;
      }
    }
    return false;
  }

  static bool _hasWakeStemHint(String phonetic) {
    return phonetic.startsWith('жан') && phonetic.contains('р');
  }

  static bool _isWeakWakeHint(String phonetic) {
    return phonetic.startsWith('жан');
  }

  static List<String> _buildWakeLookupForms() {
    final forms = <String>{
      ..._buildNormalizedSet(_strongForms),
      ..._buildNormalizedSet(_acceptableForms),
    }.toList(growable: false);
    forms.sort((a, b) => b.length.compareTo(a.length));
    return forms;
  }

  static Set<String> _buildNormalizedSet(List<String> values) {
    return values.map(_normalize).where((value) => value.isNotEmpty).toSet();
  }

  static Set<String> _buildPhoneticSet(List<String> values) {
    return values
        .map(
          (value) => _normalizePhonetic(_normalize(value).replaceAll(' ', '')),
        )
        .where((value) => value.isNotEmpty)
        .toSet();
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
