// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Kazakh (`kk`).
class AppLocalizationsKk extends AppLocalizations {
  AppLocalizationsKk([String locale = 'kk']) : super(locale);

  @override
  String get appName => 'Janarym';

  @override
  String get languagePickerLabel => 'Тіл';

  @override
  String get languageRu => 'Русский';

  @override
  String get languageKk => 'Қазақша';

  @override
  String get languageShortRu => 'RU';

  @override
  String get languageShortKk => 'KZ';

  @override
  String get checkingMic => 'Микрофон тексерілуде...';

  @override
  String get checkingCamera => 'Камера тексерілуде...';

  @override
  String get micAvailable => 'Микрофон қолжетімді.';

  @override
  String get micAccessDenied =>
      'Микрофонға рұқсат берілмеген. Қолданба баптауларынан рұқсат беріңіз.';

  @override
  String get micAccessRequired =>
      'Дауыстық командалар үшін микрофонға рұқсат қажет.';

  @override
  String get cameraAvailable => 'Камера қолжетімді.';

  @override
  String get cameraAccessDenied =>
      'Камераға рұқсат берілмеген. Қолданба баптауларынан рұқсат беріңіз.';

  @override
  String get cameraAccessRequired =>
      'Айналаны сипаттау үшін камераға рұқсат қажет.';

  @override
  String get cameraNotFound => 'Камера табылмады.';

  @override
  String get cameraLiveOn => 'Камера: қосулы';

  @override
  String get cameraLiveOff => 'Камера: өшірулі';

  @override
  String cameraStartFailed(Object error) {
    return 'Камераны іске қосу мүмкін болмады: $error';
  }

  @override
  String get errorOpenAiKeyMissing =>
      'OPENAI_API_KEY берілмеген (.env файлын тексеріңіз)';

  @override
  String get errorEmptyImageFrame => 'Кадр бос.';

  @override
  String get errorExtractTextFailed => 'Жауап мәтінін алу мүмкін болмады.';

  @override
  String get sttNoMicPermission => 'Жазу үшін микрофонға рұқсат жоқ';

  @override
  String sttStartFailed(Object error) {
    return 'Сөйлеуді тануды іске қосу мүмкін болмады: $error';
  }

  @override
  String sttGenericError(Object error) {
    return 'Сөйлеуді тану қатесі: $error';
  }

  @override
  String get modeNavigation => 'Маршрут режимі';

  @override
  String get modeGeneral => 'Қалыпты режим';

  @override
  String get statusWaitingReply => 'Жауабыңызды күтемін';

  @override
  String get embeddedMapDisabled =>
      'Тұрақтылық үшін кірістірілген карта уақытша өшірілген. Навигация мен дауыстық нұсқаулар жұмыс істейді.';

  @override
  String get panelStatusPrefix => 'Күйі';

  @override
  String get panelTargetPrefix => 'Мақсат';

  @override
  String get panelErrorPrefix => 'Қате';

  @override
  String get navStatusIdle => 'күту';

  @override
  String get navStatusResolvingDestination => 'мекенжайды іздеу';

  @override
  String get navStatusAwaitingChoice => 'таңдауды күту';

  @override
  String get navStatusBuildingRoute => 'маршрут құру';

  @override
  String get navStatusNavigating => 'жолда';

  @override
  String get navStatusRerouting => 'қайта құру';

  @override
  String get navStatusCompleted => 'аяқталды';

  @override
  String get navStatusError => 'қате';

  @override
  String get markerFinish => 'Мәреге';

  @override
  String get markerYou => 'Сіз';

  @override
  String get circleLabelWake => '«Жанарым» деп айтыңыз';

  @override
  String get circleLabelListening => 'Тыңдап тұрмын';

  @override
  String get circleLabelThinking => 'Ойланып тұрмын';

  @override
  String get circleLabelSpeaking => 'Сөйлеп тұрмын';

  @override
  String get circleLabelReady => 'Жұмысқа дайын';

  @override
  String get circleStatusWake => 'КҮТУ';

  @override
  String get circleStatusListening => 'ТЫҢДАУ';

  @override
  String get circleStatusThinking => 'ОЙЛАУ';

  @override
  String get circleStatusSpeaking => 'СӨЙЛЕУ';

  @override
  String get circleStatusReady => 'ДАЙЫН';

  @override
  String get commandProcessingFailed =>
      'Команданы өңдеу мүмкін болмады. Қайта көріңіз.';

  @override
  String get enableRouteModeFirst => 'Алдымен маршрут режимін қосыңыз.';

  @override
  String get routeModeDescribeBlocked =>
      'Қазір маршрут режимі қосулы. Сипаттау командалары үшін режимнен шығыңыз.';

  @override
  String get didntHearCommandRepeat => 'Команданы естімедім. Қайталап айтыңыз.';

  @override
  String get sayAddressAfterRoutePhrase =>
      'Мекенжайды «маршрут до...» сөздерінен кейін айтыңыз.';

  @override
  String get unknownRouteCommandHelp =>
      'Команданы түсінбедім. Мекенжай айтыңыз немесе: әрі қарай не, маршрут күйі, маршрутты тоқтат.';

  @override
  String get followUpNeedAnythingElse => 'Тағы бірдеңе керек пе?';

  @override
  String get routeModeAlreadyEnabled => 'Маршрут режимі әлдеқашан қосулы.';

  @override
  String get routeModeNotEnabled => 'Маршрут режимі қосылмаған.';

  @override
  String get noCameraAccess => 'Камераға рұқсат жоқ.';

  @override
  String get fastFrameUnavailable =>
      'Кадрды жылдам алу мүмкін болмады. Команданы қайталаңыз.';

