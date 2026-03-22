import '../l10n/app_locale_controller.dart';
import '../navigation/models/navigation_mode_state.dart';
import '../voice/wake_phrase_matcher.dart';

enum AssistantModeIntent {
  enterNavMode,
  exitNavMode,
  enterBusMode,
  exitBusMode,
  navStart,
  busStopRoutes,
  busStopSchedule,
  routeToPlaceLabel,
  setPlaceLabel,
  startOnboarding,
  restartOnboarding,
  updateUserFear,
  confirmYes,
  confirmNo,
  navStop,
  navStatus,
  navNextStep,
  navRejectChoice,
  visionDescribe,
  repeat,
  readText,
  switchVoiceLanguage,
  unknown,
}

class CommandDecision {
  final String cleanedText;
  final AssistantModeIntent modeIntent;
  final String? directionRu;
  final String? destinationQuery;
  final int? candidateChoiceIndex;
  final String? placeLabelName;
  final String? freeAddressText;
  final String? fearText;
  final NavigationDestinationKind destinationKindHint;
  final String? transitRouteName;
  final bool isAffirmative;
  final bool isNegative;
  const CommandDecision({
    required this.cleanedText,
    required this.modeIntent,
    this.directionRu,
    this.destinationQuery,
    this.candidateChoiceIndex,
    this.placeLabelName,
    this.freeAddressText,
    this.fearText,
    this.destinationKindHint = NavigationDestinationKind.generic,
    this.transitRouteName,
    this.isAffirmative = false,
    this.isNegative = false,
  });
}

class _TransitScheduleQuery {
  const _TransitScheduleQuery({
    required this.stopQuery,
    required this.routeName,
  });

  final String stopQuery;
  final String routeName;
}

class CommandRouter {
  static const List<String> describeTriggers = [
    'опиши',
    'что вокруг',
    'что впереди',
    'справа',
    'слева',
    'сзади',
    'позади',
    'вокруг',
    'сипатта',
    'сипаттап бер',
    'айналаны сипатта',
    'алдымда не бар',
    'алдыңда не бар',
    'не көріп тұрсың',
    'оң жақта',
    'сол жақта',
    'артта',
    'айналамда',
    'қандай түс',
    'түсі қандай',
    'түсін айт',
  ];

  static const List<String> repeatTriggers = [
    'повтори',
    'еще раз',
    'ещё раз',
    'повтор',
    'қайтала',
    'тағы бір рет',
    'тағы қайтала',
    'жауап бер',
  ];

  static const List<String> readTextTriggers = [
    'прочитай',
    'прочитать',
    'читай',
    'читай текст',
    'прочитай текст',
    'считай текст',
    'read text',
    'read this',
    'scan text',
    'оқы',
    'мәтінді оқы',
    'мәтінді оқып бер',
    'қайта оқы',
  ];

  static const List<String> switchVoiceLanguageTriggers = [
    'қазақша',
    'қазақша сөйле',
    'қазақша жауап бер',
    'қазақ тілінде',
    'қазақ тілінде жауап бер',
    'по-казахски',
    'по казахски',
    'на казахском',
    'орысша',
    'орысша сөйле',
    'по-русски',
    'по русски',
    'на русском',
  ];

  static const List<String> enterNavModeTriggers = [
    'включи режим маршрута',
    'режим маршрута включи',
    'включи режим навигации',
    'режим навигации включи',
    'маршрут режимін қос',
    'маршрут режимін іске қос',
    'навигация режимін қос',
  ];

  static const List<String> exitNavModeTriggers = [
    'выйти из режима маршрута',
    'выйди из режима маршрута',
    'выключи режим маршрута',
    'выйти из режима навигации',
    'выключи режим навигации',
    'маршрут режимінен шық',
    'маршрут режимін өшір',
    'навигация режимінен шық',
    'навигация режимін өшір',
  ];

  static const List<String> enterBusModeTriggers = [
    'включи режим автобуса',
    'режим автобуса включи',
    'включи автобусный режим',
    'автобусный режим включи',
    'автобус режимін қос',
    'автобус режимін іске қос',
  ];

  static const List<String> exitBusModeTriggers = [
    'выйти из режима автобуса',
    'выйди из режима автобуса',
    'выключи режим автобуса',
    'выйти из автобусного режима',
    'выключи автобусный режим',
    'автобус режимінен шық',
    'автобус режимін өшір',
  ];

