enum DetectedTextScript { cyrillic, latin, mixed, unknown }

class TextReadingNormalizer {
  const TextReadingNormalizer._();

  static const Map<String, String> _latinToCyrillicLookalikes =
      <String, String>{
        'A': 'А', 'a': 'а',
        'B': 'В',
        'C': 'С', 'c': 'с',
        'E': 'Е', 'e': 'е',
        'H': 'Н',
        'K': 'К', 'k': 'к',
        'M': 'М',
        'O': 'О', 'o': 'о',
        'P': 'Р', 'p': 'р',
        'T': 'Т',
        'X': 'Х', 'x': 'х',
        'Y': 'У', 'y': 'у',
        'i': 'і',
      };

  static const Map<String, String> _latinToCyrillicPhonetic =
      <String, String>{
    's': 'с', 'S': 'С',
    'r': 'р', 'R': 'Р',
    'z': 'з', 'Z': 'З',
    'd': 'д', 'D': 'Д',
    'f': 'ф', 'F': 'Ф',
    'g': 'г', 'G': 'Г',
    'h': 'х',
    'j': 'й', 'J': 'Й',
    'q': 'к', 'Q': 'К',
    'w': 'в', 'W': 'В',
    'v': 'в', 'V': 'В',
    'u': 'и', // visual/sound mix
    'n': 'н',
    'l': 'л', 'L': 'Л',
    'b': 'б', 'B': 'Б',
    'k': 'к', 'K': 'К',
    'p': 'п', 'P': 'П',
    't': 'т', 'T': 'Т',
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
    r'[ABCEHKMOPTXYabcehkmoptyxuniltі]',
  );
  static final RegExp _tokenPattern = RegExp(r'([A-Za-zА-Яа-яЁё]+)');
  static final RegExp _latinOnlyToken = RegExp(r'^[A-Za-z]+$');
  static final RegExp _upperLatinToken = RegExp(r'^[A-Z]+$');

  static final RegExp _pseudoRussianLatinWordToken = RegExp(r'[A-Za-z]{3,}');
  static final RegExp _whitespacePattern = RegExp(r'\s+');

  static String normalizeForRussianSpeech(String rawText) {
    final source = _collapseWhitespace(rawText);
    if (source.isEmpty) return source;

    // First: Normalize known lookalikes
    final lookaliveNormalized = normalizeCyrillicLookalikes(source);
    
    // Second: Aggressively map any REMAINING Latin to Russian sound-alikes
    // to prevent the Russian engine from spelling out individual letters.
    final buffer = StringBuffer();
    for (final rune in lookaliveNormalized.runes) {
      final char = String.fromCharCode(rune);
      if (_latinChar.hasMatch(char)) {
        // Fallback chain: phonetic -> lookalike -> original
        final mapped = _latinToCyrillicPhonetic[char] ?? 
                       _latinToCyrillicLookalikes[char] ?? 
                       char;
        buffer.write(mapped);
      } else {
        buffer.write(char);
      }
    }
    return _collapseWhitespace(buffer.toString());
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

    final useEnglish = shouldUseEnglishTts(source);
    if (useEnglish) return source;

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
    
    // Require at least 4 chars or 20% Cyrillic to consider it Russian context
    if (cyrillicCount >= 4 || (cyrillicCount / totalLetters) >= 0.2) {
      return DetectedTextScript.cyrillic;
    }
    
    if (latinCount > 0) return DetectedTextScript.latin;
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

  static const String _cyrillicVowels = 'аеёиоуыэюя';
  static const String _latinVowels = 'aeiouy';

  static bool isSpeechSafe(String text) {
    final source = _collapseWhitespace(text);
    if (source.isEmpty) return false;

    final tokens = source.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return false;

    // Measurement detection (e.g. "100 кг")
    final hasMeasurement = RegExp(r'[0-9]+\s*[\u0430-\u044f\u0451a-z]+').hasMatch(source.toLowerCase());
    
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
         if (tokens[i].length <= 2 && tokens[i].toLowerCase() == tokens[i+1].toLowerCase()) {
           repeats++;
         }
      }
      if (repeats >= 2) return false;
    }

    return true;
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
    final cyrillicVowelCount = _countMatches(lower, RegExp(r'[\u0430\u0435\u0451\u0438\u043e\u0443\u044b\u044d\u044e\u044f]'));
    final latinVowelCount = _countMatches(lower, RegExp(r'[aeiouy]'));
    final totalVowelCount = cyrillicVowelCount + latinVowelCount;

    // Whitelist check for vowel-less abbreviations
    if (totalVowelCount == 0) {
      final whitelist = {
        '\u0441\u043c', '\u043a\u0433', '\u043c\u0433', '\u043c\u043b', '\u0442\u0433',
        'kzt', 'dr', 'mr', 'mrs', 'st', 'rd', 'th', 'lb', 'oz', 'qt', 'ft',
        '\u0442\u0431', '\u0433\u0431', '\u043c\u0431', '\u043a\u0431',
      };
      if (!whitelist.contains(lower)) return false;
    }

    // 2. Unnatural sequences
    // Too many vowels in a row (RU/EN)
    // Russian: 3 vowels in a row is basically impossible in real words (except rare ones)
    if (RegExp(r'[\u0430\u0435\u0451\u0438\u043e\u0443\u044b\u044d\u044e\u044f]{3,}').hasMatch(lower)) return false;
    if (RegExp(r'[aeiouy]{4,}').hasMatch(lower)) return false;
    
    // Too many consonants in a row (RU/EN)
    if (RegExp(r'[\u0431\u0432\u0433\u0434\u0436\u0437\u0439\u043a\u043b\u043c\u043d\u043f\u0440\u0441\u0442\u0444\u0445\u0446\u0447\u0448\u0449]{4,}').hasMatch(lower)) return false;
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

  static bool shouldUseEnglishTts(String text) {
    final source = _collapseWhitespace(text);
    if (source.length < 2) return false;
    
    final cyrillicCount = _countMatches(source, _cyrillicChar);
    final totalLetters = cyrillicCount + _countMatches(source, _latinChar);

    // Veto English mode ONLY if there is significant Cyrillic presence.
    // This prevents a single misread letter (like l -> л) from forcing RU mode.
    if (cyrillicCount >= 4 || (totalLetters > 0 && (cyrillicCount / totalLetters) >= 0.20)) {
      return false;
    }

    final lower = source.toLowerCase();
    final latinCount = _countMatches(source, _latinChar);
    if (latinCount == 0) return false;

    // Reject nonsense like "ZZZ" or "LLLL"
    if (!isSpeechSafe(source)) return false;

    // Phonetic density check: English words must have vowels
    final vowelCount = _countMatches(lower, RegExp('[aeiouy]'));
    if (vowelCount == 0 && source.length >= 3) {
      // Small whitelist for English vowel-less abbreviations
      final whitelist = {'dr', 'mr', 'mrs', 'st', 'rd', 'th', 'lb', 'kg'};
      if (!whitelist.contains(lower)) return false;
    }

    return true;
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

  static String _normalizeTokenAggressive(String token) {
    return _convertLookalikes(token);
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
