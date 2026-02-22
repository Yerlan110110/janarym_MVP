import '../l10n/app_locale_controller.dart';

enum AssistantModeIntent {
  enterNavMode,
  exitNavMode,
  navStart,
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
  const CommandDecision({
    required this.cleanedText,
    required this.modeIntent,
    this.directionRu,
    this.destinationQuery,
    this.candidateChoiceIndex,
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
    'жан',
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

  static String blindSystemPromptFor(AppLanguage language) {
    if (language == AppLanguage.kk) {
      return 'Сен көру қабілеті шектеулі адамға арналған ассистентсің. '
          'Қысқа әрі нақты жауап бер. '
          'Қосымша сұрақ қойма. '
          'Дерек жетпесе, камерасыз көрмейтініңді ашық айт және камераны кейін қосуды ұсын.';
    }
    return 'Ты ассистент для незрячего пользователя. '
        'Отвечай коротко и по делу. '
        'Не задавай уточняющих вопросов. '
        'Если не хватает данных — честно скажи что без камеры не видишь и предложи включить камеру позже.';
  }

  static String visionSystemPromptFor(AppLanguage language) {
    if (language == AppLanguage.kk) {
      return 'Сен көру қабілеті шектеулі адамға арналған ассистентсің. '
          'Көріністі нақты, түсінікті және жылы түрде сипатта. '
          'Жауап 2 қысқа сөйлемнен аспасын. '
          'Пайдаланушы сұраса, қысқа не толығырақ айтуға болады. '
          'Қосымша сұрақ қойма. '
          'Бірдеңе көрінбесе, оны ашық айт.';
    }
    return 'Ты ассистент для незрячего пользователя. '
        'Опиши изображение по делу, дружелюбно и понятно. '
        'Ответ не длиннее 2 коротких предложений. '
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
    final intent = _resolveIntent(target, destination: destination);

    return CommandDecision(
      cleanedText: target,
      modeIntent: intent,
      directionRu: direction,
      destinationQuery: destination,
      candidateChoiceIndex: choiceIndex,
    );
  }

  AssistantModeIntent _resolveIntent(
    String text, {
    required String? destination,
  }) {
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