  static const List<String> navStartTriggers = [
    'построй маршрут до остановки',
    'проложи маршрут до остановки',
    'маршрут до остановки',
    'построй маршрут до',
    'маршрут до',
    'веди до',
    'проложи маршрут до',
    'как пройти до',
    'проведи до',
    'поехали до',
    'маршрут құр',
    'маршрут жаса',
    'дейін апар',
    'бағыт құр',
    'маршрут баста',
    'аялдамаға дейін маршрут',
    'аялдамага дейін маршрут',
    'үйге апар',
  ];

  static const List<String> transitStopTriggers = [
    'остановка',
    'остановки',
    'остановке',
    'до остановки',
    'на остановке',
    'на остановку',
    'bus stop',
    'аялдама',
    'аялдамаға',
    'аялдамага',
    'аялдамада',
    'аялдамасына',
    'аялдамаға дейін',
  ];

  static const List<String> transitStopRoutesTriggers = [
    'какие маршруты на остановке',
    'какие автобусы на остановке',
    'какие маршруты ходят на остановке',
    'какие автобусы ходят на остановке',
    'какие остановки ходят на остановке',
    'автобусы ходят на остановке',
    'автобусы на остановке',
    'маршруты на остановке',
    'аялдамада қандай маршруттар',
    'аялдамада қандай автобустар',
    'қандай автобустар келеді',
  ];

  static const List<String> transitScheduleTriggers = [
    'когда',
    'во сколько',
    'через сколько',
    'придет',
    'придет автобус',
    'придет маршрут',
    'придет номер',
    'придет ли',
    'придёт',
    'придёт автобус',
    'придёт маршрут',
    'приедет',
    'подъедет',
    'будет',
    'кашан',
    'қашан',
    'келеді',
    'келедi',
  ];

  static const List<String> navStopTriggers = [
    'стоп маршрут',
    'останови маршрут',
    'остановить маршрут',
    'прекрати маршрут',
    'заверши маршрут',
    'маршрутты тоқтат',
    'маршрут стоп',
    'бағытты тоқтат',
  ];

  static const List<String> navStatusTriggers = [
    'статус маршрута',
    'где я',
    'сколько осталось',
    'прогресс маршрута',
    'насколько далеко',
    'маршрут күйі',
    'қай жерде тұрмын',
    'қанша қалды',
    'қандай қашықтық қалды',
    'қайда бару керек',
  ];

  static const List<String> navNextStepTriggers = [
    'что дальше',
    'куда дальше',
    'следующий маневр',
    'следующий шаг',
    'куда поворачивать',
    'әрі қарай не',
    'келесі қадам',
    'қайда бұрыламын',
    'келесі бұрылыс',
  ];

  static const List<String> navRejectChoiceTriggers = [
    'никакой',
    'никакой вариант',
    'ни один',
    'ни один вариант',
    'ничего из этого',
    'отмена выбора',
    'ешқайсысы',
    'ешбірі',
    'таңдауды болдырма',
  ];

  static const List<String> onboardingTriggers = [
    'начать персонализацию',
    'начни персонализацию',
    'давай начнем персонализацию',
    'давай начнём персонализацию',
    'начнем персонализацию',
    'начнём персонализацию',
    'пройти персонализацию',
    'пройти опрос',
    'начать опрос',
    'начни опрос',
    'давай начнем опрос',
    'давай начнём опрос',
    'начнем опрос',
    'начнём опрос',
    'персонализация',
    'баптауды бастау',
    'персонализацияны бастау',
    'сұрақтарға жауап беру',
  ];

  static const List<String> restartOnboardingTriggers = [
    'начать сначала',
    'начни сначала',
    'перепройти опрос',
    'пройти опрос заново',
    'сбросить опрос',
    'бастапкыдан бастау',
    'басынан бастау',
    'сауалнаманы қайта бастау',
  ];

  static const List<String> yesTriggers = [
    'да',
    'правильно',
    'верно',
    'подтверждаю',
    'иә',
    'ия',
    'дұрыс',
    'раста',
  ];

