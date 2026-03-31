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
        'i': 'і',
      };

  static final RegExp _cyrillicChar = RegExp(r'[А-Яа-яЁё]');
  static final RegExp _latinChar = RegExp(r'[A-Za-z]');
  static final RegExp _latinLookalikeChar = RegExp(
    r'[ABCEHKMOPTXYabcehkmoptyxuniltі]',
  );
  static final RegExp _lookalikeOnlyLatinToken = RegExp(
    r'^[ABCEHKMOPTXYabcehkmoptyx]{5,}$',
  );
  static final RegExp _hardLookalikeLatinChar = RegExp(r'[CKMXPHckmxph]');
  static final RegExp _tokenPattern = RegExp(r'([A-Za-zА-Яа-яЁё]+)');
  static final RegExp _latinOnlyToken = RegExp(r'^[A-Za-z]+$');
  static final RegExp _upperLatinToken = RegExp(r'^[A-Z]+$');

  static final RegExp _pseudoRussianLatinWordToken = RegExp(r'[A-Za-z]{3,}');
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  static String normalizeForRussianSpeech(String rawText) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;
    return normalizeCyrillicLookalikes(source);
  }

  static String normalizeCyrillicLookalikes(String rawText) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;
    if (detectScript(source) == DetectedTextScript.latin &&
        shouldUseEnglishTts(source)) {
      return source;
    }

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

    if (script == DetectedTextScript.latin && shouldUseEnglishTts(source)) {
      return source;
    }

    return normalizeForRussianSpeech(source);
  }

  static String normalizeForAutoSpeech(String rawText) {
    return normalizeForRussianSpeech(rawText);
  }

  static bool looksMostlyCyrillic(String text) {
    final source = text.trim();
    if (source.isEmpty) return false;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final totalLetters = cyrillicCount + _countMatches(source, _latinChar);
    if (totalLetters == 0) return false;

    // Stronger bias towards Cyrillic: must be significant part
    return cyrillicCount >= 3 || (cyrillicCount / totalLetters) > 0.2;
  }

  static bool looksMostlyLatin(String text) {
    final source = text.trim();
    if (source.isEmpty) return false;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final latinCount = _countMatches(source, _latinChar);
    if (cyrillicCount + latinCount == 0) return false;

    return latinCount > cyrillicCount && cyrillicCount < 3;
  }

  static DetectedTextScript detectScript(String text) {
    final source = text.trim();
    if (source.isEmpty) return DetectedTextScript.unknown;
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final latinCount = _countMatches(source, _latinChar);
    final totalLetters = cyrillicCount + latinCount;

    if (totalLetters == 0) return DetectedTextScript.unknown;

    if (cyrillicCount > 0 && latinCount > 0) {
      if (cyrillicCount >= 4 && latinCount <= 1) {
        return DetectedTextScript.cyrillic;
      }
      if (latinCount >= 4 && cyrillicCount <= 1) {
        return DetectedTextScript.latin;
      }
      return DetectedTextScript.mixed;
    }

    if (cyrillicCount > 0) {
      return DetectedTextScript.cyrillic;
    }

    if (latinCount > 0) {
      return DetectedTextScript.latin;
    }
    return DetectedTextScript.unknown;
  }

  static bool looksLikeRussianishLatin(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 5) return false;

    final lower = token.toLowerCase();

    // sh, ch, ts, ya, jo are too common in English to be used as a veto here.
    // We only check for digraphs that are much more specific to RU translit.
    const ruTranslitDigraphs = {'shch', 'sch', 'zh', 'kh'};
    for (final pair in ruTranslitDigraphs) {
      if (lower.contains(pair)) return true;
    }

    return lower.endsWith('iy') ||
        lower.endsWith('yi') ||
        lower.endsWith('ogo') || // translit -ogo
        lower.endsWith('uyu') ||
        lower.endsWith('aya');
  }

  static bool isSpeechSafe(String text) {
    final source = _collapseWhitespace(text);
    if (source.isEmpty) return false;
    if (isLikelyEnglishText(source)) {
      return _isEnglishSpeechSafe(source);
    }

    final tokens = source
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return false;

    // Measurement detection (e.g. "100 кг")
    final hasMeasurement = RegExp(
      r'[0-9]+\s*[\u0430-\u044f\u0451a-z]+',
    ).hasMatch(source.toLowerCase());

    // Minimum length check
    if (!hasMeasurement && source.length < 3) return false;

    int safeTokens = 0;
    for (final token in tokens) {
      if (_isPhoneticallyPlausible(token)) {
        safeTokens++;
      }
    }

    // Strictness logic:
    // For 1-2 tokens, ALL must be safe.
    // For 3+ tokens, 80% must be safe.
    if (tokens.length <= 2) {
      if (safeTokens < tokens.length) return false;
    } else {
      if (safeTokens < tokens.length * 0.8) return false;
    }

    // Pattern: Repetitive short tokens (like "1 0 1 0" or "X X X")
    if (tokens.length >= 4) {
      int repeats = 0;
      for (int i = 0; i < tokens.length - 1; i++) {
        if (tokens[i].length <= 2 &&
            tokens[i].toLowerCase() == tokens[i + 1].toLowerCase()) {
          repeats++;
        }
      }
      if (repeats >= 2) return false;
    }

    return true;
  }

  static bool isLikelyEnglishText(String text) {
    final source = _collapseWhitespace(text);
    if (source.length < 2) return false;
    if (_countMatches(source, _cyrillicChar) != 0) return false;
    if (detectScript(source) != DetectedTextScript.latin) return false;

    final tokens = _pseudoRussianLatinWordToken
        .allMatches(source)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return false;

    final suspiciousCount = tokens.where(_isSuspiciousEnglishTtsToken).length;
    if (suspiciousCount > 0 && suspiciousCount * 2 >= tokens.length) {
      return false;
    }

    final englishLikeCount = tokens.where(_looksEnglishLikeToken).length;
    if (englishLikeCount == 0) return false;
    if (tokens.length <= 2) {
      return englishLikeCount == tokens.length;
    }
    return englishLikeCount * 10 >= tokens.length * 6;
  }

  static bool _isPhoneticallyPlausible(String token) {
    if (token.length < 2) {
      // Single chars are only safe if they are digits/measurements in a larger context
      // but here we evaluate token-by-token.
      return RegExp(r'[0-9а-яёA-Z]', caseSensitive: false).hasMatch(token);
    }

    // Numbers/symbols are safe if length >= 2
    if (RegExp(r'^[0-9\W]+$').hasMatch(token)) return true;

    final lower = token.toLowerCase();

    // 1. Vowel discovery
    final cyrillicVowelCount = _countMatches(
      lower,
      RegExp(r'[\u0430\u0435\u0451\u0438\u043e\u0443\u044b\u044d\u044e\u044f]'),
    );
    final latinVowelCount = _countMatches(lower, RegExp(r'[aeiouy]'));
    final totalVowelCount = cyrillicVowelCount + latinVowelCount;

    // Whitelist check for vowel-less abbreviations
    if (totalVowelCount == 0) {
      final whitelist = {
        '\u0441\u043c',
        '\u043a\u0433',
        '\u043c\u0433',
        '\u043c\u043b',
        '\u0442\u0433',
        'kzt',
        'dr',
        'mr',
        'mrs',
        'st',
        'rd',
        'th',
        'lb',
        'oz',
        'qt',
        'ft',
        '\u0442\u0431',
        '\u0433\u0431',
        '\u043c\u0431',
        '\u043a\u0431',
      };
      if (!whitelist.contains(lower)) return false;
    }

    // 2. Unnatural sequences
    // Too many vowels in a row (RU/EN)
    // Russian: 3 vowels in a row is basically impossible in real words (except rare ones)
    if (RegExp(
      r'[\u0430\u0435\u0451\u0438\u043e\u0443\u044b\u044d\u044e\u044f]{3,}',
    ).hasMatch(lower)) {
      return false;
    }
    if (RegExp(r'[aeiouy]{4,}').hasMatch(lower)) return false;

    // Too many consonants in a row (RU/EN)
    if (RegExp(
      r'[\u0431\u0432\u0433\u0434\u0436\u0437\u0439\u043a\u043b\u043c\u043d\u043f\u0440\u0441\u0442\u0444\u0445\u0446\u0447\u0448\u0449]{4,}',
    ).hasMatch(lower)) {
      return false;
    }
    if (RegExp(r'[bcdfghjklmnpqrstvwxz]{6,}').hasMatch(lower)) return false;

    // 3. Technical / OCR noise (All-caps strings without vowels or too long)
    final isAllUpper = token == token.toUpperCase() && token.length >= 3;
    if (isAllUpper) {
      // Only allow short common acronyms (3 letters) or whitelisted measurments
      if (token.length > 3 && totalVowelCount < 2) return false;
      if (totalVowelCount == 0) return false;
    }

    // 4. Mixed digits/letters (Entropy)
    if (token.length >= 3 &&
        RegExp(r'[0-9]').hasMatch(token) &&
        RegExp(r'[a-zA-Z]').hasMatch(token)) {
      if (!RegExp(r'^[0-9]+[a-z]{1,3}$').hasMatch(lower)) return false;
    }

    return true;
  }

  static bool _isEnglishSpeechSafe(String text) {
    final tokens = _pseudoRussianLatinWordToken
        .allMatches(text)
        .map((match) => match.group(0) ?? '')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) return false;

    final safeTokens = tokens.where(_looksEnglishLikeToken).length;
    if (tokens.length <= 2) {
      return safeTokens == tokens.length;
    }
    return safeTokens * 10 >= tokens.length * 7;
  }

  static bool shouldUseEnglishTts(String text) {
    final source = _collapseWhitespace(text);
    if (!isLikelyEnglishText(source)) return false;
    return _isEnglishSpeechSafe(source);
  }

  static bool looksLikePseudoRussianOcr(String text) {
    final source = _collapseWhitespace(text);
    if (source.isEmpty) return false;

    final script = detectScript(source);
    if (script == DetectedTextScript.cyrillic ||
        script == DetectedTextScript.unknown) {
      return false;
    }
    if (isLikelyEnglishText(source)) return false;

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

    if (cyrillicCount > 0) {
      // Mixed word (e.g. "Маmа") -> convert lookalikes to Cyrillic
      return _convertLookalikes(token);
    }

    // Pure Latin word. Is it phonetically English or just lookalikes?
    if (latinLookalikeCount > 0) {
      // Aggressive check: if it looks like a Russian word misread as Latin,
      // we convert EVERYTHING to Cyrillic to prevent spelling.
      if (!shouldUseEnglishTts(token)) {
        return _convertLookalikes(token);
      }
    }

    return token;
  }

  static String normalizeForTts(String text, {required bool useEnglishVoice}) {
    if (useEnglishVoice) return text;
    return normalizeForAutoSpeech(text);
  }

  static String _convertLookalikes(String token) {
    final buffer = StringBuffer();
    for (final rune in token.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(_latinToCyrillicLookalikes[char] ?? char);
    }
    return buffer.toString();
  }

  // Internal helper to replace lookalikes (only called for mixed tokens now)

  static String _collapseWhitespace(String text) {
    return text.replaceAll(_whitespacePattern, ' ').trim();
  }

  static int _countMatches(String text, RegExp pattern) {
    return pattern.allMatches(text).length;
  }

  static bool _looksPseudoRussianToken(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (token.length < 3) return false;
    if (_isSuspiciousEnglishTtsToken(token)) return true;

    final lookalikeCount = _countMatches(token, _latinLookalikeChar);
    if (lookalikeCount * 2 >= token.length && token.length >= 4) {
      return true;
    }
    if (_upperLatinToken.hasMatch(token) && token.length >= 5) {
      return true;
    }
    if (_hasWeirdMixedCase(token)) {
      return true;
    }

    return false;
  }

  static bool _isSuspiciousEnglishTtsToken(String token) {
    final lower = token.toLowerCase();
    if (looksLikeRussianishLatin(token)) return true;
    if (_lookalikeOnlyLatinToken.hasMatch(token) &&
        _countMatches(token, _hardLookalikeLatinChar) >= 2) {
      return true;
    }
    if (_hasWeirdMixedCase(token)) return true;
    return lower.endsWith('tb') ||
        lower.endsWith('tm') ||
        lower.contains('cei') ||
        lower.contains('npe') ||
        lower.contains('npu') ||
        lower.contains('ctb');
  }

  static bool _looksEnglishLikeToken(String token) {
    if (!_latinOnlyToken.hasMatch(token)) return false;
    if (_isSuspiciousEnglishTtsToken(token)) return false;

    final lower = token.toLowerCase();
    if (RegExp(r'^(.)\1{2,}$').hasMatch(lower)) return false;

    const shortWords = {
      'a',
      'an',
      'as',
      'at',
      'by',
      'do',
      'go',
      'he',
      'if',
      'in',
      'is',
      'it',
      'me',
      'my',
      'no',
      'of',
      'ok',
      'on',
      'or',
      'to',
      'up',
      'us',
      'we',
    };
    const noVowelWhitelist = {
      'dr',
      'mr',
      'mrs',
      'st',
      'rd',
      'th',
      'lb',
      'oz',
      'kg',
      'ui',
      'usb',
      'gps',
      'sms',
      'wifi',
      'gpt',
    };

    if (token.length <= 2) {
      return shortWords.contains(lower);
    }

    final vowelCount = _countMatches(lower, RegExp(r'[aeiouy]'));
    if (vowelCount == 0) {
      return noVowelWhitelist.contains(lower) ||
          (_upperLatinToken.hasMatch(token) && token.length <= 4);
    }

    if (RegExp(r'[bcdfghjklmnpqrstvwxz]{7,}').hasMatch(lower)) return false;

    return true;
  }

  static bool _hasWeirdMixedCase(String token) {
    if (token.length < 5) return false;
    if (!RegExp(r'(?=.*[A-Z])(?=.*[a-z])').hasMatch(token)) return false;
    if (RegExp(r'^[A-Z][a-z]+$').hasMatch(token)) return false;
    return true;
  }
}
