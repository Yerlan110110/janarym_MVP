import 'package:flutter/foundation.dart';

import '../l10n/app_locale_controller.dart';
import 'models/personalization_models.dart';
import 'personalization_repository.dart';

class OnboardingQuestion {
  const OnboardingQuestion({
    required this.id,
    required this.key,
    required this.ru,
    required this.kk,
  });

  final int id;
  final String key;
  final String ru;
  final String kk;
}

class PersonalizationController extends ChangeNotifier {
  PersonalizationController({required PersonalizationRepository repository})
    : _repository = repository;

  final PersonalizationRepository _repository;

  PersonalizationSnapshot _snapshot = PersonalizationSnapshot.initial(
    nowEpochMs: DateTime.now().millisecondsSinceEpoch,
  );

  bool _initialized = false;
  bool _onboardingActive = false;
  bool _onboardingPaused = false;

  bool get initialized => _initialized;
  bool get onboardingActive => _onboardingActive;
  bool get onboardingRequired => !_snapshot.onboardingCompleted;
  bool get onboardingPaused => _onboardingPaused;
  PersonalizationSnapshot get snapshot => _snapshot;
  int get onboardingStep =>
      _snapshot.profile.onboardingStep.clamp(0, _questions.length);
  int get totalOnboardingQuestions => _questions.length;

  OnboardingQuestion? get currentQuestion {
    if (!onboardingRequired) return null;
    final idx = onboardingStep;
    if (idx < 0 || idx >= _questions.length) return null;
    return _questions[idx];
  }

  String currentQuestionText(AppLanguage language) {
    final q = currentQuestion;
    if (q == null) return '';
    return language == AppLanguage.kk ? q.kk : q.ru;
  }

  Future<void> init() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var profile = await _repository.getProfile();
    profile ??= UserProfile.initial(nowEpochMs: now);
    await _repository.upsertProfile(profile);

    final fears = await _repository.getFears();
    final labels = await _repository.getPlaceLabels();
    final answers = await _repository.getAnswersMap();
    profile = _applyDerivedPreferences(profile, answers);