  static const List<String> noTriggers = [
    'нет',
    'неправильно',
    'не верно',
    'не надо',
    'не нужно',
    'жоқ',
    'жок',
    'қате',
    'керек емес',
  ];

  static const List<String> setLabelTriggers = [
    'поставь метку',
    'сохрани как',
    'запомни как',
    'создай метку',
    'белгі қой',
    'белгі жаса',
    'сақта',
  ];

  static const List<String> routeToLabelTriggers = [
    'маршрут до дома',
    'маршрут до работы',
    'маршрут до метки',
    'маршрут до',
    'бағыт үйге',
    'бағыт жұмысқа',
    'белгіге дейін маршрут',
  ];

  static const List<String> fearTriggers = [
    'я боюсь',
    'мне страшно',
    'боюсь',
    'страшно',
    'мен қорқамын',
    'коркамын',
    'қауіптенемін',
  ];

  static String blindSystemPromptFor(AppLanguage language) {
    if (language == AppLanguage.kk) {
      return 'Сен көру қабілеті шектеулі адамға арналған ассистентсің. '
          'Нақты әрі түсінікті жауап бер. '
          'Қосымша сұрақ қойма. '
          'Дерек жетпесе, камерасыз көрмейтініңді ашық айт және камераны кейін қосуды ұсын.';
    }
    return 'Ты ассистент для незрячего пользователя. '
        'Отвечай по делу и понятно. '
        'Не задавай уточняющих вопросов. '
        'Если не хватает данных — честно скажи что без камеры не видишь и предложи включить камеру позже.';
  }

  static String visionSystemPromptFor(AppLanguage language) {
    if (language == AppLanguage.kk) {
      return 'Сен көру қабілеті шектеулі адамға арналған ассистентсің. '
          'Көріністі нақты, түсінікті және жылы түрде сипатта. '
          'Әдетте 2-3 толық аяқталған сөйлем жеткілікті. '
          'Сөйлемді ортасынан үзбе, көп нүкте қолданба. '
          'Жауапты "Бұл суретте..." деген шаблонмен бастама. '
          'Пайдаланушы сұрамаса, бұрыш, градус, координата, пайыз айтпа. '
          'Пайдаланушы сұраса, қысқа не толығырақ айтуға болады. '
          'Қосымша сұрақ қойма. '
          'Бірдеңе көрінбесе, оны ашық айт.';
    }
    return 'Ты ассистент для незрячего пользователя. '
        'Опиши изображение по делу, дружелюбно и понятно. '
        'Обычно достаточно 2-3 завершённых предложений без обрывов. '
        'Не используй многоточия и не начинай с шаблона "На этой фотографии". '
        'Если пользователь не просил, не называй градусы, углы, координаты или проценты. '
        'Если пользователь просит, можно коротко или подробнее. '
        'Не задавай уточняющих вопросов. '
        'Если что-то не видно, честно скажи об этом.';
  }

