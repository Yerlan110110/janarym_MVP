enum DetectedTextScript { cyrillic, latin, mixed, unknown }

class TextReadingNormalizer {
  const TextReadingNormalizer._();

  static const Map<String, String> _latinToCyrillicLookalikes =
      <String, String>{
        'A': 'А',
        'a': 'а',
        'B': 'В',
        'C': 'С',
        'c': 'с',
        'E': 'Е',
        'e': 'е',
        'H': 'Н',
        'K': 'К',
        'k': 'к',
        'M': 'М',
        'O': 'О',
        'o': 'о',
        'P': 'Р',
        'p': 'р',
        'T': 'Т',
        'X': 'Х',
        'x': 'х',
        'Y': 'У',
        'y': 'у',
      };

  static const Map<String, String> _latinToCyrillicPhonetic = <String, String>{
    'a': 'а',
    'b': 'б',
    'c': 'к',
    'd': 'д',
    'e': 'е',
    'f': 'ф',
    'g': 'г',
    'h': 'х',
    'i': 'и',
    'j': 'й',
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
    'y': 'и',
    'z': 'з',
  };

  static const List<MapEntry<String, String>> _latinDigraphs =
      <MapEntry<String, String>>[
        MapEntry<String, String>('shch', 'щ'),
        MapEntry<String, String>('sch', 'щ'),
        MapEntry<String, String>('yo', 'ё'),
        MapEntry<String, String>('jo', 'ё'),
        MapEntry<String, String>('yu', 'ю'),
        MapEntry<String, String>('ju', 'ю'),
        MapEntry<String, String>('ya', 'я'),
        MapEntry<String, String>('ja', 'я'),
        MapEntry<String, String>('zh', 'ж'),
        MapEntry<String, String>('kh', 'х'),
        MapEntry<String, String>('ts', 'ц'),
        MapEntry<String, String>('ch', 'ч'),
        MapEntry<String, String>('sh', 'ш'),
      ];

  static final RegExp _cyrillicChar = RegExp(r'[А-Яа-яЁё]');
  static final RegExp _latinChar = RegExp(r'[A-Za-z]');
  static final RegExp _latinLookalikeChar = RegExp(
    r'[ABCEHKMOPTXYabcehkmoptyx]',
  );
  static final RegExp _tokenPattern = RegExp(r'([A-Za-zА-Яа-яЁё]+)');
  static final RegExp _latinOnlyToken = RegExp(r'^[A-Za-z]+$');
  static final RegExp _upperLatinToken = RegExp(r'^[A-Z]+$');
  static final RegExp _capitalizedLatinToken = RegExp(r'^[A-Z][a-z]+$');
  static final RegExp _latinWordToken = RegExp(r'[A-Za-z]{4,}');
  static final RegExp _pseudoRussianLatinWordToken = RegExp(r'[A-Za-z]{3,}');
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  static String normalizeForRussianSpeech(String rawText) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;