    _snapshot = PersonalizationSnapshot(
      profile: profile,
      fears: fears,
      placeLabels: labels,
      answers: answers,
    );
    _initialized = true;
    notifyListeners();
  }

  Future<void> startOrResumeOnboarding() async {
    _onboardingPaused = false;
    _onboardingActive = onboardingRequired;
    notifyListeners();
  }

  Future<void> restartOnboardingFromScratch() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = _snapshot.profile;
    final reset = UserProfile(
      id: current.id,
      displayName: '',
      responseLength: ResponseLength.medium,
      toneStyle: ToneStyle.warm,
      warningIntensity: 2,
      onboardingCompleted: false,
      onboardingStep: 0,
      confirmAddressBeforeRoute: true,
      preferSaferRoute: true,
      createdAtEpochMs: current.createdAtEpochMs == 0
          ? now
          : current.createdAtEpochMs,
      updatedAtEpochMs: now,
    );

    await _repository.upsertProfile(reset);
    await _repository.clearQuestionnaireAnswers();
    await _repository.clearOnboardingFears();
    await _reloadSnapshot();

    _onboardingPaused = false;
    _onboardingActive = true;
    notifyListeners();
  }

  void pauseOnboarding() {
    _onboardingPaused = true;
    _onboardingActive = false;
    notifyListeners();
  }

  Future<void> answerOnboardingQuestion(String answer) async {
    if (!onboardingRequired) return;
    final text = answer.trim();
    if (text.isEmpty) return;
    final question = currentQuestion;
    if (question == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final normalized = _normalizeQuestionValue(question.id, text);
    await _repository.saveQuestionAnswer(
      question.id,
      question.key,
      text,
      normalizedValue: normalized,
    );

    var profile = _snapshot.profile;
    profile = _applyProfileFromAnswer(
      profile,
      question.id,
      text,
      normalized,
      now,
    );
    final nextStep = (profile.onboardingStep + 1).clamp(0, _questions.length);
    profile = profile.copyWith(
      onboardingStep: nextStep,
      onboardingCompleted: nextStep >= _questions.length,
      updatedAtEpochMs: now,
    );
    await _repository.upsertProfile(profile);

    if (question.id == 6) {
      for (final fear in _extractFearTokens(text)) {
        await _repository.upsertFear(
          UserFear(
            fearKey: fear,
            customText: fear,
            source: 'onboarding',
            severity: profile.warningIntensity,
            updatedAtEpochMs: now,
          ),
        );
      }
    }

    await _reloadSnapshot();
    _onboardingActive = onboardingRequired && !_onboardingPaused;
    notifyListeners();
  }

  Future<void> updateFromDirectUserFact(String text) async {
    final normalized = normalizeText(text);
    if (normalized.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final fear = _extractFearFromFreeText(text);
    if (fear != null && fear.isNotEmpty) {
      await _repository.upsertFear(
        UserFear(
          fearKey: fear,
          customText: fear,
          source: 'voice',
          severity: _snapshot.profile.warningIntensity,
          updatedAtEpochMs: now,
        ),
      );
      await _reloadSnapshot();
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    await _reloadSnapshot();
    notifyListeners();
  }

  Future<void> _reloadSnapshot() async {
    final profile =
        await _repository.getProfile() ??
        UserProfile.initial(nowEpochMs: DateTime.now().millisecondsSinceEpoch);
    final fears = await _repository.getFears();
    final labels = await _repository.getPlaceLabels();
    final answers = await _repository.getAnswersMap();
    final derivedProfile = _applyDerivedPreferences(profile, answers);
    _snapshot = PersonalizationSnapshot(
      profile: derivedProfile,
      fears: fears,
      placeLabels: labels,
      answers: answers,
    );
  }

  UserProfile _applyDerivedPreferences(
    UserProfile profile,
    Map<int, String> answers,
  ) {
    var updated = profile;
    final routePreference = normalizeText(answers[8] ?? '');
    if (routePreference.isNotEmpty) {
      final safer =
          routePreference.contains('безопас') ||
          routePreference.contains('қауіп');
      final shorter =
          routePreference.contains('короч') || routePreference.contains('қысқ');
      if (safer || shorter) {
        updated = updated.copyWith(preferSaferRoute: safer);
      }
    }

    final confirm = normalizeText(answers[9] ?? '');
    if (confirm.isNotEmpty) {
      updated = updated.copyWith(
        confirmAddressBeforeRoute: !_isNegative(confirm),
      );
    }
    return updated;
  }

  String? _extractFearFromFreeText(String text) {
    final normalized = normalizeText(text);
    final fearMarkers = [
      'я боюсь',
      'мне страшно',
      'боюсь',
      'страшно',
      'мен коркамын',
      'коркамын',
      'мне тревожно',
      'мазасызданамын',
    ];
    var found = false;
    for (final marker in fearMarkers) {
      if (normalized.contains(marker)) {
        found = true;
        break;
      }
    }
    if (!found) return null;
    var value = normalized;
    for (final marker in fearMarkers) {
      value = value.replaceFirst(marker, '').trim();
    }
    if (value.isEmpty) return null;
    return value;
  }

  UserProfile _applyProfileFromAnswer(
    UserProfile profile,
    int questionId,
    String raw,
    String normalized,
    int now,
  ) {
    switch (questionId) {
      case 1:
        return profile.copyWith(displayName: raw.trim(), updatedAtEpochMs: now);
      case 3:
        return profile.copyWith(
          responseLength: _responseLengthFromAnswer(normalized),
          updatedAtEpochMs: now,
        );
      case 4:
        return profile.copyWith(
          toneStyle: _toneStyleFromAnswer(normalized),
          updatedAtEpochMs: now,
        );
      case 5:
        return profile.copyWith(
          warningIntensity: _warningIntensityFromAnswer(normalized),
          updatedAtEpochMs: now,
        );
      case 8:
        return profile.copyWith(
          preferSaferRoute:
              normalized.contains('безопас') || normalized.contains('қауіп'),
          updatedAtEpochMs: now,
        );
      case 9:
        return profile.copyWith(
          confirmAddressBeforeRoute: !_isNegative(normalized),
          updatedAtEpochMs: now,
        );
      default:
        return profile.copyWith(updatedAtEpochMs: now);
    }
  }

  String _normalizeQuestionValue(int questionId, String answer) {
    final normalized = normalizeText(answer);
    switch (questionId) {
      case 3:
        return _responseLengthFromAnswer(normalized).storageValue;
      case 4:
        return _toneStyleFromAnswer(normalized).storageValue;
      case 5:
        return _warningIntensityFromAnswer(normalized).toString();
      case 9:
        return _isNegative(normalized) ? 'no' : 'yes';
      default:
        return normalized;
    }
  }

  ResponseLength _responseLengthFromAnswer(String normalized) {
    if (normalized.contains('корот') ||
        normalized.contains('кыска') ||
        normalized.contains('қысқа')) {
      return ResponseLength.short;
    }
    if (normalized.contains('подроб') ||
        normalized.contains('толык') ||
        normalized.contains('толық')) {
      return ResponseLength.detailed;
    }
    return ResponseLength.medium;
  }

  ToneStyle _toneStyleFromAnswer(String normalized) {
    if (normalized.contains('нейтр') || normalized.contains('бейтарап')) {
      return ToneStyle.neutral;
    }
    if (normalized.contains('прям') || normalized.contains('тік')) {
      return ToneStyle.direct;
    }
    return ToneStyle.warm;
  }

  int _warningIntensityFromAnswer(String normalized) {
    if (normalized.contains('максим') ||
        normalized.contains('макс') ||
        normalized.contains('maximum')) {
      return 3;
    }
    if (normalized.contains('чаще') ||
        normalized.contains('жиі') ||
        normalized.contains('жиi')) {
      return 3;
    }
    if (normalized.contains('обыч') || normalized.contains('әдет')) {
      return 2;
    }
    return 2;
  }

  bool _isNegative(String normalized) {
    return normalized == 'нет' ||
        normalized.startsWith('нет ') ||
        normalized == 'жок' ||
        normalized.startsWith('жок ') ||
        normalized.contains('қажет емес') ||
        normalized.contains('не надо');
  }

  List<String> _extractFearTokens(String text) {
    final normalized = normalizeText(text);
    if (normalized.isEmpty) return const [];
    final tokens = normalized
        .split(RegExp(r'[,;]| и | және | мен | with '))
        .map((part) => part.trim())
        .where((part) => part.length > 2)
        .toList(growable: false);
    if (tokens.isEmpty) return [normalized];
    return tokens;
  }
}

const List<OnboardingQuestion> _questions = [
  OnboardingQuestion(
    id: 1,
    key: 'display_name',
    ru: '1 из 10. Как к вам обращаться?',
    kk: '1/10. Сізге қалай жүгінейін?',
  ),
  OnboardingQuestion(
    id: 2,
    key: 'default_language',
    ru: '2 из 10. На каком языке отвечать по умолчанию: русский или казахский?',
    kk: '2/10. Әдепкі тіл: орыс па, қазақ па?',
  ),
  OnboardingQuestion(
    id: 3,
    key: 'response_length',
    ru: '3 из 10. Формат ответов: коротко, средне или подробно?',
    kk: '3/10. Жауап ұзақтығы: қысқа, орташа, әлде толық па?',
  ),
  OnboardingQuestion(
    id: 4,
    key: 'tone_style',
    ru: '4 из 10. Тон общения: нейтральный, тёплый или более прямой?',
    kk: '4/10. Сөйлесу тоны: бейтарап, жылы, әлде тік пе?',
  ),
  OnboardingQuestion(
    id: 5,
    key: 'warning_intensity',
    ru: '5 из 10. Нужны предупреждения обычно, чаще или максимум?',
    kk: '5/10. Ескертулер: әдеттегідей, жиірек, әлде максимум па?',
  ),
  OnboardingQuestion(
    id: 6,
    key: 'fears',
    ru: '6 из 10. Чего вы боитесь на улице больше всего?',
    kk: '6/10. Көшеде неден көбірек қорқасыз?',
  ),
  OnboardingQuestion(
    id: 7,
    key: 'complex_segments_warning',
    ru: '7 из 10. Предупреждать заранее о сложных участках? Да или нет.',
    kk: '7/10. Күрделі жерлер туралы алдын ала ескерту керек пе? Иә немесе жоқ.',
  ),
  OnboardingQuestion(
    id: 8,
    key: 'route_preference',
    ru: '8 из 10. Предпочитаете безопаснее или короче?',
    kk: '8/10. Қауіпсіздеу ме, әлде қысқалау маршрут па?',
  ),
  OnboardingQuestion(
    id: 9,
    key: 'confirm_address_before_route',
    ru: '9 из 10. Нужны подтверждения адреса перед стартом маршрута? Да или нет.',
    kk: '9/10. Маршрут алдында мекенжайды растау керек пе? Иә немесе жоқ.',
  ),
  OnboardingQuestion(
    id: 10,
    key: 'set_home_label',
    ru: '10 из 10. Хотите сразу установить метку дом? Можно ответить: да позже.',
    kk: '10/10. Үй меткасын қазір орнатқыңыз келе ме? Мысалы: иә, кейін.',
  ),
];
