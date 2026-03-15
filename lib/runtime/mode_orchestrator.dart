import 'package:flutter/material.dart';

import 'feature_flags.dart';

enum JanarymMode {
  home,
  route,
  safety,
  text_reader,
  shopping,
  cooking,
  dress_code,
  anti_fraud,
  memory,
  find,
}

extension JanarymModeX on JanarymMode {
  String get storageKey => name;
}

class ModeUiIndicator {
  const ModeUiIndicator({
    required this.labelRu,
    required this.labelKk,
    required this.shortRu,
    required this.shortKk,
    required this.icon,
    required this.accentColor,
  });

  final String labelRu;
  final String labelKk;
  final String shortRu;
  final String shortKk;
  final IconData icon;
  final Color accentColor;

  String label({required bool isKazakh}) => isKazakh ? labelKk : labelRu;

  String shortLabel({required bool isKazakh}) => isKazakh ? shortKk : shortRu;
}

class ModePerceptionFilter {
  const ModePerceptionFilter({
    this.requiresLiveCamera = true,
    this.prefersSceneDescription = false,
    this.prefersNavigationGuidance = false,
    this.reflexPriority = false,
    this.safetyMax = false,
    this.enableAutoTextReader = false,
    this.enableOcr = false,
    this.enableWeatherContext = false,
    this.enableShoppingList = false,
    this.enableCookingGuidance = false,
    this.enableCurrencyCheck = false,
    this.enableSceneMemory = false,
    this.enableObjectSearch = false,
    this.showHazardOverlay = true,
    this.allowHazardVoice = true,
    this.hazardLabelsOfInterest = const <String>{},
    this.ocrFocus = const <String>{},
  });

  final bool requiresLiveCamera;
  final bool prefersSceneDescription;
  final bool prefersNavigationGuidance;
  final bool reflexPriority;
  final bool safetyMax;
  final bool enableAutoTextReader;
  final bool enableOcr;
  final bool enableWeatherContext;
  final bool enableShoppingList;
  final bool enableCookingGuidance;
  final bool enableCurrencyCheck;
  final bool enableSceneMemory;
  final bool enableObjectSearch;
  final bool showHazardOverlay;
  final bool allowHazardVoice;
  final Set<String> hazardLabelsOfInterest;
  final Set<String> ocrFocus;

  bool matchesHazardLabel(String? label) {
    if (label == null || label.trim().isEmpty) return false;
    if (hazardLabelsOfInterest.isEmpty) return true;
    return hazardLabelsOfInterest.contains(label.trim().toLowerCase());
  }

  Map<String, Object?> toSnapshot() {
    return <String, Object?>{
      'live_camera': requiresLiveCamera,
      'scene_description': prefersSceneDescription,
      'navigation_guidance': prefersNavigationGuidance,
      'reflex_priority': reflexPriority,
      'safety_max': safetyMax,
      'auto_text_reader': enableAutoTextReader,
      'ocr': enableOcr,
      'weather': enableWeatherContext,
      'shopping': enableShoppingList,
      'cooking': enableCookingGuidance,
      'currency_check': enableCurrencyCheck,
      'scene_memory': enableSceneMemory,
      'object_search': enableObjectSearch,
      'hazard_overlay': showHazardOverlay,
      'hazard_voice': allowHazardVoice,
      'hazard_focus': hazardLabelsOfInterest.toList(growable: false),
      'ocr_focus': ocrFocus.toList(growable: false),
    };
  }
}

class ModePromptProfile {
  const ModePromptProfile({
    required this.blindRu,
    required this.blindKk,
    required this.visionRu,
    required this.visionKk,
  });

  final String blindRu;
  final String blindKk;
  final String visionRu;
  final String visionKk;

  String blind({required bool isKazakh}) => isKazakh ? blindKk : blindRu;

  String vision({required bool isKazakh}) => isKazakh ? visionKk : visionRu;
}