  String normalize(String text) {
    var t = text.toLowerCase().replaceAll('ё', 'е');
    t = t.replaceAll('-', ' ');
    t = t.replaceAll(RegExp(r'[\n\r]'), ' ');
    t = t.replaceAll(RegExp(r'[.,!?;:"()\[\]{}<>«»]'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  String stripWakeWords(String text) {
    return WakePhraseMatcher.stripWakeWords(text);
  }

  CommandDecision route(String text) {
    final normalized = normalize(text);
    final cleaned = stripWakeWords(normalized);
    final target = cleaned.isEmpty ? normalized : cleaned;
    final direction = _directionFromText(target);
    final choiceIndex = _extractCandidateChoiceIndex(target);
    final transitSchedule = _extractTransitSchedule(target);
    final transitStopRoutesQuery = _extractTransitStopRoutesQuery(target);
    final destination =
        transitSchedule?.stopQuery ??
        transitStopRoutesQuery ??
        _extractDestination(target);
    final placeLabelName = _extractPlaceLabelName(target);
    final fearText = _extractFearText(target);
    final isYes = _isAffirmative(target);
    final isNo = _isNegative(target);
    final intent = _resolveIntent(
      target,
      destination: destination,
      placeLabelName: placeLabelName,
      fearText: fearText,
      isAffirmative: isYes,
      isNegative: isNo,
    );

    return CommandDecision(
      cleanedText: target,
      modeIntent: intent,
      directionRu: direction,
      destinationQuery: destination,
      destinationKindHint: _resolveDestinationKindHint(
        target,
        destination: destination,
      ),
      transitRouteName: transitSchedule?.routeName,
      candidateChoiceIndex: choiceIndex,
      placeLabelName: placeLabelName,
      freeAddressText: _extractFreeAddressText(target),
      fearText: fearText,
      isAffirmative: isYes,
      isNegative: isNo,
    );
  }

  AssistantModeIntent _resolveIntent(
    String text, {
    required String? destination,
    required String? placeLabelName,
    required String? fearText,
    required bool isAffirmative,
    required bool isNegative,
  }) {
    if (_extractTransitSchedule(text) != null) {
      return AssistantModeIntent.busStopSchedule;
    }
    if (_extractTransitStopRoutesQuery(text) != null) {
      return AssistantModeIntent.busStopRoutes;
    }

    if (isAffirmative) return AssistantModeIntent.confirmYes;
    if (isNegative) return AssistantModeIntent.confirmNo;

    if (enterNavModeTriggers.any(text.contains)) {
      return AssistantModeIntent.enterNavMode;
    }
    if (exitNavModeTriggers.any(text.contains)) {
      return AssistantModeIntent.exitNavMode;
    }
    if (enterBusModeTriggers.any(text.contains)) {
      return AssistantModeIntent.enterBusMode;
    }
    if (exitBusModeTriggers.any(text.contains)) {
      return AssistantModeIntent.exitBusMode;
    }
    if (navStopTriggers.any(text.contains)) {
      return AssistantModeIntent.navStop;
    }
    if (navStatusTriggers.any(text.contains)) {
      return AssistantModeIntent.navStatus;
    }
    if (navNextStepTriggers.any(text.contains)) {
      return AssistantModeIntent.navNextStep;
    }
    if (navRejectChoiceTriggers.any(text.contains)) {
      return AssistantModeIntent.navRejectChoice;
    }

    if (onboardingTriggers.any(text.contains)) {
      return AssistantModeIntent.startOnboarding;
    }
    if (restartOnboardingTriggers.any(text.contains)) {
      return AssistantModeIntent.restartOnboarding;
    }
    if (fearText != null && fearText.isNotEmpty) {
      return AssistantModeIntent.updateUserFear;
    }
    if (_looksLikeSetLabelCommand(text)) {
      return AssistantModeIntent.setPlaceLabel;
    }
    if (placeLabelName != null && _looksLikeRouteToLabel(text, destination)) {
      return AssistantModeIntent.routeToPlaceLabel;
    }
    if (navStartTriggers.any(text.contains) ||
        (text.startsWith('маршрут ') && text.length > 8) ||
        (text.startsWith('бағыт ') && text.length > 6)) {
      return AssistantModeIntent.navStart;
    }
    if (destination != null && destination.isNotEmpty) {
      return AssistantModeIntent.navStart;
    }
    if (switchVoiceLanguageTriggers.any(text.contains)) {
      return AssistantModeIntent.switchVoiceLanguage;
    }
    if (repeatTriggers.any(text.contains)) {
      return AssistantModeIntent.repeat;
    }
    if (readTextTriggers.any(text.contains)) {
      return AssistantModeIntent.readText;
    }
    if (describeTriggers.any(text.contains)) {
      return AssistantModeIntent.visionDescribe;
    }
    return AssistantModeIntent.unknown;
  }

  String? _extractDestination(String text) {
    for (final trigger in navStartTriggers) {
      final index = text.indexOf(trigger);
      if (index < 0) continue;
      final query = text.substring(index + trigger.length).trim();
      if (query.isNotEmpty) return query;
    }
    if (text.startsWith('маршрут ')) {
      final query = text.substring('маршрут '.length).trim();
      if (query.isNotEmpty) return query;
    }
    if (text.startsWith('бағыт ')) {
      final query = text.substring('бағыт '.length).trim();
      if (query.isNotEmpty) return query;
    }
    return null;
  }

  String? _extractTransitStopRoutesQuery(String text) {
    // 1. Try triggers-based extraction (legacy fallback)
    for (final trigger in transitStopRoutesTriggers) {
      final index = text.indexOf(trigger);
      if (index >= 0) {
        final tail = text.substring(index + trigger.length).trim();
        final query = _stripTransitStopPrefix(tail);
        if (query.isNotEmpty) return query;
      }
    }

    // 2. Try flexible regex patterns
    final patterns = <RegExp>[
      RegExp(
        r'(?:какие\s+)?(?:автобусы|маршруты)(?:\s+ходят)?(?:\s+на)?\s+остановк[аеиуы]\s+(.+)$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'(?:какие\s+)?(?:автобусы|маршруты)(?:\s+ходят)?\s+через\s+остановк[аеиуы]\s+(.+)$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'остановк[аеиуы]\s+(.+?)\s+(?:какие\s+)?(?:автобусы|маршруты)(?:\s+ходят)?$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'аялдама(?:да|сына)?\s+(.+?)\s+(?:қандай\s+)?(?:маршруттар|автобустар)(?:\s+келеді)?$',
        unicode: true,
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final query = _stripTransitStopPrefix(match.group(1) ?? '').trim();
        if (query.isNotEmpty) return query;
      }
    }

    return null;
  }

  _TransitScheduleQuery? _extractTransitSchedule(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'^(?:когда|через сколько|во сколько)\s+(?:придет|приедет|будет)?\s*(?:автобус|маршрут)?\s*(?:номер\s+)?([0-9\p{L}-]+)\s+(?:на|до|к)?\s*остановк[аеиуы]\s+(.+)$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:автобус|маршрут)\s+(?:номер\s+)?([0-9\p{L}-]+)\s+(?:когда|через сколько|во сколько)\s+(?:придет|приедет|будет)?\s*(?:на|до|к)?\s*остановк[аеиуы]\s+(.+)$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'^(?:автобус|маршрут)?\s*(?:номер\s+)?([0-9\p{L}-]+)\s+(?:когда|через сколько|во сколько)\s+(?:на|до|к)?\s*остановк[аеиуы]\s+(.+)$',
        unicode: true,
        caseSensitive: false,
      ),
      RegExp(
        r'^аялдама(?:да|сына)?\s+(.+?)\s+(?:автобус|маршрут)?\s*(?:номер\s+)?([0-9\p{L}-]+)\s+(?:қашан|қашан келеді|қашан болады)$',
        unicode: true,
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      String routeName;
      String stopQuery;
      if (pattern.pattern.startsWith('^аялдама')) {
        stopQuery = match.group(1)?.trim() ?? '';
        routeName = match.group(2)?.trim() ?? '';
      } else if (match.groupCount >= 3 &&
          (match.group(1) == 'автобус' || match.group(1) == 'маршрут')) {
        routeName = match.group(2)?.trim() ?? '';
        stopQuery = match.group(3)?.trim() ?? '';
      } else {
        routeName = match.group(1)?.trim() ?? '';
        stopQuery = match.group(2)?.trim() ?? '';
      }
      stopQuery = _stripTransitStopPrefix(stopQuery);
      if (routeName.isEmpty || stopQuery.isEmpty) continue;
      return _TransitScheduleQuery(stopQuery: stopQuery, routeName: routeName);
    }
    final routeName = _extractTransitRouteName(text);
    final stopQuery = _extractTransitStopQuery(text);
    if (routeName == null || stopQuery == null) return null;
    if (!_looksLikeTransitScheduleQuestion(text)) return null;
    return _TransitScheduleQuery(stopQuery: stopQuery, routeName: routeName);
  }

  bool _looksLikeTransitScheduleQuestion(String text) {
    if (!(_looksLikeTransitStopText(text) &&
        _containsTransitRouteReference(text))) {
      return false;
    }
    return transitScheduleTriggers.any(text.contains);
  }

  bool _containsTransitRouteReference(String text) {
    return _extractTransitRouteName(text) != null;
  }

  String? _extractTransitRouteName(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'(?:^|\s)(?:автобус|маршрут)\s+номер\s+([0-9\p{L}-]+)(?:\s|$)',
        unicode: true,
      ),
      RegExp(
        r'(?:^|\s)(?:автобус|маршрут)\s+([0-9\p{L}-]+)(?:\s|$)',
        unicode: true,
      ),
      RegExp(
        r'(?:^|\s)номер\s+([0-9\p{L}-]+)\s+(?:автобус|маршрут)(?:\s|$)',
        unicode: true,
      ),
      RegExp(
        r'(?:^|\s)([0-9]{1,3}[a-zа-яқөүіңғәһ]?)\s+(?:автобус|маршрут)(?:\s|$)',
        unicode: true,
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final routeName = match?.group(1)?.trim() ?? '';
      if (routeName.isNotEmpty) {
        return routeName;
      }
    }
    return null;
  }

  String? _extractTransitStopQuery(String text) {
    final patterns = <RegExp>[
      RegExp(
        r'(?:^|\s)(?:на|до|к)\s+остановк[аеиуы]\s+(.+?)\s+(?:когда|через сколько|во сколько|придет|придёт|приедет|подъедет|будет)(?:\s|$)',
        unicode: true,
      ),
      RegExp(
        r'(?:^|\s)остановк[аеиуы]\s+(.+?)\s+(?:когда|через сколько|во сколько|придет|придёт|приедет|подъедет|будет)(?:\s|$)',
        unicode: true,
      ),
      RegExp(r'(?:^|\s)(?:на|до|к)\s+остановк[аеиуы]\s+(.+)$', unicode: true),
      RegExp(r'(?:^|\s)остановк[аеиуы]\s+(.+)$', unicode: true),
      RegExp(
        r'(?:^|\s)аялдама(?:ға|га|да|ны|сына)?\s+(.+?)\s+(?:қашан|кашан|келеді|келедi)(?:\s|$)',
        unicode: true,
      ),
      RegExp(r'(?:^|\s)аялдама(?:ға|га|да|ны|сына)?\s+(.+)$', unicode: true),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final query = _sanitizeTransitStopQuery(match.group(1) ?? '');
      if (query.isNotEmpty) return query;
    }
    return null;
  }

  String _sanitizeTransitStopQuery(String text) {
    var query = _stripTransitStopPrefix(text).trim();
    query = query.replaceFirst(
      RegExp(
        r'^(номер\s+[0-9\p{L}-]+\s+)?(?:автобус|маршрут)\s+',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
    query = query.replaceFirst(
      RegExp(
        r'^(?:когда|через сколько|во сколько|придет|придёт|приедет|подъедет|будет|қашан|кашан)\s+',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
    query = query.replaceFirst(
      RegExp(
        r'\s+(?:когда|через сколько|во сколько|придет|придёт|приедет|подъедет|будет|қашан|кашан|автобус|маршрут|номер)(?:\s|$).*$',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
    return query.trim();
  }

  NavigationDestinationKind _resolveDestinationKindHint(
    String text, {
    required String? destination,
  }) {
    final destinationText = destination?.trim() ?? '';
    if (_looksLikeTransitStopText(text) ||
        (destinationText.isNotEmpty &&
            _looksLikeTransitStopText(destinationText))) {
      return NavigationDestinationKind.transitStop;
    }
    return NavigationDestinationKind.generic;
  }

  bool _looksLikeTransitStopText(String text) {
    final compact = text.trim();
    if (compact.isEmpty) return false;
    return transitStopTriggers.any(compact.contains);
  }

  String _stripTransitStopPrefix(String text) {
    return text
        .replaceFirst(
          RegExp(
            r'^(остановк[аеи]?|аялдама(ға|га)?|аялдамасына)\s+',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trim();
  }

  bool _looksLikeSetLabelCommand(String text) {
    return setLabelTriggers.any(text.contains);
  }

  bool _looksLikeRouteToLabel(String text, String? destination) {
    if (destination == null || destination.trim().isEmpty) return false;
    if (_looksLikeTransitStopText(text) ||
        _looksLikeTransitStopText(destination)) {
      return false;
    }
    final hasLabelCue =
        routeToLabelTriggers.any(text.contains) ||
        text.contains('метк') ||
        text.contains('белгі');
    if (!hasLabelCue) {
      final words = destination.split(' ').where((w) => w.isNotEmpty).length;
      final hasDigits = RegExp(r'\d').hasMatch(destination);
      if (hasDigits) return false;
      return words <= 2;
    }
    return true;
  }

  String? _extractPlaceLabelName(String text) {
    final lowered = text.trim();
    if (lowered.isEmpty) return null;

    final setMatch = RegExp(
      r'(поставь метку|сохрани как|запомни как|создай метку|белгі қой|белгі жаса)\s+(.+)$',
      unicode: true,
    ).firstMatch(lowered);
    if (setMatch != null) {
      return setMatch.group(2)?.trim();
    }

    final routeMatch = RegExp(
      r'(маршрут до|бағыт|маршрут)\s+(.+)$',
      unicode: true,
    ).firstMatch(lowered);
    if (routeMatch != null) {
      final raw = routeMatch.group(2)?.trim() ?? '';
      if (raw.isEmpty) return null;
      if (RegExp(r'\d').hasMatch(raw)) return null;
      return raw;
    }
    return null;
  }

  String? _extractFreeAddressText(String text) {
    final match = RegExp(
      r'(адрес|мекенжай)\s*(это|бұл)?\s*(.+)$',
      unicode: true,
    ).firstMatch(text);
    if (match == null) return null;
    final tail = match.group(3)?.trim() ?? '';
    if (tail.isEmpty) return null;
    return tail;
  }

  String? _extractFearText(String text) {
    for (final trigger in fearTriggers) {
      if (!text.contains(trigger)) continue;
      final idx = text.indexOf(trigger);
      final tail = text.substring(idx + trigger.length).trim();
      if (tail.isNotEmpty) return tail;
      return trigger;
    }
    return null;
  }

  bool _isAffirmative(String text) {
    final compact = text.trim();
    if (compact.isEmpty) return false;
    final words = compact.split(' ').where((w) => w.isNotEmpty).length;
    if (words > 4) return false;
    return yesTriggers.any((trigger) {
      if (compact == trigger) return true;
      return compact.startsWith('$trigger ');
    });
  }

  bool _isNegative(String text) {
    final compact = text.trim();
    if (compact.isEmpty) return false;
    final words = compact.split(' ').where((w) => w.isNotEmpty).length;
    if (words > 5) return false;
    return noTriggers.any((trigger) {
      if (compact == trigger) return true;
      return compact.startsWith('$trigger ');
    });
  }

  int? _extractCandidateChoiceIndex(String text) {
    final words = text.split(' ').where((w) => w.isNotEmpty).toList();
    final compactWords = words.map((w) => w.replaceAll('-', '')).toList();

    final hasFirst =
        RegExp(r'(^| )1($| )').hasMatch(text) ||
        compactWords.any((w) => w == '1й') ||
        words.any((w) => w.startsWith('перв')) ||
        words.any((w) => w.startsWith('бірін')) ||
        words.contains('один') ||
        words.contains('одна') ||
        words.contains('бір');
    if (hasFirst) {
      return 0;
    }

    final hasSecond =
        RegExp(r'(^| )2($| )').hasMatch(text) ||
        compactWords.any((w) => w == '2й') ||
        words.any((w) => w.startsWith('втор')) ||
        words.contains('два') ||
        words.contains('две') ||
        words.any((w) => w.startsWith('екін')) ||
        words.contains('екі');
    if (hasSecond) {
      return 1;
    }

    final hasThird =
        RegExp(r'(^| )3($| )').hasMatch(text) ||
        compactWords.any((w) => w == '3й') ||
        words.any((w) => w.startsWith('трет')) ||
        words.contains('три') ||
        words.any((w) => w.startsWith('үшінш')) ||
        words.contains('үш');
    if (hasThird) {
      return 2;
    }
    return null;
  }

  String? _directionFromText(String text) {
    if (text.contains('что впереди') ||
        text.contains('впереди') ||
        text.contains('спереди') ||
        text.contains('алдыңда') ||
        text.contains('алдымда')) {
      return 'впереди';
    }
    if (text.contains('что слева') ||
        text.contains('слева') ||
        text.contains('сол жақ')) {
      return 'слева';
    }
    if (text.contains('что справа') ||
        text.contains('справа') ||
        text.contains('оң жақ')) {
      return 'справа';
    }
    if (text.contains('что сзади') ||
        text.contains('сзади') ||
        text.contains('позади') ||
        text.contains('артта')) {
      return 'сзади';
    }
    if (text.contains('что вокруг') ||
        text.contains('вокруг') ||
        text.contains('айналам')) {
      return 'вокруг';
    }
    return null;
  }
}
