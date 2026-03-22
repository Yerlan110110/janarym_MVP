import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/app_locale_controller.dart';
import '../l10n/app_localizations.dart';
import '../navigation/models/transit_models.dart';
import '../navigation/services/dgis_transit_service.dart';
import '../navigation/services/location_provider.dart';
import '../navigation/services/navigation_utils.dart';
import 'models/bus_mode_state.dart';

typedef BusSpeakFn = Future<void> Function(String text);
typedef BusLogFn = void Function(String message);

enum _PendingBusAction { stopRoutes, stopSchedule }

class _BusStopResolution {
  const _BusStopResolution._({this.selectedStop, this.candidates = const []});

  const _BusStopResolution.selected(TransitStopCandidate stop)
    : this._(selectedStop: stop);

  const _BusStopResolution.choices(List<TransitStopCandidate> candidates)
    : this._(candidates: candidates);

  final TransitStopCandidate? selectedStop;
  final List<TransitStopCandidate> candidates;

  bool get hasChoices => candidates.isNotEmpty;
}

class BusModeController {
  BusModeController({
    required BusSpeakFn speak,
    BusLogFn? log,
    NavigationTransitService? transitService,
    NavigationLocationProvider? locationProvider,
    AppLanguage language = AppLanguage.ru,
  }) : _speak = speak,
       _log = log ?? debugPrint,
       _transitService = transitService ?? DgisTransitService(),
       _locationProvider =
           locationProvider ?? const GeolocatorNavigationLocationProvider(),
       _language = language {
    _transitService.setLanguage(language);
  }

  final BusSpeakFn _speak;
  final BusLogFn _log;
  final NavigationTransitService _transitService;
  final NavigationLocationProvider _locationProvider;
  AppLanguage _language;

  final ValueNotifier<BusModeState> state = ValueNotifier(BusModeState.initial);