class ModeDescriptor {
  const ModeDescriptor({
    required this.mode,
    required this.contextKey,
    required this.ui,
    required this.perception,
    required this.prompts,
  });

  final JanarymMode mode;
  final String contextKey;
  final ModeUiIndicator ui;
  final ModePerceptionFilter perception;
  final ModePromptProfile prompts;
}

class ModeState {
  const ModeState({
    required this.activeMode,
    required this.subState,
    required this.autoTriggered,
    required this.lastTransitionTimestamp,
    this.autoTriggeredBy,
  });

  final JanarymMode activeMode;
  final String subState;
  final bool autoTriggered;
  final int lastTransitionTimestamp;
  final String? autoTriggeredBy;

  ModeState copyWith({
    JanarymMode? activeMode,
    String? subState,
    bool? autoTriggered,
    int? lastTransitionTimestamp,
    Object? autoTriggeredBy = _noChange,
  }) {
    return ModeState(
      activeMode: activeMode ?? this.activeMode,
      subState: subState ?? this.subState,
      autoTriggered: autoTriggered ?? this.autoTriggered,
      lastTransitionTimestamp:
          lastTransitionTimestamp ?? this.lastTransitionTimestamp,
      autoTriggeredBy: autoTriggeredBy == _noChange
          ? this.autoTriggeredBy
          : autoTriggeredBy as String?,
    );
  }

  static const Object _noChange = Object();
}

