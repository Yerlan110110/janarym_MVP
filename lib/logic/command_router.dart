import '../l10n/app_locale_controller.dart';

enum AssistantModeIntent {
  enterNavMode,
  exitNavMode,
  navStart,
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
    this.isAffirmative = false,
    this.isNegative = false,
  });
}

class CommandRouter {
  static const List<String> wakeWordVariants = [
    'жанарым',
    'жанарим',
    'жанарум',
    'жан арым',
    'жан а рым',
    'жанаром',
    'жанарам',
    'жанрам',
    'шмарым',
    'janarym',
    'janarim',
    'zhanarym',
    'zhanarim',
    'zhanarum',
    'zhan a rym',
    'zhan-a-rym',
  ];

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
    'айналаны сипатта',
    'алдымда не бар',
    'алдыңда не бар',
    'оң жақта',
    'сол жақта',
    'артта',
    'айналамда',
  ];

  static const List<String> repeatTriggers = [
    'повтори',
    'еще раз',
    'ещё раз',
    'повтор',
    'қайтала',
    'тағы бір рет',
    'тағы қайтала',
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

  static const List<String> navStartTriggers = [
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
    'пройти персонализацию',
    'пройти опрос',
    'начать опрос',
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
    var t = text;
    for (final w in wakeWordVariants) {
      t = t.replaceAll(RegExp(r'\b' + RegExp.escape(w) + r'\b'), ' ');
    }
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  CommandDecision route(String text) {
    final normalized = normalize(text);
    final cleaned = stripWakeWords(normalized);
    final target = cleaned.isEmpty ? normalized : cleaned;
    final direction = _directionFromText(target);
    final choiceIndex = _extractCandidateChoiceIndex(target);
    final destination = _extractDestination(target);
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
    if (isAffirmative) return AssistantModeIntent.confirmYes;
    if (isNegative) return AssistantModeIntent.confirmNo;
    if (enterNavModeTriggers.any(text.contains)) {
      return AssistantModeIntent.enterNavMode;
    }
    if (exitNavModeTriggers.any(text.contains)) {
      return AssistantModeIntent.exitNavMode;
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
    if (repeatTriggers.any(text.contains)) {
      return AssistantModeIntent.repeat;
    }
    final hasVisionDirection = _directionFromText(text) != null;
    if (hasVisionDirection || describeTriggers.any(text.contains)) {
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

  bool _looksLikeSetLabelCommand(String text) {
    return setLabelTriggers.any(text.contains);
  }

  bool _looksLikeRouteToLabel(String text, String? destination) {
    if (destination == null || destination.trim().isEmpty) return false;
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
