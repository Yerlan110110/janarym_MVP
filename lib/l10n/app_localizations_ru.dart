// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appName => 'Janarym';

  @override
  String get languagePickerLabel => 'Язык';

  @override
  String get languageRu => 'Русский';

  @override
  String get languageKk => 'Қазақша';

  @override
  String get languageShortRu => 'RU';

  @override
  String get languageShortKk => 'KZ';

  @override
  String get checkingMic => 'Проверяю микрофон...';

  @override
  String get checkingCamera => 'Проверяю камеру...';

  @override
  String get micAvailable => 'Микрофон доступен.';

  @override
  String get micAccessDenied =>
      'Доступ к микрофону запрещён. Разрешите в настройках приложения.';

  @override
  String get micAccessRequired =>
      'Нужен доступ к микрофону для голосовых команд.';

  @override
  String get cameraAvailable => 'Камера доступна.';

  @override
  String get cameraAccessDenied =>
      'Доступ к камере запрещён. Разрешите в настройках приложения.';

  @override
  String get cameraAccessRequired =>
      'Нужен доступ к камере для описания окружения.';

  @override
  String get cameraNotFound => 'Камера не найдена.';

  @override
  String get cameraLiveOn => 'Камера: включена';

  @override
  String get cameraLiveOff => 'Камера: выключена';

  @override
  String cameraStartFailed(Object error) {
    return 'Не удалось запустить камеру: $error';
  }

  @override
  String get errorOpenAiKeyMissing => 'OPENAI_API_KEY не задан (проверь .env)';

  @override
  String get errorEmptyImageFrame => 'Пустой кадр изображения.';

  @override
  String get errorExtractTextFailed => 'Не удалось извлечь текст ответа.';

  @override
  String get sttNoMicPermission => 'Нет доступа к микрофону для записи';

  @override
  String sttStartFailed(Object error) {
    return 'Не удалось запустить распознавание речи: $error';
  }

  @override
  String sttGenericError(Object error) {
    return 'Ошибка распознавания речи: $error';
  }

  @override
  String get modeNavigation => 'Режим маршрута';

  @override
  String get modeGeneral => 'Обычный режим';

  @override
  String get statusWaitingReply => 'Жду вашего ответа';

  @override
  String get embeddedMapDisabled =>
      'Встроенная карта временно отключена для стабильности. Навигация и голосовые инструкции работают.';

  @override
  String get panelStatusPrefix => 'Статус';

  @override
  String get panelTargetPrefix => 'Цель';

  @override
  String get panelErrorPrefix => 'Ошибка';

  @override
  String get navStatusIdle => 'ожидание';

  @override
  String get navStatusResolvingDestination => 'поиск адреса';

  @override
  String get navStatusAwaitingChoice => 'ожидание выбора';

  @override
  String get navStatusBuildingRoute => 'построение маршрута';

  @override
  String get navStatusNavigating => 'в пути';

  @override
  String get navStatusRerouting => 'перестроение';

  @override
  String get navStatusCompleted => 'завершен';

  @override
  String get navStatusError => 'ошибка';

  @override
  String get markerFinish => 'Финиш';

  @override
  String get markerYou => 'Вы';

  @override
  String get circleLabelWake => 'Скажите «Жанарым»';

  @override
  String get circleLabelListening => 'Слушаю';

  @override
  String get circleLabelThinking => 'Думаю';

  @override
  String get circleLabelSpeaking => 'Говорю';

  @override
  String get circleLabelReady => 'Готов к работе';

  @override
  String get circleStatusWake => 'ОЖИДАНИЕ';

  @override
  String get circleStatusListening => 'СЛУШАЮ';

  @override
  String get circleStatusThinking => 'ДУМАЮ';

  @override
  String get circleStatusSpeaking => 'ГОВОРЮ';

  @override
  String get circleStatusReady => 'ГОТОВО';

  @override
  String get commandProcessingFailed =>
      'Не удалось обработать команду. Попробуйте снова.';

  @override
  String get enableRouteModeFirst => 'Сначала включите режим маршрута.';

  @override
  String get routeModeDescribeBlocked =>
      'Сейчас включен режим маршрута. Выйдите из режима маршрута для команд описания.';

  @override
  String get didntHearCommandRepeat =>
      'Не расслышала команду. Повторите, пожалуйста.';

  @override
  String get sayAddressAfterRoutePhrase =>
      'Скажите адрес после слов: маршрут до...';

  @override
  String get unknownRouteCommandHelp =>
      'Не поняла команду. Скажите адрес назначения или: что дальше, статус маршрута, стоп маршрут.';

  @override
  String get followUpNeedAnythingElse => 'Нужно ли еще что-нибудь?';

  @override
  String get routeModeAlreadyEnabled => 'Режим маршрута уже включен.';

  @override
  String get routeModeNotEnabled => 'Режим маршрута не включен.';

  @override
  String get noCameraAccess => 'Нет доступа к камере.';

  @override
  String get fastFrameUnavailable =>
      'Не удалось быстро получить кадр. Повторите команду.';

  @override
  String get frameUnavailable =>
      'Не удалось получить кадр с камеры. Повторите команду.';

  @override
  String get staleFrameUnavailable =>
      'Камера не дала свежий кадр. Повторите команду.';

  @override
  String get noAnswerToRepeat => 'Пока нет ответа, который можно повторить.';

  @override
  String get describeDirectionFrontPrompt => 'Опиши что впереди';

  @override
  String get describeDirectionLeftPrompt => 'Опиши что слева';

  @override
  String get describeDirectionRightPrompt => 'Опиши что справа';

  @override
  String get describeDirectionBackPrompt => 'Опиши что сзади';

  @override
  String get describeDirectionAroundPrompt => 'Опиши что вокруг';

  @override
  String get navModeAlreadyEnabled => 'Режим маршрута уже включен.';

  @override
  String get navNoLocationPermission =>
      'Нет доступа к геопозиции. Разрешите локацию.';

  @override
  String get navModeEnabled => 'Режим маршрута включен.';

  @override
  String get navModeDisabled => 'Режим маршрута выключен.';

  @override
  String get navEnableFirst => 'Сначала включите режим маршрута.';

  @override
  String get navSayDestinationAfterRouteWords =>
      'Скажите адрес назначения после слов маршрут до.';

  @override
  String navConfirmAddressQuestion(Object address) {
    return 'Правильно ли адрес: $address?';
  }

  @override
  String get navSayCorrectAddressNow => 'Продиктуйте правильный адрес.';

  @override
  String get navAnswerYesOrNoOrAddress =>
      'Скажите: да, правильно. Или нет и продиктуйте правильный адрес.';

  @override
  String get navLocationUnavailable => 'Не удалось получить вашу геопозицию.';

  @override
  String get navAddressNotFoundAstana =>
      'Не нашла адрес в Астане. Назовите другой адрес.';

  @override
  String get navFoundMultipleVariantsIntro => 'Нашла несколько вариантов.';

  @override
  String get navSayOptionFirstSecondThird =>
      'Скажите: первый, второй или третий.';

  @override
  String get navNoVariantsToChoose => 'Сейчас нет вариантов адреса для выбора.';

  @override
  String get navInvalidVariantNumber =>
      'Такого номера нет. Скажите первый, второй или третий.';

  @override
  String get navNoVariantsToCancel => 'Сейчас нет списка вариантов для отмены.';

  @override
  String get navDictateAnotherAddress =>
      'Хорошо. Продиктуйте другой адрес в Астане.';

  @override
  String get navRouteStopped => 'Маршрут остановлен.';

  @override
  String get navNoActiveRoute => 'Сейчас нет активного маршрута.';

  @override
  String get navRouteNotStarted => 'Маршрут не запущен.';

  @override
  String get navRouteAlmostCompleted => 'Маршрут почти завершен.';

  @override
  String get navRouteBuilt => 'Маршрут построен.';

  @override
  String get navRouteBuildFailedOpenExternal =>
      'Не удалось построить встроенный маршрут. Открываю внешний навигатор.';

  @override
  String get navRouteBuildFailed =>
      'Не удалось построить маршрут. Проверьте интернет или повторите запрос.';

  @override
  String get navArrivedDestination => 'Вы прибыли в точку назначения.';

  @override
  String get navRouteRerouted => 'Маршрут перестроен.';

  @override
  String get navKeepCurrentRoute => 'Двигайтесь по текущему маршруту.';

  @override
  String navSummaryDistanceInstruction(Object distance, Object instruction) {
    return 'До цели $distance. $instruction';
  }

  @override
  String navRouteBuiltWithEta(Object distance, Object etaPart) {
    return 'Маршрут построен. Дистанция $distance$etaPart';
  }

  @override
  String navEtaPart(int minutes) {
    return ', примерно $minutes минут.';
  }

  @override
  String navVariantItem(int number, Object label) {
    return '$number: $label.';
  }

  @override
  String distanceFullMeters(Object value) {
    return '$value метров';
  }

  @override
  String distanceFullKilometers(Object value) {
    return '$value километра';
  }

  @override
  String distanceShortMeters(Object value) {
    return '$value м';
  }

  @override
  String distanceShortKilometers(Object value) {
    return '$value км';
  }

  @override
  String get instructionArrive => 'Вы на месте.';

  @override
  String get instructionArrivedToDestination =>
      'Вы прибыли в точку назначения.';

  @override
  String instructionDistanceToDestination(Object distance) {
    return 'До точки назначения осталось $distance.';
  }

  @override
  String instructionInDistance(Object distance, Object instruction) {
    return 'Через $distance $instruction';
  }

  @override
  String get instructionTurnLeft => 'Поверните налево.';

  @override
  String get instructionTurnRight => 'Поверните направо.';

  @override
  String get instructionUTurn => 'Развернитесь, когда это будет безопасно.';

  @override
  String get instructionGoStraight => 'Двигайтесь прямо.';

  @override
  String get routeTitleFallback => 'Адрес';

  @override
  String get routeAstanaOnly =>
      'Сейчас поддерживаются только маршруты по Астане.';

  @override
  String get routeNotFound => 'Маршрут не найден';

  @override
  String get routeInsufficientData => 'Недостаточно данных маршрута';

  @override
  String get routeCityAstana => 'Астана';

  @override
  String get blindSystemPromptRu =>
      'Ты ассистент для незрячего пользователя. Отвечай коротко и по делу. Не задавай уточняющих вопросов. Если не хватает данных — честно скажи что без камеры не видишь и предложи включить камеру позже.';

  @override
  String get blindSystemPromptKk =>
      'Сен көру қабілеті шектеулі адамға арналған ассистентсің. Қысқа әрі нақты жауап бер. Қосымша сұрақ қойма. Дерек жетпесе, камерасыз көрмейтініңді ашық айт және камераны кейін қосуды ұсын.';

  @override
  String get visionSystemPromptRu =>
      'Ты ассистент для незрячего пользователя. Опиши изображение по делу, дружелюбно и понятно. Ответ не длиннее 2 коротких предложений. Если пользователь просит, можно коротко или подробнее. Не задавай уточняющих вопросов. Если что-то не видно, честно скажи об этом.';

  @override
  String get visionSystemPromptKk =>
      'Сен көру қабілеті шектеулі адамға арналған ассистентсің. Көріністі нақты, түсінікті және жылы түрде сипатта. Жауап 2 қысқа сөйлемнен аспасын. Пайдаланушы сұраса, қысқа не толығырақ айтуға болады. Қосымша сұрақ қойма. Бірдеңе көрінбесе, оны ашық айт.';
}
