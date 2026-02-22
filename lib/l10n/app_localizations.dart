import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_kk.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('kk'),
    Locale('ru'),
  ];

  /// No description provided for @appName.
  ///
  /// In ru, this message translates to:
  /// **'Janarym'**
  String get appName;

  /// No description provided for @languagePickerLabel.
  ///
  /// In ru, this message translates to:
  /// **'Язык'**
  String get languagePickerLabel;

  /// No description provided for @languageRu.
  ///
  /// In ru, this message translates to:
  /// **'Русский'**
  String get languageRu;

  /// No description provided for @languageKk.
  ///
  /// In ru, this message translates to:
  /// **'Қазақша'**
  String get languageKk;

  /// No description provided for @languageShortRu.
  ///
  /// In ru, this message translates to:
  /// **'RU'**
  String get languageShortRu;

  /// No description provided for @languageShortKk.
  ///
  /// In ru, this message translates to:
  /// **'KZ'**
  String get languageShortKk;

  /// No description provided for @checkingMic.
  ///
  /// In ru, this message translates to:
  /// **'Проверяю микрофон...'**
  String get checkingMic;

  /// No description provided for @checkingCamera.
  ///
  /// In ru, this message translates to:
  /// **'Проверяю камеру...'**
  String get checkingCamera;

  /// No description provided for @micAvailable.
  ///
  /// In ru, this message translates to:
  /// **'Микрофон доступен.'**
  String get micAvailable;

  /// No description provided for @micAccessDenied.
  ///
  /// In ru, this message translates to:
  /// **'Доступ к микрофону запрещён. Разрешите в настройках приложения.'**
  String get micAccessDenied;

  /// No description provided for @micAccessRequired.
  ///
  /// In ru, this message translates to:
  /// **'Нужен доступ к микрофону для голосовых команд.'**
  String get micAccessRequired;

  /// No description provided for @cameraAvailable.
  ///
  /// In ru, this message translates to:
  /// **'Камера доступна.'**
  String get cameraAvailable;

  /// No description provided for @cameraAccessDenied.
  ///
  /// In ru, this message translates to:
  /// **'Доступ к камере запрещён. Разрешите в настройках приложения.'**
  String get cameraAccessDenied;

  /// No description provided for @cameraAccessRequired.
  ///
  /// In ru, this message translates to:
  /// **'Нужен доступ к камере для описания окружения.'**
  String get cameraAccessRequired;

  /// No description provided for @cameraNotFound.
  ///
  /// In ru, this message translates to:
  /// **'Камера не найдена.'**
  String get cameraNotFound;

  /// No description provided for @cameraLiveOn.
  ///
  /// In ru, this message translates to:
  /// **'Камера: включена'**
  String get cameraLiveOn;

  /// No description provided for @cameraLiveOff.
  ///
  /// In ru, this message translates to:
  /// **'Камера: выключена'**
  String get cameraLiveOff;

  /// No description provided for @cameraStartFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось запустить камеру: {error}'**
  String cameraStartFailed(Object error);

  /// No description provided for @errorOpenAiKeyMissing.
  ///
  /// In ru, this message translates to:
  /// **'OPENAI_API_KEY не задан (проверь .env)'**
  String get errorOpenAiKeyMissing;

  /// No description provided for @errorEmptyImageFrame.
  ///
  /// In ru, this message translates to:
  /// **'Пустой кадр изображения.'**
  String get errorEmptyImageFrame;

  /// No description provided for @errorExtractTextFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось извлечь текст ответа.'**
  String get errorExtractTextFailed;

  /// No description provided for @sttNoMicPermission.
  ///
  /// In ru, this message translates to:
  /// **'Нет доступа к микрофону для записи'**
  String get sttNoMicPermission;

  /// No description provided for @sttStartFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось запустить распознавание речи: {error}'**
  String sttStartFailed(Object error);

  /// No description provided for @sttGenericError.
  ///
  /// In ru, this message translates to:
  /// **'Ошибка распознавания речи: {error}'**
  String sttGenericError(Object error);

  /// No description provided for @modeNavigation.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута'**
  String get modeNavigation;

  /// No description provided for @modeGeneral.
  ///
  /// In ru, this message translates to:
  /// **'Обычный режим'**
  String get modeGeneral;

  /// No description provided for @statusWaitingReply.
  ///
  /// In ru, this message translates to:
  /// **'Жду вашего ответа'**
  String get statusWaitingReply;

  /// No description provided for @embeddedMapDisabled.
  ///
  /// In ru, this message translates to:
  /// **'Встроенная карта временно отключена для стабильности. Навигация и голосовые инструкции работают.'**
  String get embeddedMapDisabled;

  /// No description provided for @panelStatusPrefix.
  ///
  /// In ru, this message translates to:
  /// **'Статус'**
  String get panelStatusPrefix;

  /// No description provided for @panelTargetPrefix.
  ///
  /// In ru, this message translates to:
  /// **'Цель'**
  String get panelTargetPrefix;

  /// No description provided for @panelErrorPrefix.
  ///
  /// In ru, this message translates to:
  /// **'Ошибка'**
  String get panelErrorPrefix;

  /// No description provided for @navStatusIdle.
  ///
  /// In ru, this message translates to:
  /// **'ожидание'**
  String get navStatusIdle;

  /// No description provided for @navStatusResolvingDestination.
  ///
  /// In ru, this message translates to:
  /// **'поиск адреса'**
  String get navStatusResolvingDestination;

  /// No description provided for @navStatusAwaitingChoice.
  ///
  /// In ru, this message translates to:
  /// **'ожидание выбора'**
  String get navStatusAwaitingChoice;

  /// No description provided for @navStatusBuildingRoute.
  ///
  /// In ru, this message translates to:
  /// **'построение маршрута'**
  String get navStatusBuildingRoute;

  /// No description provided for @navStatusNavigating.
  ///
  /// In ru, this message translates to:
  /// **'в пути'**
  String get navStatusNavigating;

  /// No description provided for @navStatusRerouting.
  ///
  /// In ru, this message translates to:
  /// **'перестроение'**
  String get navStatusRerouting;

  /// No description provided for @navStatusCompleted.
  ///
  /// In ru, this message translates to:
  /// **'завершен'**
  String get navStatusCompleted;

  /// No description provided for @navStatusError.
  ///
  /// In ru, this message translates to:
  /// **'ошибка'**
  String get navStatusError;

  /// No description provided for @markerFinish.
  ///
  /// In ru, this message translates to:
  /// **'Финиш'**
  String get markerFinish;

  /// No description provided for @markerYou.
  ///
  /// In ru, this message translates to:
  /// **'Вы'**
  String get markerYou;

  /// No description provided for @circleLabelWake.
  ///
  /// In ru, this message translates to:
  /// **'Скажите «Жанарым»'**
  String get circleLabelWake;

  /// No description provided for @circleLabelListening.
  ///
  /// In ru, this message translates to:
  /// **'Слушаю'**
  String get circleLabelListening;

  /// No description provided for @circleLabelThinking.
  ///
  /// In ru, this message translates to:
  /// **'Думаю'**
  String get circleLabelThinking;

  /// No description provided for @circleLabelSpeaking.
  ///
  /// In ru, this message translates to:
  /// **'Говорю'**
  String get circleLabelSpeaking;

  /// No description provided for @circleLabelReady.
  ///
  /// In ru, this message translates to:
  /// **'Готов к работе'**
  String get circleLabelReady;

  /// No description provided for @circleStatusWake.
  ///
  /// In ru, this message translates to:
  /// **'ОЖИДАНИЕ'**
  String get circleStatusWake;

  /// No description provided for @circleStatusListening.
  ///
  /// In ru, this message translates to:
  /// **'СЛУШАЮ'**
  String get circleStatusListening;

  /// No description provided for @circleStatusThinking.
  ///
  /// In ru, this message translates to:
  /// **'ДУМАЮ'**
  String get circleStatusThinking;

  /// No description provided for @circleStatusSpeaking.
  ///
  /// In ru, this message translates to:
  /// **'ГОВОРЮ'**
  String get circleStatusSpeaking;

  /// No description provided for @circleStatusReady.
  ///
  /// In ru, this message translates to:
  /// **'ГОТОВО'**
  String get circleStatusReady;

  /// No description provided for @commandProcessingFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось обработать команду. Попробуйте снова.'**
  String get commandProcessingFailed;

  /// No description provided for @enableRouteModeFirst.
  ///
  /// In ru, this message translates to:
  /// **'Сначала включите режим маршрута.'**
  String get enableRouteModeFirst;

  /// No description provided for @routeModeDescribeBlocked.
  ///
  /// In ru, this message translates to:
  /// **'Сейчас включен режим маршрута. Выйдите из режима маршрута для команд описания.'**
  String get routeModeDescribeBlocked;

  /// No description provided for @didntHearCommandRepeat.
  ///
  /// In ru, this message translates to:
  /// **'Не расслышала команду. Повторите, пожалуйста.'**
  String get didntHearCommandRepeat;

  /// No description provided for @sayAddressAfterRoutePhrase.
  ///
  /// In ru, this message translates to:
  /// **'Скажите адрес после слов: маршрут до...'**
  String get sayAddressAfterRoutePhrase;

  /// No description provided for @unknownRouteCommandHelp.
  ///
  /// In ru, this message translates to:
  /// **'Не поняла команду. Скажите адрес назначения или: что дальше, статус маршрута, стоп маршрут.'**
  String get unknownRouteCommandHelp;

  /// No description provided for @followUpNeedAnythingElse.
  ///
  /// In ru, this message translates to:
  /// **'Нужно ли еще что-нибудь?'**
  String get followUpNeedAnythingElse;

  /// No description provided for @routeModeAlreadyEnabled.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута уже включен.'**
  String get routeModeAlreadyEnabled;

  /// No description provided for @routeModeNotEnabled.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута не включен.'**
  String get routeModeNotEnabled;

  /// No description provided for @noCameraAccess.
  ///
  /// In ru, this message translates to:
  /// **'Нет доступа к камере.'**
  String get noCameraAccess;

  /// No description provided for @fastFrameUnavailable.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось быстро получить кадр. Повторите команду.'**
  String get fastFrameUnavailable;

  /// No description provided for @frameUnavailable.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось получить кадр с камеры. Повторите команду.'**
  String get frameUnavailable;

  /// No description provided for @staleFrameUnavailable.
  ///
  /// In ru, this message translates to:
  /// **'Камера не дала свежий кадр. Повторите команду.'**
  String get staleFrameUnavailable;

  /// No description provided for @noAnswerToRepeat.
  ///
  /// In ru, this message translates to:
  /// **'Пока нет ответа, который можно повторить.'**
  String get noAnswerToRepeat;

  /// No description provided for @describeDirectionFrontPrompt.
  ///
  /// In ru, this message translates to:
  /// **'Опиши что впереди'**
  String get describeDirectionFrontPrompt;

  /// No description provided for @describeDirectionLeftPrompt.
  ///
  /// In ru, this message translates to:
  /// **'Опиши что слева'**
  String get describeDirectionLeftPrompt;

  /// No description provided for @describeDirectionRightPrompt.
  ///
  /// In ru, this message translates to:
  /// **'Опиши что справа'**
  String get describeDirectionRightPrompt;

  /// No description provided for @describeDirectionBackPrompt.
  ///
  /// In ru, this message translates to:
  /// **'Опиши что сзади'**
  String get describeDirectionBackPrompt;

  /// No description provided for @describeDirectionAroundPrompt.
  ///
  /// In ru, this message translates to:
  /// **'Опиши что вокруг'**
  String get describeDirectionAroundPrompt;

  /// No description provided for @navModeAlreadyEnabled.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута уже включен.'**
  String get navModeAlreadyEnabled;

  /// No description provided for @navNoLocationPermission.
  ///
  /// In ru, this message translates to:
  /// **'Нет доступа к геопозиции. Разрешите локацию.'**
  String get navNoLocationPermission;

  /// No description provided for @navModeEnabled.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута включен.'**
  String get navModeEnabled;

  /// No description provided for @navModeDisabled.
  ///
  /// In ru, this message translates to:
  /// **'Режим маршрута выключен.'**
  String get navModeDisabled;

  /// No description provided for @navEnableFirst.
  ///
  /// In ru, this message translates to:
  /// **'Сначала включите режим маршрута.'**
  String get navEnableFirst;

  /// No description provided for @navSayDestinationAfterRouteWords.
  ///
  /// In ru, this message translates to:
  /// **'Скажите адрес назначения после слов маршрут до.'**
  String get navSayDestinationAfterRouteWords;

  /// No description provided for @navConfirmAddressQuestion.
  ///
  /// In ru, this message translates to:
  /// **'Правильно ли адрес: {address}?'**
  String navConfirmAddressQuestion(Object address);

  /// No description provided for @navSayCorrectAddressNow.
  ///
  /// In ru, this message translates to:
  /// **'Продиктуйте правильный адрес.'**
  String get navSayCorrectAddressNow;

  /// No description provided for @navAnswerYesOrNoOrAddress.
  ///
  /// In ru, this message translates to:
  /// **'Скажите: да, правильно. Или нет и продиктуйте правильный адрес.'**
  String get navAnswerYesOrNoOrAddress;

  /// No description provided for @navLocationUnavailable.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось получить вашу геопозицию.'**
  String get navLocationUnavailable;

  /// No description provided for @navAddressNotFoundAstana.
  ///
  /// In ru, this message translates to:
  /// **'Не нашла адрес в Астане. Назовите другой адрес.'**
  String get navAddressNotFoundAstana;

  /// No description provided for @navFoundMultipleVariantsIntro.
  ///
  /// In ru, this message translates to:
  /// **'Нашла несколько вариантов.'**
  String get navFoundMultipleVariantsIntro;

  /// No description provided for @navSayOptionFirstSecondThird.
  ///
  /// In ru, this message translates to:
  /// **'Скажите: первый, второй или третий.'**
  String get navSayOptionFirstSecondThird;

  /// No description provided for @navNoVariantsToChoose.
  ///
  /// In ru, this message translates to:
  /// **'Сейчас нет вариантов адреса для выбора.'**
  String get navNoVariantsToChoose;

  /// No description provided for @navInvalidVariantNumber.
  ///
  /// In ru, this message translates to:
  /// **'Такого номера нет. Скажите первый, второй или третий.'**
  String get navInvalidVariantNumber;

  /// No description provided for @navNoVariantsToCancel.
  ///
  /// In ru, this message translates to:
  /// **'Сейчас нет списка вариантов для отмены.'**
  String get navNoVariantsToCancel;

  /// No description provided for @navDictateAnotherAddress.
  ///
  /// In ru, this message translates to:
  /// **'Хорошо. Продиктуйте другой адрес в Астане.'**
  String get navDictateAnotherAddress;

  /// No description provided for @navRouteStopped.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут остановлен.'**
  String get navRouteStopped;

  /// No description provided for @navNoActiveRoute.
  ///
  /// In ru, this message translates to:
  /// **'Сейчас нет активного маршрута.'**
  String get navNoActiveRoute;

  /// No description provided for @navRouteNotStarted.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут не запущен.'**
  String get navRouteNotStarted;

  /// No description provided for @navRouteAlmostCompleted.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут почти завершен.'**
  String get navRouteAlmostCompleted;

  /// No description provided for @navRouteBuilt.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут построен.'**
  String get navRouteBuilt;

  /// No description provided for @navRouteBuildFailedOpenExternal.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось построить встроенный маршрут. Открываю внешний навигатор.'**
  String get navRouteBuildFailedOpenExternal;

  /// No description provided for @navRouteBuildFailed.
  ///
  /// In ru, this message translates to:
  /// **'Не удалось построить маршрут. Проверьте интернет или повторите запрос.'**
  String get navRouteBuildFailed;

  /// No description provided for @navArrivedDestination.
  ///
  /// In ru, this message translates to:
  /// **'Вы прибыли в точку назначения.'**
  String get navArrivedDestination;

  /// No description provided for @navRouteRerouted.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут перестроен.'**
  String get navRouteRerouted;

  /// No description provided for @navKeepCurrentRoute.
  ///
  /// In ru, this message translates to:
  /// **'Двигайтесь по текущему маршруту.'**
  String get navKeepCurrentRoute;

  /// No description provided for @navSummaryDistanceInstruction.
  ///
  /// In ru, this message translates to:
  /// **'До цели {distance}. {instruction}'**
  String navSummaryDistanceInstruction(Object distance, Object instruction);

  /// No description provided for @navRouteBuiltWithEta.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут построен. Дистанция {distance}{etaPart}'**
  String navRouteBuiltWithEta(Object distance, Object etaPart);

  /// No description provided for @navEtaPart.
  ///
  /// In ru, this message translates to:
  /// **', примерно {minutes} минут.'**
  String navEtaPart(int minutes);

  /// No description provided for @navVariantItem.
  ///
  /// In ru, this message translates to:
  /// **'{number}: {label}.'**
  String navVariantItem(int number, Object label);

  /// No description provided for @distanceFullMeters.
  ///
  /// In ru, this message translates to:
  /// **'{value} метров'**
  String distanceFullMeters(Object value);

  /// No description provided for @distanceFullKilometers.
  ///
  /// In ru, this message translates to:
  /// **'{value} километра'**
  String distanceFullKilometers(Object value);

  /// No description provided for @distanceShortMeters.
  ///
  /// In ru, this message translates to:
  /// **'{value} м'**
  String distanceShortMeters(Object value);

  /// No description provided for @distanceShortKilometers.
  ///
  /// In ru, this message translates to:
  /// **'{value} км'**
  String distanceShortKilometers(Object value);

  /// No description provided for @instructionArrive.
  ///
  /// In ru, this message translates to:
  /// **'Вы на месте.'**
  String get instructionArrive;

  /// No description provided for @instructionArrivedToDestination.
  ///
  /// In ru, this message translates to:
  /// **'Вы прибыли в точку назначения.'**
  String get instructionArrivedToDestination;

  /// No description provided for @instructionDistanceToDestination.
  ///
  /// In ru, this message translates to:
  /// **'До точки назначения осталось {distance}.'**
  String instructionDistanceToDestination(Object distance);

  /// No description provided for @instructionInDistance.
  ///
  /// In ru, this message translates to:
  /// **'Через {distance} {instruction}'**
  String instructionInDistance(Object distance, Object instruction);

  /// No description provided for @instructionTurnLeft.
  ///
  /// In ru, this message translates to:
  /// **'Поверните налево.'**
  String get instructionTurnLeft;

  /// No description provided for @instructionTurnRight.
  ///
  /// In ru, this message translates to:
  /// **'Поверните направо.'**
  String get instructionTurnRight;

  /// No description provided for @instructionUTurn.
  ///
  /// In ru, this message translates to:
  /// **'Развернитесь, когда это будет безопасно.'**
  String get instructionUTurn;

  /// No description provided for @instructionGoStraight.
  ///
  /// In ru, this message translates to:
  /// **'Двигайтесь прямо.'**
  String get instructionGoStraight;

  /// No description provided for @routeTitleFallback.
  ///
  /// In ru, this message translates to:
  /// **'Адрес'**
  String get routeTitleFallback;

  /// No description provided for @routeAstanaOnly.
  ///
  /// In ru, this message translates to:
  /// **'Сейчас поддерживаются только маршруты по Астане.'**
  String get routeAstanaOnly;

  /// No description provided for @routeNotFound.
  ///
  /// In ru, this message translates to:
  /// **'Маршрут не найден'**
  String get routeNotFound;

  /// No description provided for @routeInsufficientData.
  ///
  /// In ru, this message translates to:
  /// **'Недостаточно данных маршрута'**
  String get routeInsufficientData;

  /// No description provided for @routeCityAstana.
  ///
  /// In ru, this message translates to:
  /// **'Астана'**
  String get routeCityAstana;

  /// No description provided for @blindSystemPromptRu.
  ///
  /// In ru, this message translates to:
  /// **'Ты ассистент для незрячего пользователя. Отвечай коротко и по делу. Не задавай уточняющих вопросов. Если не хватает данных — честно скажи что без камеры не видишь и предложи включить камеру позже.'**
  String get blindSystemPromptRu;

  /// No description provided for @blindSystemPromptKk.
  ///
  /// In ru, this message translates to:
  /// **'Сен көру қабілеті шектеулі адамға арналған ассистентсің. Қысқа әрі нақты жауап бер. Қосымша сұрақ қойма. Дерек жетпесе, камерасыз көрмейтініңді ашық айт және камераны кейін қосуды ұсын.'**
  String get blindSystemPromptKk;

  /// No description provided for @visionSystemPromptRu.
  ///
  /// In ru, this message translates to:
  /// **'Ты ассистент для незрячего пользователя. Опиши изображение по делу, дружелюбно и понятно. Ответ не длиннее 2 коротких предложений. Если пользователь просит, можно коротко или подробнее. Не задавай уточняющих вопросов. Если что-то не видно, честно скажи об этом.'**
  String get visionSystemPromptRu;

  /// No description provided for @visionSystemPromptKk.
  ///
  /// In ru, this message translates to:
  /// **'Сен көру қабілеті шектеулі адамға арналған ассистентсің. Көріністі нақты, түсінікті және жылы түрде сипатта. Жауап 2 қысқа сөйлемнен аспасын. Пайдаланушы сұраса, қысқа не толығырақ айтуға болады. Қосымша сұрақ қойма. Бірдеңе көрінбесе, оны ашық айт.'**
  String get visionSystemPromptKk;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['kk', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'kk':
      return AppLocalizationsKk();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