    return source.replaceAllMapped(_tokenPattern, (match) {
      final token = match.group(0) ?? '';
      return _normalizeTokenAggressive(token);
    });
  }

  static String normalizeCyrillicLookalikes(String rawText) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;

    return source.replaceAllMapped(_tokenPattern, (match) {
      final token = match.group(0) ?? '';
      return _normalizeTokenConservative(token);
    });
  }

  static String normalizeForManualSpeech(
    String rawText, {
    required DetectedTextScript script,
  }) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;

    final conservative = _collapseWhitespace(
      normalizeCyrillicLookalikes(source),
    );
    if (looksMostlyCyrillic(conservative)) {
      return conservative;
    }
    if (script == DetectedTextScript.latin) {
      return source;
    }
    return conservative;
  }

  static String normalizeForAutoSpeech(String rawText) {
    return _collapseWhitespace(normalizeCyrillicLookalikes(rawText));
  }

  static bool looksMostlyCyrillic(String text) {
    final source = text.trim();
    if (source.isEmpty) return false;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final latinCount = _countMatches(source, _latinChar);
    return cyrillicCount >= 2 && cyrillicCount >= latinCount;
  }

  static bool looksMostlyLatin(String text) {
    final source = text.trim();
    if (source.isEmpty) return false;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final latinCount = _countMatches(source, _latinChar);
    return latinCount >= 2 && latinCount > cyrillicCount;
  }

  static DetectedTextScript detectScript(String text) {
    final source = text.trim();
    if (source.isEmpty) return DetectedTextScript.unknown;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final latinCount = _countMatches(source, _latinChar);
    if (cyrillicCount == 0 && latinCount == 0) {
      return DetectedTextScript.unknown;
    }
    if (cyrillicCount == 0) return DetectedTextScript.latin;
    if (latinCount == 0) return DetectedTextScript.cyrillic;
    if (cyrillicCount >= latinCount * 2) {
      return DetectedTextScript.cyrillic;
    }
    if (latinCount >= cyrillicCount * 2) {
      return DetectedTextScript.latin;
    }
    return DetectedTextScript.mixed;
  }

  static bool looksLikeRussianishLatin(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 5) return false;

    final tail = token.substring(1);
    if (tail != tail.toLowerCase()) {
      return true;
    }

    final lower = token.toLowerCase();
    for (final pair in _latinDigraphs) {
      if (lower.contains(pair.key)) return true;
    }

    return lower.endsWith('tb') ||
        lower.endsWith('ctb') ||
        lower.endsWith('iy') ||
        lower.endsWith('yi');
  }

  static bool shouldUseEnglishTts(String text) {
    final source = _collapseWhitespace(text);
    if (source.isEmpty) return false;
    if (!looksMostlyLatin(source)) return false;

    final tokens = _latinWordToken
        .allMatches(source)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return false;

    final suspiciousCount = tokens.where(looksLikeRussianishLatin).length;
    if (tokens.length == 1) {
      return suspiciousCount == 0 && tokens.first.length >= 6;
    }

    return suspiciousCount * 2 < tokens.length;
  }

  static bool looksLikePseudoRussianOcr(String text) {
    final source = _collapseWhitespace(text);
    if (source.isEmpty) return false;

    final script = detectScript(source);
    if (script == DetectedTextScript.cyrillic ||
        script == DetectedTextScript.unknown) {
      return false;
    }
    if (shouldUseEnglishTts(source)) return false;

    final tokens = _pseudoRussianLatinWordToken
        .allMatches(source)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return false;

    final suspiciousCount = tokens.where(_looksPseudoRussianToken).length;
    if (suspiciousCount == 0) return false;
    if (suspiciousCount * 2 >= tokens.length) return true;

    final lookalikeChars = _countMatches(source, _latinLookalikeChar);
    return lookalikeChars >= 8 && tokens.length <= 3;
  }

  static String _normalizeTokenConservative(String token) {
    final cyrillicCount = _countMatches(token, _cyrillicChar);
    final latinLookalikeCount = _countMatches(token, _latinLookalikeChar);
    if (cyrillicCount > 0 && latinLookalikeCount > 0) {
      if (cyrillicCount < latinLookalikeCount) {
        return token;
      }
      return _convertLookalikes(token);
    }

    if (!_latinOnlyToken.hasMatch(token)) {
      return token;
    }

    if (_isMostlyLookalikeLatin(token)) {
      return _convertLookalikes(token);
    }

    return token;
  }

  static String _normalizeTokenAggressive(String token) {
    final cyrillicCount = _countMatches(token, _cyrillicChar);
    final latinLookalikeCount = _countMatches(token, _latinLookalikeChar);
    if (cyrillicCount > 0 && latinLookalikeCount > 0) {
      if (cyrillicCount < latinLookalikeCount) {
        return token;
      }
      return _convertLookalikes(token);
    }

    if (!_latinOnlyToken.hasMatch(token)) {
      return token;
    }

    if (_isMostlyLookalikeLatin(token)) {
      return _convertLookalikes(token);
    }

    if (_looksLikeRussianTransliteration(token)) {
      return _transliterateLatinToken(token);
    }

    return token;
  }

  static String _convertLookalikes(String token) {
    final buffer = StringBuffer();
    for (final rune in token.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_latinToCyrillicLookalikes[char] ?? char);
    }
    return buffer.toString();
  }

  static bool _isMostlyLookalikeLatin(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 2) return false;
    final latinCount = _countMatches(token, _latinChar);
    if (latinCount == 0) return false;
    final lookalikeCount = _countMatches(token, _latinLookalikeChar);
    return lookalikeCount == latinCount;
  }

  static bool _looksLikeRussianTransliteration(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 4) return false;

    final lower = token.toLowerCase();
    final latinCount = _countMatches(token, _latinChar);
    final lookalikeCount = _countMatches(token, _latinLookalikeChar);
    final lookalikeRatio = latinCount == 0
        ? 0
        : lookalikeCount * 100 ~/ latinCount;
    for (final pair in _latinDigraphs) {
      if (lower.contains(pair.key)) return true;
    }

    const russianishSuffixes = <String>[
      'iya',
      'ogo',
      'aya',
      'oe',
      'iy',
      'yi',
      'ka',
      'nik',
      'ov',
      'ev',
      'ina',
      'ova',
      'ski',
    ];
    for (final suffix in russianishSuffixes) {
      if (lower.endsWith(suffix)) return true;
    }

    if ((_upperLatinToken.hasMatch(token) ||
            _capitalizedLatinToken.hasMatch(token)) &&
        lookalikeCount >= 2 &&
        lookalikeRatio >= 75) {
      return true;
    }

    if (lookalikeRatio >= 80) {
      return true;
    }

    return false;
  }

  static String _transliterateLatinToken(String token) {
    final lower = token.toLowerCase();
    final buffer = StringBuffer();
    var index = 0;
    while (index < lower.length) {
      var matched = false;
      for (final pair in _latinDigraphs) {
        if (lower.startsWith(pair.key, index)) {
          buffer.write(pair.value);
          index += pair.key.length;
          matched = true;
          break;
        }
      }
      if (matched) continue;

      final char = lower[index];
      buffer.write(_latinToCyrillicPhonetic[char] ?? char);
      index += 1;
    }
    return _applyOriginalCasing(token, buffer.toString());
  }

  static String _applyOriginalCasing(String source, String converted) {
    if (source.isEmpty || converted.isEmpty) return converted;
    final isAllUpper = source == source.toUpperCase();
    if (isAllUpper) return converted.toUpperCase();
    final isCapitalized =
        source[0] == source[0].toUpperCase() &&
        source.substring(1) == source.substring(1).toLowerCase();
    if (!isCapitalized) return converted;
    return converted[0].toUpperCase() + converted.substring(1);
  }

  static String _collapseWhitespace(String text) {
    return text.replaceAll(_whitespacePattern, ' ').trim();
  }

  static int _countMatches(String text, RegExp pattern) {
    return pattern.allMatches(text).length;
  }

  static bool _looksPseudoRussianToken(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 3) return false;
    if (looksLikeRussianishLatin(token)) return true;

    final lower = token.toLowerCase();
    final lookalikeCount = _countMatches(token, _latinLookalikeChar);
    if (lookalikeCount * 2 >= token.length && token.length >= 4) {
      return true;
    }
    if (_upperLatinToken.hasMatch(token) && token.length >= 5) {
      return true;
    }
    if (RegExp(r'(?=.*[A-Z])(?=.*[a-z]).{5,}').hasMatch(token)) {
      return true;
    }

    return lower.endsWith('tb') ||
        lower.endsWith('tm') ||
        lower.contains('cei') ||
        lower.contains('npe') ||
        lower.contains('npu') ||
        lower.contains('ctb');
  }
}