  @override
  String get frameUnavailable =>
      'Камерадан кадр алу мүмкін болмады. Команданы қайталаңыз.';

  @override
  String get staleFrameUnavailable =>
      'Камера жаңа кадр бермеді. Команданы қайталаңыз.';

  @override
  String get noAnswerToRepeat => 'Қайталайтын жауап әлі жоқ.';

  @override
  String get describeDirectionFrontPrompt => 'Алдыңдағыны сипатта';

  @override
  String get describeDirectionLeftPrompt => 'Сол жақтағыны сипатта';

  @override
  String get describeDirectionRightPrompt => 'Оң жақтағыны сипатта';

  @override
  String get describeDirectionBackPrompt => 'Арттағыны сипатта';

  @override
  String get describeDirectionAroundPrompt => 'Айналаны сипатта';

  @override
  String get navModeAlreadyEnabled => 'Маршрут режимі әлдеқашан қосулы.';

  @override
  String get navNoLocationPermission =>
      'Геолокацияға рұқсат жоқ. Локацияға рұқсат беріңіз.';

  @override
  String get navModeEnabled => 'Маршрут режимі қосылды.';

  @override
  String get navModeDisabled => 'Маршрут режимі өшірілді.';

  @override
  String get navEnableFirst => 'Алдымен маршрут режимін қосыңыз.';

  @override
  String get navSayDestinationAfterRouteWords =>
      '«маршрут до» сөздерінен кейін мекенжай айтыңыз.';

  @override
  String navConfirmAddressQuestion(Object address) {
    return 'Мекенжай дұрыс па: $address?';
  }

  @override
  String get navSayCorrectAddressNow => 'Дұрыс мекенжайды айтыңыз.';

  @override
  String get navAnswerYesOrNoOrAddress =>
      'Айтыңыз: иә, дұрыс. Немесе жоқ деп, дұрыс мекенжайды айтыңыз.';

  @override
  String get navLocationUnavailable =>
      'Сіздің геопозицияңызды алу мүмкін болмады.';

  @override
  String get navAddressNotFoundAstana =>
      'Астанадан мұндай мекенжай табылмады. Басқа мекенжай айтыңыз.';

  @override
  String get navFoundMultipleVariantsIntro => 'Бірнеше нұсқа табылды.';

  @override
  String get navSayOptionFirstSecondThird =>
      'Біріншісі, екіншісі немесе үшіншісі деп айтыңыз.';

  @override
  String get navNoVariantsToChoose => 'Таңдайтын мекенжай нұсқалары қазір жоқ.';

  @override
  String get navInvalidVariantNumber =>
      'Мұндай нөмір жоқ. Біріншісі, екіншісі немесе үшіншісі деп айтыңыз.';

  @override
  String get navNoVariantsToCancel => 'Бас тартатын нұсқалар тізімі қазір жоқ.';

  @override
  String get navDictateAnotherAddress =>
      'Жақсы. Астанадағы басқа мекенжайды айтыңыз.';

  @override
  String get navRouteStopped => 'Маршрут тоқтатылды.';

  @override
  String get navNoActiveRoute => 'Қазір белсенді маршрут жоқ.';

  @override
  String get navRouteNotStarted => 'Маршрут іске қосылмаған.';

  @override
  String get navRouteAlmostCompleted => 'Маршрут аяқталуға жақын.';

  @override
  String get navRouteBuilt => 'Маршрут құрылды.';

  @override
  String get navRouteBuildFailedOpenExternal =>
      'Кірістірілген маршрутты құру мүмкін болмады. Сыртқы навигаторды ашамын.';

  @override
  String get navRouteBuildFailed =>
      'Маршрутты құру мүмкін болмады. Интернетті тексеріңіз немесе сұрауды қайталаңыз.';

  @override
  String get navArrivedDestination => 'Сіз межеге жеттіңіз.';

  @override
  String get navRouteRerouted => 'Маршрут қайта құрылды.';

  @override
  String get navKeepCurrentRoute => 'Қазіргі маршрутпен жүре беріңіз.';

  @override
  String navSummaryDistanceInstruction(Object distance, Object instruction) {
    return 'Мақсатқа дейін $distance. $instruction';
  }

  @override
  String navRouteBuiltWithEta(Object distance, Object etaPart) {
    return 'Маршрут құрылды. Қашықтық $distance$etaPart';
  }

  @override
  String navEtaPart(int minutes) {
    return ', шамамен $minutes минут.';
  }

  @override
  String navVariantItem(int number, Object label) {
    return '$number: $label.';
  }

  @override
  String distanceFullMeters(Object value) {
    return '$value метр';
  }

  @override
  String distanceFullKilometers(Object value) {
    return '$value км';
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
  String get instructionArrive => 'Межеге жеттіңіз.';

  @override
  String get instructionArrivedToDestination => 'Сіз межеге жеттіңіз.';

  @override
  String instructionDistanceToDestination(Object distance) {
    return 'Межеге дейін $distance қалды.';
  }

  @override
  String instructionInDistance(Object distance, Object instruction) {
    return '$distance кейін $instruction';
  }

  @override
  String get instructionTurnLeft => 'Солға бұрылыңыз.';

  @override
  String get instructionTurnRight => 'Оңға бұрылыңыз.';

  @override
  String get instructionUTurn => 'Қауіпсіз болғанда кері бұрылыңыз.';

  @override
  String get instructionGoStraight => 'Тура жүріңіз.';

  @override
  String get routeTitleFallback => 'Мекенжай';

  @override
  String get routeAstanaOnly =>
      'Қазір тек Астана бойынша маршруттар қолдау табады.';

  @override
  String get routeNotFound => 'Маршрут табылмады';

  @override
  String get routeInsufficientData => 'Маршрут деректері жеткіліксіз';

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