  StreamSubscription<NavPoint>? _positionSubscription;
  _PendingBusAction _pendingAction = _PendingBusAction.stopRoutes;
  String? _pendingRouteName;

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    _transitService.setLanguage(language);
  }

  Future<void> enterMode({bool speak = true}) async {
    if (state.value.modeEnabled) {
      if (speak) {
        await _speak(_l10n.busModeAlreadyEnabled);
      }
      return;
    }

    final hasPermission = await _locationProvider.ensurePermission();
    if (!hasPermission) {
      final message = _l10n.navNoLocationPermission;
      _log('[BUS] enter denied: no location permission');
      _setState(
        state.value.copyWith(
          modeEnabled: false,
          status: BusModeStatus.error,
          error: message,
        ),
      );
      if (speak) {
        await _speak(message);
      }
      return;
    }

    await _positionSubscription?.cancel();
    _positionSubscription = _locationProvider.positionStream().listen(
      _onLocationUpdate,
      onError: (error) {
        _log('[BUS] location stream error: $error');
      },
    );

    final current = await _locationProvider.getCurrentLocation();
    _setState(
      state.value.copyWith(
        modeEnabled: true,
        status: BusModeStatus.idle,
        currentLocation: current,
        candidates: const [],
        clearError: true,
        clearLastInstruction: true,
      ),
    );
    _log('[BUS] enter');
    if (speak) {
      await _speak(_l10n.busModeEnabled);
    }
  }

  Future<void> exitMode({bool speak = true}) async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _clearPendingAction();
    _setState(BusModeState.initial);
    _log('[BUS] exit');
    if (speak) {
      await _speak(_l10n.busModeDisabled);
    }
  }

  void resetState() {
    _clearPendingAction();
    _setState(
      state.value.copyWith(
        status: BusModeStatus.idle,
        candidates: const [],
        clearError: true,
        clearLastInstruction: true,
      ),
    );
  }

  Future<void> speakStopRoutes(String query) async {
    if (!state.value.modeEnabled) {
      await _speak(_l10n.enableBusModeFirst);
      return;
    }
    final stopQuery = query.trim();
    if (stopQuery.isEmpty) {
      await _speak(_transitSayStopNamePrompt());
      return;
    }
    final current =
        state.value.currentLocation ?? await _ensureCurrentLocation();
    if (current == null) {
      await _speak(_l10n.navLocationUnavailable);
      return;
    }

    try {
      final resolution = await _resolveStopSelection(stopQuery, current);
      if (resolution.selectedStop != null) {
        await _announceStopRoutes(resolution.selectedStop!);
        return;
      }
      if (resolution.hasChoices) {
        _pendingAction = _PendingBusAction.stopRoutes;
        _pendingRouteName = null;
        await _speakCandidateChoices(resolution.candidates);
        return;
      }
      await _speak(_transitStopNotFoundMessage(stopQuery));
    } on TransitServiceUnavailable catch (error) {
      _log('[BUS] routes unavailable: $error');
      await _speak(_transitUnavailableMessage());
    } catch (error) {
      _log('[BUS] routes error: $error');
      await _speak(_transitUnavailableMessage());
    }
  }

  Future<void> speakScheduledArrivals({
    required String stopQuery,
    required String routeName,
  }) async {
    if (!state.value.modeEnabled) {
      await _speak(_l10n.enableBusModeFirst);
      return;
    }
    final cleanStopQuery = stopQuery.trim();
    final cleanRouteName = routeName.trim();
    if (cleanStopQuery.isEmpty || cleanRouteName.isEmpty) {
      await _speak(_transitSchedulePrompt());
      return;
    }
    final current =
        state.value.currentLocation ?? await _ensureCurrentLocation();
    if (current == null) {
      await _speak(_l10n.navLocationUnavailable);
      return;
    }

    try {
      final resolution = await _resolveStopSelection(cleanStopQuery, current);
      if (resolution.selectedStop != null) {
        await _announceStopSchedule(resolution.selectedStop!, cleanRouteName);
        return;
      }
      if (resolution.hasChoices) {
        _pendingAction = _PendingBusAction.stopSchedule;
        _pendingRouteName = cleanRouteName;
        await _speakCandidateChoices(resolution.candidates);
        return;
      }
      await _speak(_transitStopNotFoundMessage(cleanStopQuery));
    } on TransitServiceUnavailable catch (error) {
      _log('[BUS] schedule unavailable: $error');
      await _speak(_transitUnavailableMessage());
    } catch (error) {
      _log('[BUS] schedule error: $error');
      await _speak(_transitUnavailableMessage());
    }
  }

  Future<void> selectCandidate(int index) async {
    final candidates = state.value.candidates;
    if (candidates.isEmpty ||
        state.value.status != BusModeStatus.awaitingChoice) {
      await _speak(_l10n.navNoVariantsToChoose);
      return;
    }
    if (index < 0 || index >= candidates.length) {
      await _speak(_l10n.navInvalidVariantNumber);
      return;
    }

    final selected = candidates[index];
    final routeName = _pendingRouteName;
    final action = _pendingAction;
    _clearPendingAction();

    switch (action) {
      case _PendingBusAction.stopRoutes:
        await _announceStopRoutes(selected);
        return;
      case _PendingBusAction.stopSchedule:
        if (routeName == null || routeName.trim().isEmpty) {
          await _speak(_transitUnavailableMessage());
          return;
        }
        await _announceStopSchedule(selected, routeName.trim());
        return;
    }
  }

  Future<void> rejectCandidateSelection() async {
    final hasChoices =
        state.value.candidates.isNotEmpty &&
        state.value.status == BusModeStatus.awaitingChoice;
    if (!hasChoices) {
      await _speak(_l10n.navNoVariantsToCancel);
      return;
    }

    _clearPendingAction();
    _setState(
      state.value.copyWith(
        status: BusModeStatus.idle,
        candidates: const [],
        clearError: true,
        clearLastInstruction: true,
      ),
    );
    await _speak(_dictateAnotherStopMessage());
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _transitService.dispose();
    state.dispose();
  }

  Future<_BusStopResolution> _resolveStopSelection(
    String query,
    NavPoint current,
  ) async {
    final stops = await _transitService.searchStops(
      query: query,
      nearLocation: current,
      limit: 10,
    );
    if (stops.isEmpty) {
      return const _BusStopResolution.choices(<TransitStopCandidate>[]);
    }

    final normalizedQuery = _normalizeStopName(query);
    final exactMatches = stops
        .where((candidate) {
          return _normalizeStopName(candidate.title) == normalizedQuery;
        })
        .toList(growable: false);

    if (exactMatches.isNotEmpty) {
      final preferredMatches = _preferPhysicalStops(exactMatches);
      return _BusStopResolution.selected(
        _nearestStop(current, preferredMatches),
      );
    }

    if (stops.length == 1) {
      return _BusStopResolution.selected(stops.first);
    }

    return _BusStopResolution.choices(stops.take(3).toList(growable: false));
  }

  List<TransitStopCandidate> _preferPhysicalStops(
    List<TransitStopCandidate> candidates,
  ) {
    final platformLevel = candidates
        .where((candidate) => candidate.isPlatformLevel)
        .toList(growable: false);
    return platformLevel.isNotEmpty ? platformLevel : candidates;
  }

  TransitStopCandidate _nearestStop(
    NavPoint origin,
    List<TransitStopCandidate> candidates,
  ) {
    final sorted = List<TransitStopCandidate>.from(candidates);
    sorted.sort((a, b) {
      final distanceA = distanceMeters(origin, a.point);
      final distanceB = distanceMeters(origin, b.point);
      final byDistance = distanceA.compareTo(distanceB);
      if (byDistance != 0) return byDistance;
      if (a.isPlatformLevel != b.isPlatformLevel) {
        return a.isPlatformLevel ? -1 : 1;
      }
      return a.id.compareTo(b.id);
    });
    return sorted.first;
  }

  Future<void> _announceStopRoutes(TransitStopCandidate stop) async {
    final routes = await _transitService.getStopRoutes(
      stop: stop,
      nearLocation: state.value.currentLocation,
    );
    if (routes.isEmpty) {
      final message = _transitStopRoutesUnavailableMessage(stop.title);
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final labels = routes.map(_routeLabel).toList(growable: false);
    final preview = labels.take(6).join(', ');
    final extra = labels.length > 6
        ? _transitExtraRoutesSuffix(labels.length - 6)
        : '';
    final cleanStopName = _stripStopPrefix(stop.title);
    final message = _language == AppLanguage.kk
        ? '$cleanStopName аялдамасында: $preview$extra.'
        : 'На остановке $cleanStopName: $preview$extra.';
    _setState(
      state.value.copyWith(
        status: BusModeStatus.idle,
        candidates: const [],
        lastInstruction: message,
        clearError: true,
      ),
    );
    await _speak(message);
  }

  Future<void> _announceStopSchedule(
    TransitStopCandidate stop,
    String routeName,
  ) async {
    final routes = await _transitService.getStopRoutes(
      stop: stop,
      nearLocation: state.value.currentLocation,
    );
    final availableRoutes = _availableRoutesPreview(routes);
    final normalizedSearch = _normalizeTransitRouteName(routeName);

    var matchingRoutes = routes
        .where((route) {
          return _normalizeTransitRouteName(route.displayName) ==
              normalizedSearch;
        })
        .toList(growable: false);

    if (matchingRoutes.isEmpty) {
      final searchDigits = routeName.replaceAll(RegExp(r'[^0-9]'), '');
      if (searchDigits.isNotEmpty) {
        matchingRoutes = routes
            .where((route) {
              final routeDigits = route.displayName.replaceAll(
                RegExp(r'[^0-9]'),
                '',
              );
              return routeDigits == searchDigits;
            })
            .toList(growable: false);
      }
    }

    if (matchingRoutes.isEmpty) {
      matchingRoutes = routes
          .where((route) {
            final normalizedRoute = _normalizeTransitRouteName(
              route.displayName,
            );
            return normalizedRoute.contains(normalizedSearch) ||
                normalizedSearch.contains(normalizedRoute);
          })
          .toList(growable: false);
    }

    if (matchingRoutes.isEmpty) {
      final message = _routeLooksPresentInStopList(routeName, routes)
          ? _transitScheduleUnavailableMessage(
              routeName: routeName,
              stopName: stop.title,
              availableRoutes: availableRoutes,
            )
          : _transitRouteMissingAtStopMessage(
              routeName: routeName,
              stopName: stop.title,
              availableRoutes: availableRoutes,
            );
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final bestMatch = matchingRoutes.first;
    final entries = await _transitService.getScheduledArrivals(
      stop: stop,
      routeName: bestMatch.displayName,
      nearLocation: state.value.currentLocation,
    );
    if (entries.isEmpty) {
      final message = _transitScheduleUnavailableMessage(
        routeName: bestMatch.displayName,
        stopName: stop.title,
        availableRoutes: availableRoutes,
      );
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final message = _formatTransitScheduleMessage(
      stopName: stop.title,
      routeName: routeName,
      entries: entries,
    );
    _setState(
      state.value.copyWith(
        status: BusModeStatus.idle,
        candidates: const [],
        lastInstruction: message,
        clearError: true,
      ),
    );
    await _speak(message);
  }

  Future<void> _speakCandidateChoices(
    List<TransitStopCandidate> candidates,
  ) async {
    _setState(
      state.value.copyWith(
        status: BusModeStatus.awaitingChoice,
        candidates: candidates,
        clearError: true,
      ),
    );

    final buffer = StringBuffer('${_l10n.navFoundMultipleVariantsIntro} ');
    for (var i = 0; i < candidates.length; i++) {
      buffer.write(
        '${_l10n.navVariantItem(i + 1, _candidatePromptLabel(candidates[i]))} ',
      );
    }
    buffer.write(_l10n.navSayOptionFirstSecondThird);
    await _speak(buffer.toString());
  }

  Future<NavPoint?> _ensureCurrentLocation() async {
    final current = state.value.currentLocation;
    if (current != null) {
      return current;
    }
    try {
      final fresh = await _locationProvider.getCurrentLocation();
      _setState(state.value.copyWith(currentLocation: fresh));
      return fresh;
    } catch (error) {
      _log('[BUS] current location error: $error');
      return null;
    }
  }

  void _onLocationUpdate(NavPoint point) {
    _setState(state.value.copyWith(currentLocation: point));
  }

  void _setState(BusModeState nextState) {
    state.value = nextState;
  }

  void _clearPendingAction() {
    _pendingAction = _PendingBusAction.stopRoutes;
    _pendingRouteName = null;
  }

  String _candidatePromptLabel(TransitStopCandidate candidate) {
    final title = candidate.title.trim();
    final subtitle = candidate.subtitle.trim();
    if (subtitle.isEmpty ||
        subtitle.toLowerCase().contains(title.toLowerCase())) {
      return title;
    }
    final shortSubtitle = subtitle.length > 56
        ? '${subtitle.substring(0, 56)}...'
        : subtitle;
    return '$title, $shortSubtitle';
  }

  String _normalizeStopName(String value) {
    return _stripStopPrefix(
      value,
    ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _routeLabel(TransitRouteSummary route) {
    final name = route.displayName.trim();
    final type = route.transportType.trim().toLowerCase();
    if (type.isEmpty) return name;
    if (_language == AppLanguage.kk) {
      if (type.contains('bus')) return 'автобус $name';
      if (type.contains('tram')) return 'трамвай $name';
      if (type.contains('trolley')) return 'троллейбус $name';
      if (type.contains('shuttle')) return 'маршрутка $name';
      return '$type $name';
    }
    if (type.contains('bus')) return 'автобус $name';
    if (type.contains('tram')) return 'трамвай $name';
    if (type.contains('trolley')) return 'троллейбус $name';
    if (type.contains('shuttle')) return 'маршрутка $name';
    return '$type $name';
  }

  String _formatTransitScheduleMessage({
    required String stopName,
    required String routeName,
    required List<TransitScheduleEntry> entries,
  }) {
    final primary = entries.first;
    final direction = primary.destinationLabel.trim();
    final directionPart = direction.isEmpty
        ? ''
        : _language == AppLanguage.kk
        ? ' $direction бағытымен'
        : ' в сторону $direction';
    final cleanStopName = _stripStopPrefix(stopName);
    final displayRouteName = routeName.toLowerCase().contains('автобус')
        ? routeName
        : 'автобус $routeName';

    if (primary.sourceType == TransitScheduleSourceType.precise &&
        primary.exactTimes.isNotEmpty) {
      final firstTime = primary.exactTimes.first;
      if (_language == AppLanguage.kk) {
        return 'Кесте бойынша $displayRouteName $directionPart $cleanStopName аялдамасына сағат $firstTime келуі тиіс.';
      }
      return 'По расписанию $displayRouteName$directionPart должен прийти на остановку $cleanStopName в $firstTime.';
    }

    final interval = primary.intervalMinutes ?? 0;
    if (_language == AppLanguage.kk) {
      return '2GIS дерегі бойынша $cleanStopName аялдамасында $displayRouteName$directionPart үшін шамамен $interval минуттық интервал көрсетілген, бірақ жақын келу уақыты қазір берілмеді. Мүмкін, қазір рейс жоқ немесе кесте ескірген.';
    }
    return 'По данным 2GIS, для $displayRouteName$directionPart на остановке $cleanStopName указан интервал около $interval минут, но ближайшее прибытие сейчас не показано. Возможно, сейчас рейсов нет или расписание неактуально.';
  }

  String _availableRoutesPreview(List<TransitRouteSummary> routes) {
    if (routes.isEmpty) {
      return '';
    }
    final labels = routes.map(_routeLabel).toList(growable: false);
    final preview = labels.take(6).join(', ');
    final extra = labels.length > 6
        ? _transitExtraRoutesSuffix(labels.length - 6)
        : '';
    return '$preview$extra';
  }

  bool _routeLooksPresentInStopList(
    String routeName,
    List<TransitRouteSummary> routes,
  ) {
    final normalizedSearch = _normalizeTransitRouteName(routeName);
    final searchDigits = routeName.replaceAll(RegExp(r'[^0-9]'), '');
    final looseSearch = routeName.trim().toLowerCase();

    for (final route in routes) {
      final normalizedRoute = _normalizeTransitRouteName(route.displayName);
      if (normalizedRoute == normalizedSearch ||
          normalizedRoute.contains(normalizedSearch) ||
          normalizedSearch.contains(normalizedRoute)) {
        return true;
      }
      final routeDigits = route.displayName.replaceAll(RegExp(r'[^0-9]'), '');
      if (searchDigits.isNotEmpty && routeDigits == searchDigits) {
        return true;
      }
      if (looseSearch.isNotEmpty &&
          route.displayName.toLowerCase().contains(looseSearch)) {
        return true;
      }
    }

    return false;
  }

  String _normalizeTransitRouteName(String routeName) {
    String normalized = routeName.split('(')[0].split('（')[0].trim();
    return normalized
        .toUpperCase()
        .replaceAll('МАРШРУТ', '')
        .replaceAll('АВТОБУС', '')
        .replaceAll(RegExp(r'[^A-Z0-9\u0410-\u044F\u0401\u0451]'), '');
  }

  String _transitUnavailableMessage() {
    return _language == AppLanguage.kk
        ? 'Қазір аялдамалар мен кесте деректері уақытша қолжетімсіз.'
        : 'Сейчас данные по остановкам и расписанию временно недоступны.';
  }

  String _transitStopNotFoundMessage(String stopQuery) {
    return _language == AppLanguage.kk
        ? '$stopQuery аялдамасын таба алмадым.'
        : 'Не удалось найти остановку $stopQuery.';
  }

  String _transitSayStopNamePrompt() {
    return _language == AppLanguage.kk
        ? 'Аялдама атауын айтыңыз.'
        : 'Скажите название остановки.';
  }

  String _transitSchedulePrompt() {
    return _language == AppLanguage.kk
        ? 'Автобус нөмірін және аялдама атауын айтыңыз.'
        : 'Скажите номер автобуса и название остановки.';
  }

  String _transitStopRoutesUnavailableMessage(String stopName) {
    final cleanStopName = _stripStopPrefix(stopName);
    return _language == AppLanguage.kk
        ? '$cleanStopName аялдамасы бойынша маршруттар тізімін ала алмадым.'
        : 'Не удалось получить список маршрутов для остановки $cleanStopName.';
  }

  String _transitRouteMissingAtStopMessage({
    required String routeName,
    required String stopName,
    String availableRoutes = '',
  }) {
    final cleanStopName = _stripStopPrefix(stopName);
    final routesTail = availableRoutes.isEmpty
        ? ''
        : _language == AppLanguage.kk
        ? ' Онда мынадай маршруттар бар: $availableRoutes.'
        : ' На этой остановке ходят: $availableRoutes.';
    return _language == AppLanguage.kk
        ? '2GIS дерегі бойынша $cleanStopName аялдамасында $routeName бағытын бірмәнді растай алмадым.$routesTail'
        : 'По данным 2GIS не удалось однозначно подтвердить, что маршрут $routeName останавливается на остановке $cleanStopName.$routesTail';
  }

  String _transitScheduleUnavailableMessage({
    required String routeName,
    required String stopName,
    String availableRoutes = '',
  }) {
    final cleanStopName = _stripStopPrefix(stopName);
    final routesTail = availableRoutes.isEmpty
        ? ''
        : _language == AppLanguage.kk
        ? ' Онда мынадай маршруттар бар: $availableRoutes.'
        : ' На этой остановке ходят: $availableRoutes.';
    return _language == AppLanguage.kk
        ? '$routeName бағыты $cleanStopName аялдамасында бар, бірақ жақын келу уақытын анықтай алмадым. Мүмкін, қазір рейс жоқ, түнгі үзіліс болып тұр немесе кесте уақытша қолжетімсіз.$routesTail'
        : 'Маршрут $routeName есть на остановке $cleanStopName, но сейчас не удалось определить его ближайшее прибытие. Возможно, сейчас нет активных рейсов, ночной перерыв или расписание временно недоступно.$routesTail';
  }

  String _transitExtraRoutesSuffix(int extraCount) {
    if (extraCount <= 0) return '';
    if (_language == AppLanguage.kk) {
      return ' және тағы $extraCount';
    }
    return ' и ещё $extraCount';
  }

  String _dictateAnotherStopMessage() {
    return _language == AppLanguage.kk
        ? 'Басқа аялдама атауын айтыңыз.'
        : 'Продиктуйте другое название остановки.';
  }

  String _stripStopPrefix(String label) {
    return label
        .replaceFirst(
          RegExp(
            r'^(остановка|аялдама)\s+',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trim();
  }
}
