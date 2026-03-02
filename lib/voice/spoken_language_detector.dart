import '../l10n/app_locale_controller.dart';

enum SpokenLanguageConfidence { low, medium, high }

class SpokenLanguageDetectionResult {
  const SpokenLanguageDetectionResult({
    required this.language,
    required this.confidence,
    required this.reason,
    this.explicitSwitch = false,
  });

  final AppLanguage language;
  final SpokenLanguageConfidence confidence;
  final String reason;
  final bool explicitSwitch;
}

class SpokenLanguageDetector {
  static const Set<String> _kazakhLetters = {
    'ә',
    'і',
    'ң',
    'ғ',
    'ү',
    'ұ',
    'қ',
    'ө',
    'һ',
  };

  static const Map<String, int> _kazakhLexicon = {
    'иә': 3,
    'ия': 3,
    'жоқ': 3,
    'жок': 3,
    'қайда': 2,
    'қалай': 2,
    'керек': 1,
    'жүр': 1,
    'апар': 3,
    'оқы': 3,
    'қайта': 2,
    'тоқта': 3,
    'жалғастыр': 3,
    'жалгастыр': 3,
    'мәтін': 3,
    'мәтінді': 3,
    'дауыс': 2,
    'таб': 2,
    'үйге': 3,
    'дүкен': 2,
    'бағыт': 3,
    'багыт': 3,
    'көрсет': 2,
    'корсет': 2,
    'қос': 2,
    'өшір': 2,
    'сипаттап': 3,
    'түс': 2,
    'түсі': 2,
    'көріп': 2,
    'тұрсың': 2,
    'жауап': 2,
    'сөйле': 3,
    'орысша': 3,
    'қазақша': 4,
    'қазақ': 3,
    'тілінде': 3,
    'келесі': 2,
    'қадам': 2,
    'маршрутты': 3,
    'есте': 2,
    'сақтау': 2,
    'алаяқтық': 2,
    'сатып': 2,
    'алу': 1,
    'дайындау': 2,
    'қалыпты': 2,
    'көмек': 2,
    'баста': 2,
  };

  static const Map<String, int> _russianLexicon = {
    'да': 2,
    'нет': 2,
    'где': 2,
    'как': 1,
    'нужно': 1,
    'останови': 3,
    'прочитай': 3,
    'продолжай': 3,
    'домой': 3,
    'маршрут': 3,
    'покажи': 2,
    'включи': 2,
    'выключи': 2,
    'найди': 2,
    'режим': 2,
    'что': 1,
    'видишь': 2,
    'сцена': 1,
    'по-казахски': 4,
    'на': 0,
    'казахском': 3,
    'по-русски': 4,
    'русском': 3,
    'ответь': 2,
    'ответ': 1,
    'говори': 2,
    'помоги': 1,
    'читай': 3,
    'повтори': 2,
    'дальше': 2,
    'следующий': 2,
    'память': 2,
    'покупки': 2,
    'готовка': 2,
    'дрескод': 2,
  };

  static const List<String> _explicitKazakhSwitches = [
    'қазақша',
    'қазақша сөйле',
    'қазақша жауап бер',
    'қазақ тілінде',
    'қазақ тілінде жауап бер',
    'по казахски',
    'по-казахски',
    'на казахском',
  ];

  static const List<String> _explicitRussianSwitches = [
    'орысша',
    'орысша сөйле',
    'по русски',
    'по-русски',
    'на русском',
  ];

  static SpokenLanguageDetectionResult detect(
    String transcript, {
    required AppLanguage fallbackLanguage,
  }) {
    final normalized = _normalize(transcript);
    if (normalized.isEmpty) {
      return SpokenLanguageDetectionResult(
        language: fallbackLanguage,
        confidence: SpokenLanguageConfidence.low,
        reason: 'empty',
      );
    }

    if (_explicitKazakhSwitches.any(normalized.contains)) {
      return const SpokenLanguageDetectionResult(
        language: AppLanguage.kk,
        confidence: SpokenLanguageConfidence.high,
        reason: 'explicit_switch_kk',
        explicitSwitch: true,
      );
    }
    if (_explicitRussianSwitches.any(normalized.contains)) {
      return const SpokenLanguageDetectionResult(
        language: AppLanguage.ru,
        confidence: SpokenLanguageConfidence.high,
        reason: 'explicit_switch_ru',
        explicitSwitch: true,
      );
    }

    if (normalized.split('').any(_kazakhLetters.contains)) {
      return const SpokenLanguageDetectionResult(
        language: AppLanguage.kk,
        confidence: SpokenLanguageConfidence.high,
        reason: 'kazakh_letters',
      );
    }

    final tokens = normalized
        .split(' ')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);

    var kkScore = 0;
    var ruScore = 0;
    for (final token in tokens) {
      kkScore += _kazakhLexicon[token] ?? 0;
      ruScore += _russianLexicon[token] ?? 0;
    }

    if (kkScore == 0 && ruScore == 0) {
      return SpokenLanguageDetectionResult(
        language: fallbackLanguage,
        confidence: SpokenLanguageConfidence.low,
        reason: 'fallback',
      );
    }

    final diff = kkScore - ruScore;
    if (diff >= 3 || kkScore >= 5 && ruScore == 0) {
      return SpokenLanguageDetectionResult(
        language: AppLanguage.kk,
        confidence: SpokenLanguageConfidence.high,
        reason: 'lexicon_score_kk($kkScore:$ruScore)',
      );
    }
    if (diff <= -3 || ruScore >= 5 && kkScore == 0) {
      return SpokenLanguageDetectionResult(
        language: AppLanguage.ru,
        confidence: SpokenLanguageConfidence.high,
        reason: 'lexicon_score_ru($kkScore:$ruScore)',
      );
    }
    if (diff > 0) {
      return SpokenLanguageDetectionResult(
        language: AppLanguage.kk,
        confidence: SpokenLanguageConfidence.medium,
        reason: 'lexicon_edge_kk($kkScore:$ruScore)',
      );
    }
    if (diff < 0) {
      return SpokenLanguageDetectionResult(
        language: AppLanguage.ru,
        confidence: SpokenLanguageConfidence.medium,
        reason: 'lexicon_edge_ru($kkScore:$ruScore)',
      );
    }

    return SpokenLanguageDetectionResult(
      language: fallbackLanguage,
      confidence: SpokenLanguageConfidence.low,
      reason: 'balanced($kkScore:$ruScore)',
    );
  }

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r'[\n\r]'), ' ')
        .replaceAll(RegExp(r'[.,!?;:"()\\[\\]{}<>«»]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