class ModeOrchestrator extends ValueNotifier<ModeState> {
  ModeOrchestrator({required RuntimeFeatureFlags flags})
    : _flags = flags,
      _descriptors = _buildDescriptors(),
      super(
        ModeState(
          activeMode: JanarymMode.home,
          subState: 'idle',
          autoTriggered: false,
          lastTransitionTimestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  final RuntimeFeatureFlags _flags;
  final Map<JanarymMode, ModeDescriptor> _descriptors;

  ModeDescriptor descriptorFor(JanarymMode mode) {
    return _descriptors[mode]!;
  }

  ModeDescriptor get activeDescriptor => descriptorFor(value.activeMode);

  ModePerceptionFilter perceptionFor(JanarymMode mode) {
    return descriptorFor(mode).perception;
  }

  ModeUiIndicator uiFor(JanarymMode mode) {
    return descriptorFor(mode).ui;
  }

  String localizedModeLabel(
    JanarymMode mode, {
    required bool isKazakh,
    bool short = false,
  }) {
    final ui = uiFor(mode);
    return short
        ? ui.shortLabel(isKazakh: isKazakh)
        : ui.label(isKazakh: isKazakh);
  }

  String localizedSubState(String subState, {required bool isKazakh}) {
    switch (subState.trim().toLowerCase()) {
      case 'wake':
        return isKazakh ? 'Ояту' : 'Ожидание';
      case 'listening':
        return isKazakh ? 'Тыңдап тұрмын' : 'Слушаю';
      case 'thinking':
        return isKazakh ? 'Ойлап тұрмын' : 'Думаю';
      case 'speaking':
        return isKazakh ? 'Сөйлеп тұрмын' : 'Говорю';
      case 'active':
        return isKazakh ? 'Белсенді' : 'Активен';
      case 'idle':
      default:
        return isKazakh ? 'Дайын' : 'Готов';
    }
  }

  bool isEnabled(JanarymMode mode) {
    switch (mode) {
      case JanarymMode.home:
        return true;
      case JanarymMode.route:
        return _flags.navigationEnabled;
      case JanarymMode.safety:
        return _flags.safetyEnabled;
      case JanarymMode.text_reader:
        return _flags.textReaderEnabled;
      case JanarymMode.shopping:
        return _flags.shoppingEnabled;
      case JanarymMode.cooking:
        return _flags.cookingEnabled;
      case JanarymMode.dress_code:
        return _flags.dressCodeEnabled;
      case JanarymMode.anti_fraud:
        return _flags.antiFraudEnabled;
      case JanarymMode.memory:
        return _flags.memoryEnabled;
      case JanarymMode.find:
        return _flags.findEnabled;
    }
  }

  List<JanarymMode> availableModes() {
    const ordered = <JanarymMode>[
      JanarymMode.home,
      JanarymMode.route,
      JanarymMode.find,
      JanarymMode.memory,
      JanarymMode.text_reader,
      JanarymMode.shopping,
      JanarymMode.cooking,
      JanarymMode.dress_code,
      JanarymMode.anti_fraud,
    ];
    return ordered.where(isEnabled).toList(growable: false);
  }

  List<ModeDescriptor> availableDescriptors() {
    return availableModes().map(descriptorFor).toList(growable: false);
  }

  bool transitionTo(
    JanarymMode nextMode, {
    String subState = 'idle',
    bool autoTriggered = false,
    String? autoTriggeredBy,
  }) {
    if (!isEnabled(nextMode)) return false;
    if (value.activeMode == nextMode &&
        value.subState == subState &&
        value.autoTriggered == autoTriggered &&
        value.autoTriggeredBy == autoTriggeredBy) {
      return true;
    }
    value = value.copyWith(
      activeMode: nextMode,
      subState: subState,
      autoTriggered: autoTriggered,
      autoTriggeredBy: autoTriggeredBy,
      lastTransitionTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
    return true;
  }

  void setSubState(String subState) {
    if (value.subState == subState) return;
    value = value.copyWith(
      subState: subState,
      lastTransitionTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Map<JanarymMode, ModeDescriptor> _buildDescriptors() {
    return <JanarymMode, ModeDescriptor>{
      JanarymMode.home: ModeDescriptor(
        mode: JanarymMode.home,
        contextKey: 'home',
        ui: const ModeUiIndicator(
          labelRu: 'Обычный',
          labelKk: 'Қалыпты режим',
          shortRu: 'Обычный',
          shortKk: 'Қалыпты',
          icon: Icons.home_rounded,
          accentColor: Color(0xFF94A3B8),
        ),
        perception: const ModePerceptionFilter(
          prefersSceneDescription: true,
          hazardLabelsOfInterest: <String>{
            'car',
            'bike',
            'hot_surface',
            'sharp_object',
            'stairs_edge',
          },
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это home режим. Держи домашний контекст: помогай ориентироваться по комнате, запоминать расположение вещей и отвечай как ассистент домашнего окружения.',
          blindKk:
              'Бұл home режимі. Үй ішіндегі контексті ұста: бөлмеде бағдарлануға, заттардың орнын есте сақтауға және үй кеңістігі бойынша көмектес.',
          visionRu:
              'Это home режим. Коротко опиши текущую сцену, ключевые ориентиры, свободный проход и ближайшие заметные объекты без лишней воды.',
          visionKk:
              'Бұл home режимі. Қазіргі көріністі қысқа сипатта: негізгі ориентирлерді, бос өтуді және жақын заттарды ғана айт.',
        ),
      ),
      JanarymMode.route: ModeDescriptor(
        mode: JanarymMode.route,
        contextKey: 'route',
        ui: const ModeUiIndicator(
          labelRu: 'Маршрутизатор',
          labelKk: 'Бағдарлағыш',
          shortRu: 'Маршрут',
          shortKk: 'Маршрут',
          icon: Icons.alt_route_rounded,
          accentColor: Color(0xFF22D3EE),
        ),
        perception: const ModePerceptionFilter(
          prefersNavigationGuidance: true,
          reflexPriority: true,
          safetyMax: true,
          hazardLabelsOfInterest: <String>{'car', 'bike', 'stairs_edge'},
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это route режим. Отвечай как голосовой проводник: следующий шаг, статус маршрута, ближайший ориентир, без теории и общих объяснений.',
          blindKk:
              'Бұл route режимі. Дыбыстық бағыттаушы сияқты жауап бер: келесі қадам, маршрут күйі, жақын ориентир. Артық түсіндірусіз.',
          visionRu:
              'Это route режим. Если используешь камеру, называй только ориентиры, направление движения и помехи по пути.',
          visionKk:
              'Бұл route режимі. Камера қолданылса, тек ориентирді, қозғалыс бағытын және жолдағы кедергіні айт.',
        ),
      ),
      JanarymMode.safety: ModeDescriptor(
        mode: JanarymMode.safety,
        contextKey: 'safety',
        ui: const ModeUiIndicator(
          labelRu: 'Безопасность',
          labelKk: 'Қауіпсіздік',
          shortRu: 'Safety',
          shortKk: 'Safety',
          icon: Icons.warning_amber_rounded,
          accentColor: Color(0xFFEF4444),
        ),
        perception: const ModePerceptionFilter(
          reflexPriority: true,
          hazardLabelsOfInterest: <String>{
            'car',
            'bike',
            'hot_surface',
            'sharp_object',
            'stairs_edge',
          },
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это safety режим. Всегда ставь безопасность выше описания. Сначала опасность, затем направление, дистанция и одно короткое действие.',
          blindKk:
              'Бұл safety режимі. Әрқашан қауіпсіздікті бірінші қой: алдымен қауіп, сосын бағыты, қашықтығы және бір қысқа әрекет.',
          visionRu:
              'Это safety режим. Сначала назови опасный объект, затем направление, примерную дистанцию и краткое безопасное действие.',
          visionKk:
              'Бұл safety режимі. Алдымен қауіпті нысанды ата, кейін бағытын, шамамен қашықтығын және қысқа қауіпсіз әрекетті айт.',
        ),
      ),
      JanarymMode.text_reader: ModeDescriptor(
        mode: JanarymMode.text_reader,
        contextKey: 'text_reader',
        ui: const ModeUiIndicator(
          labelRu: 'Чтение текста',
          labelKk: 'Оқу',
          shortRu: 'Текст',
          shortKk: 'Мәтін',
          icon: Icons.text_snippet_rounded,
          accentColor: Color(0xFFA78BFA),
        ),
        perception: const ModePerceptionFilter(
          enableAutoTextReader: true,
          enableOcr: true,
          ocrFocus: <String>{'price', 'calories', 'full_text'},
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это text_reader режим. Приоритет: OCR, цена, калории, документный текст. Отвечай как читалка, а не как общий ассистент.',
          blindKk:
              'Бұл text_reader режимі. Басымдық: OCR, баға, калория, құжат мәтіні. Жалпы ассистент емес, мәтін оқығыш сияқты жауап бер.',
          visionRu:
              'Это text_reader режим. Из кадра извлекай текст, цену, калории и читай без лишнего описания сцены.',
          visionKk:
              'Бұл text_reader режимі. Кадрдан мәтін, баға және калорияны шығарып, сахнаны артық сипаттамай оқы.',
        ),
      ),
      JanarymMode.shopping: ModeDescriptor(
        mode: JanarymMode.shopping,
        contextKey: 'shopping',
        ui: const ModeUiIndicator(
          labelRu: 'Шоппинг',
          labelKk: 'Шопинг',
          shortRu: 'Шоппинг',
          shortKk: 'Шоппинг',
          icon: Icons.shopping_bag_rounded,
          accentColor: Color(0xFF34D399),
        ),
        perception: const ModePerceptionFilter(
          enableShoppingList: true,
          enableObjectSearch: true,
          enableOcr: true,
          hazardLabelsOfInterest: <String>{'car', 'bike', 'stairs_edge'},
          ocrFocus: <String>{'price', 'full_text'},
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это shopping режим. Работай со списком покупок, остатком списка, полками и короткими подсказками куда идти и что взять.',
          blindKk:
              'Бұл shopping режимі. Сатып алу тізімімен, қалған тауарлармен, сөрелермен және қайда бару керегі туралы қысқа нұсқаумен жұмыс істе.',
          visionRu:
              'Это shopping режим. Ищи нужный товар, говори только направление, полку и конкретное действие для приближения.',
          visionKk:
              'Бұл shopping режимі. Қажетті тауарды ізде, тек бағытын, сөрені және жақындауға арналған нақты қадамды айт.',
        ),
      ),
      JanarymMode.cooking: ModeDescriptor(
        mode: JanarymMode.cooking,
        contextKey: 'cooking',
        ui: const ModeUiIndicator(
          labelRu: 'Готовка',
          labelKk: 'Дайындау',
          shortRu: 'Кухня',
          shortKk: 'Асүй',
          icon: Icons.restaurant_menu_rounded,
          accentColor: Color(0xFFFB7185),
        ),
        perception: const ModePerceptionFilter(
          reflexPriority: true,
          enableCookingGuidance: true,
          hazardLabelsOfInterest: <String>{
            'hot_surface',
            'sharp_object',
            'stairs_edge',
          },
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это cooking режим. Давай пошаговые подсказки по готовке и короткие команды по смещению руки: выше, ниже, левее, правее.',
          blindKk:
              'Бұл cooking режимі. Дайындау бойынша қадамдық нұсқаулар және қол қозғалысына қысқа команда бер: жоғары, төмен, солға, оңға.',
          visionRu:
              'Это cooking режим. Отмечай плиту, горячие поверхности и острые предметы. Для руки используй только относительные направления.',
          visionKk:
              'Бұл cooking режимі. Плитаны, ыстық беттерді және өткір заттарды белгіле. Қол үшін тек салыстырмалы бағыттарды қолдан.',
        ),
      ),
      JanarymMode.dress_code: ModeDescriptor(
        mode: JanarymMode.dress_code,
        contextKey: 'dress_code',
        ui: const ModeUiIndicator(
          labelRu: 'Дрескод',
          labelKk: 'Дресс-код',
          shortRu: 'Одежда',
          shortKk: 'Киім',
          icon: Icons.checkroom_rounded,
          accentColor: Color(0xFF60A5FA),
        ),
        perception: const ModePerceptionFilter(
          enableWeatherContext: true,
          enableObjectSearch: true,
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это dress_code режим. Учитывай погоду и контекст выхода, советуй одежду кратко и практично.',
          blindKk:
              'Бұл dress_code режимі. Ауа райы мен шығу контекстін ескеріп, киім бойынша қысқа әрі практикалық кеңес бер.',
          visionRu:
              'Это dress_code режим. Оцени текущую одежду, соответствие погоде и что стоит добавить или заменить.',
          visionKk:
              'Бұл dress_code режимі. Қазіргі киімді бағала, ауа райына сәйкестігін айт және не қосу немесе ауыстыру керегін көрсет.',
        ),
      ),
      JanarymMode.anti_fraud: ModeDescriptor(
        mode: JanarymMode.anti_fraud,
        contextKey: 'anti_fraud',
        ui: const ModeUiIndicator(
          labelRu: 'Антимошеничество',
          labelKk: 'Антиалаяқ',
          shortRu: 'Касса',
          shortKk: 'Касса',
          icon: Icons.shield_rounded,
          accentColor: Color(0xFFF97316),
        ),
        perception: const ModePerceptionFilter(
          enableCurrencyCheck: true,
          enableOcr: true,
          ocrFocus: <String>{'price', 'full_text'},
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это anti_fraud режим. Внимательно проверь купюру (тенге) на фото на подлинность. Ищи тексты из OCR: "не является платежным средством", сувенирные метки. ВНИМАНИЕ: ЗАПРЕЩАЕТСЯ просить пользователя проверить купюру самому или задавать ему вопросы! Ты должен сам вынести вердикт по фото. Скажи прямо: это настоящая купюра или подделка/сувенир. Назови номинал.',
          blindKk:
              'Бұл anti_fraud режимі. Фотодағы купюраның (теңге) түпнұсқалығын мұқият тексер. OCR мәтіндерінен "төлем құралы болып табылмайды" деген жазуларды, кәдесый белгілерін ізде. НАЗАР АУДАРЫҢЫЗ: Пайдаланушыдан купюраны өзі тексеруді сұрауға немесе оған сұрақ қоюға ҚАТАҢ ТЫЙЫМ САЛЫНАДЫ! Сен фото бойынша өзің үкім шығаруың керек. Бұл нағыз ақша ма, әлде жалған/кәдесый ма, соны тікелей айт. Номиналын ата.',
          visionRu:
              'Это anti_fraud режим. Внимательно проверь купюру (тенге) на фото на подлинность. Ищи тексты из OCR: "не является платежным средством", сувенирные метки. ВНИМАНИЕ: ЗАПРЕЩАЕТСЯ просить пользователя проверить купюру самому или задавать ему вопросы! Ты должен сам вынести вердикт по фото. Скажи прямо: это настоящая купюра или подделка/сувенир. Назови номинал.',
          visionKk:
              'Бұл anti_fraud режимі. Фотодағы купюраның (теңге) түпнұсқалығын мұқият тексер. OCR мәтіндерінен "төлем құралы болып табылмайды" деген жазуларды, кәдесый белгілерін ізде. НАЗАР АУДАРЫҢЫЗ: Пайдаланушыдан купюраны өзі тексеруді сұрауға немесе оған сұрақ қоюға ҚАТАҢ ТЫЙЫМ САЛЫНАДЫ! Сен фото бойынша өзің үкім шығаруың керек. Бұл нағыз ақша ма, әлде жалған/кәдесый ма, соны тікелей айт. Номиналын ата.',
        ),
      ),
      JanarymMode.memory: ModeDescriptor(
        mode: JanarymMode.memory,
        contextKey: 'memory',
        ui: const ModeUiIndicator(
          labelRu: 'Память',
          labelKk: 'Жад',
          shortRu: 'Память',
          shortKk: 'Жад',
          icon: Icons.bookmark_rounded,
          accentColor: Color(0xFFFBBF24),
        ),
        perception: const ModePerceptionFilter(
          enableSceneMemory: true,
          prefersSceneDescription: true,
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это memory режим. Помогай сохранять сцену как якорь, сравнивать с ранее сохранённым местом и вспоминать ориентиры.',
          blindKk:
              'Бұл memory режимі. Сахнаны якорь ретінде сақтауға, бұрын сақталған орынмен салыстыруға және ориентирлерді еске түсіруге көмектес.',
          visionRu:
              'Это memory режим. Выделяй устойчивые ориентиры сцены, чтобы их можно было сохранить или сравнить позже.',
          visionKk:
              'Бұл memory режимі. Кейін сақтау немесе салыстыру үшін сахнаның тұрақты ориентирлерін бөліп көрсет.',
        ),
      ),
      JanarymMode.find: ModeDescriptor(
        mode: JanarymMode.find,
        contextKey: 'find',
        ui: const ModeUiIndicator(
          labelRu: 'Найти',
          labelKk: 'Табу',
          shortRu: 'Поиск',
          shortKk: 'Іздеу',
          icon: Icons.search_rounded,
          accentColor: Color(0xFF38BDF8),
        ),
        perception: const ModePerceptionFilter(
          enableObjectSearch: true,
          safetyMax: true,
          hazardLabelsOfInterest: <String>{'car', 'bike', 'stairs_edge'},
        ),
        prompts: const ModePromptProfile(
          blindRu:
              'Это find режим. Ищи целевой объект и отвечай только про его наличие, направление и следующий шаг.',
          blindKk:
              'Бұл find режимі. Нысанды ізде де тек бар-жоғын, бағытын және келесі қадамды айт.',
          visionRu:
              'Это find режим. Если объект виден, скажи направление и шаг для приближения. Если не виден, скажи это прямо.',
          visionKk:
              'Бұл find режимі. Егер нысан көрінсе, бағытын және жақындау қадамын айт. Көрінбесе, оны тікелей айт.',
        ),
      ),
    };
  }
}
