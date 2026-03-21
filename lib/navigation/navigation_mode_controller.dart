import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_locale_controller.dart';
import '../l10n/app_localizations.dart';
import 'models/navigation_mode_state.dart';
import 'services/dgis_transit_service.dart';
import 'services/instruction_engine.dart';
import 'services/location_provider.dart';
import 'services/navigation_route_service.dart';
import 'services/navigation_utils.dart';

typedef NavigationSpeakFn = Future<void> Function(String text);
typedef NavigationLogFn = void Function(String message);
typedef NavigationInstructionAdapter = String Function(String text);
typedef NavigationRouteBuiltCallback =
    Future<void> Function(NavigationRouteBuiltEvent event);

class NavigationRouteBuiltEvent {
  const NavigationRouteBuiltEvent({
    required this.queryText,
    required this.source,
    required this.resolvedAddress,
    required this.destination,
  });

  final String queryText;
  final String source;
  final String resolvedAddress;
  final NavPoint destination;
}

enum _PendingCandidateAction { routeBuild, stopRoutes, stopSchedule }

class NavigationModeController {
  NavigationModeController({
    required NavigationSpeakFn speak,
    NavigationLogFn? log,
    NavigationRouteService? routeService,
    NavigationTransitService? transitService,
    NavigationLocationProvider? locationProvider,
    InstructionEngine? instructionEngine,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    AppLanguage language = AppLanguage.ru,
    NavigationInstructionAdapter? instructionAdapter,
    NavigationRouteBuiltCallback? onRouteBuilt,
  }) : _speak = speak,
       _log = log ?? debugPrint,
       _routeService = routeService ?? YandexNavigationRouteService(),
       _transitService = transitService ?? DgisTransitService(),
       _locationProvider =
           locationProvider ?? const GeolocatorNavigationLocationProvider(),
       _instructionEngine = instructionEngine ?? InstructionEngine(),
       _launchUrlFn = launchUrlFn ?? launchUrl,
       _instructionAdapter = instructionAdapter,
       _onRouteBuilt = onRouteBuilt,
       _rerouteDistanceMeters = _parseDoubleEnv(
         'NAV_REROUTE_DISTANCE_METERS',
         40,
       ),
       _rerouteCooldown = Duration(
         seconds: _parseIntEnv('NAV_REROUTE_COOLDOWN_SEC', 14),
       ),
       _language = language {
    _instructionEngine.setLanguage(language);
    _routeService.setLanguage(language);
    _transitService.setLanguage(language);
  }

  final NavigationSpeakFn _speak;
  final NavigationLogFn _log;
  final NavigationRouteService _routeService;
  final NavigationTransitService _transitService;
  final NavigationLocationProvider _locationProvider;
  final InstructionEngine _instructionEngine;
  final Future<bool> Function(Uri uri, {LaunchMode mode}) _launchUrlFn;
  NavigationInstructionAdapter? _instructionAdapter;
  final NavigationRouteBuiltCallback? _onRouteBuilt;
  final double _rerouteDistanceMeters;
  final Duration _rerouteCooldown;
  final Duration _offRouteConfirmation = const Duration(seconds: 3);
  AppLanguage _language;

  final ValueNotifier<NavigationModeState> state = ValueNotifier(
    NavigationModeState.initial,
  );

  StreamSubscription<NavPoint>? _positionSubscription;
  DateTime? _offRouteSince;
  DateTime? _lastRerouteAt;
  bool _rerouteInProgress = false;
  String _lastRouteQuery = '';
  String _lastRouteSource = 'manual';
  _PendingCandidateAction _pendingCandidateAction =
      _PendingCandidateAction.routeBuild;
  String? _pendingTransitRouteName;

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    _instructionEngine.setLanguage(language);
    _routeService.setLanguage(language);
    _transitService.setLanguage(language);
  }

  void setInstructionAdapter(NavigationInstructionAdapter? adapter) {
    _instructionAdapter = adapter;
  }

  Future<void> enterMode() async {
    if (state.value.modeEnabled) {
      await _speak(_l10n.navModeAlreadyEnabled);
      return;
    }

    final hasPermission = await _locationProvider.ensurePermission();
    if (!hasPermission) {
      final message = _l10n.navNoLocationPermission;
      _log('[MODE] enter denied: no location permission');
      _setState(
        state.value.copyWith(
          modeEnabled: false,
          navStatus: NavigationStatus.error,
          error: message,
        ),
      );
      await _speak(message);
      return;
    }

    await _positionSubscription?.cancel();
    _positionSubscription = _locationProvider.positionStream().listen(
      _onLocationUpdate,
      onError: (error) {
        _log('[NAV] location stream error: $error');
      },
    );

    final current = await _locationProvider.getCurrentLocation();
    _setState(
      state.value.copyWith(
        modeEnabled: true,
        navStatus: NavigationStatus.idle,
        currentLocation: current,
        clearError: true,
        clearActiveRoute: true,
        candidates: const [],
        clearLastInstruction: true,
      ),
    );
    _log('[MODE] enter');
    await _speak(_l10n.navModeEnabled);
  }

  Future<void> exitMode() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _offRouteSince = null;
    _lastRouteQuery = '';
    _lastRerouteAt = null;
    _rerouteInProgress = false;
    _clearPendingCandidateAction();

    _setState(
      NavigationModeState.initial.copyWith(navStatus: NavigationStatus.idle),
    );
    _log('[MODE] exit');
    await _speak(_l10n.navModeDisabled);
  }

  Future<void> startRoute(String query, {String source = 'manual'}) async {
    return startRouteWithKind(
      query,
      source: source,
      destinationKind: NavigationDestinationKind.generic,
    );
  }

  Future<void> startRouteWithKind(
    String query, {
    String source = 'manual',
    NavigationDestinationKind destinationKind =
        NavigationDestinationKind.generic,
  }) async {
    if (!state.value.modeEnabled) {
      await _speak(_l10n.navEnableFirst);
      return;
    }

    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      await _speak(_l10n.navSayDestinationAfterRouteWords);
      return;
    }

    _lastRouteQuery = cleanQuery;
    _lastRouteSource = source.trim().isEmpty ? 'manual' : source.trim();
    final origin = await _ensureCurrentLocation();
    if (origin == null) {
      await _speak(_l10n.navLocationUnavailable);
      return;
    }

    _setState(
      state.value.copyWith(
        navStatus: NavigationStatus.resolvingDestination,
        clearError: true,
        clearLastInstruction: true,
      ),
    );

    try {
      final candidates = await _resolveCandidates(
        query: cleanQuery,
        origin: origin,
        limit: 3,
        destinationKind: destinationKind,
      );

      if (candidates.isEmpty) {
        _setState(
          state.value.copyWith(
            navStatus: NavigationStatus.error,
            error: _l10n.routeNotFound,
          ),
        );
        await _speak(_l10n.navAddressNotFoundAstana);
        return;
      }

      if (candidates.length == 1) {
        await _buildRoute(candidates.first);
        return;
      }

      _pendingCandidateAction = _PendingCandidateAction.routeBuild;
      _pendingTransitRouteName = null;
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.awaitingChoice,
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
    } on TransitServiceUnavailable catch (error) {
      _log('[NAV] transit stop lookup unavailable: $error');
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.error,
          error: error.toString(),
          clearActiveRoute: true,
        ),
      );
      await _speak(_transitUnavailableMessage());
    } catch (error) {
      _log('[NAV] start error: $error');
      await _handleRouteBuildFailure(error.toString());
    }
  }

  Future<void> selectCandidate(int index) async {
    final candidates = state.value.candidates;
    if (candidates.isEmpty ||
        state.value.navStatus != NavigationStatus.awaitingChoice) {
      await _speak(_l10n.navNoVariantsToChoose);
      return;
    }
    if (index < 0 || index >= candidates.length) {
      await _speak(_l10n.navInvalidVariantNumber);
      return;
    }
    final selected = candidates[index];
    switch (_pendingCandidateAction) {
      case _PendingCandidateAction.routeBuild:
        await _buildRoute(selected);
        return;
      case _PendingCandidateAction.stopRoutes:
        _clearPendingCandidateAction();
        await _announceStopRoutes(selected);
        return;
      case _PendingCandidateAction.stopSchedule:
        final routeName = _pendingTransitRouteName;
        _clearPendingCandidateAction();
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
        state.value.navStatus == NavigationStatus.awaitingChoice;
    if (!hasChoices) {
      await _speak(_l10n.navNoVariantsToCancel);
      return;
    }

    _setState(
      state.value.copyWith(
        navStatus: NavigationStatus.idle,
        candidates: const [],
        clearError: true,
        clearLastInstruction: true,
      ),
    );
    _clearPendingCandidateAction();
    _log('[NAV] candidates rejected');
    await _speak(_l10n.navDictateAnotherAddress);
  }

  Future<void> stopRoute({bool speak = true}) async {
    final hasRoute = state.value.activeRoute != null;
    _offRouteSince = null;
    _rerouteInProgress = false;
    _clearPendingCandidateAction();

    if (hasRoute) {
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.idle,
          clearActiveRoute: true,
          candidates: const [],
          clearError: true,
          lastInstruction: _l10n.navRouteStopped,
        ),
      );
      _log('[NAV] stop');
      if (speak) {
        await _speak(_l10n.navRouteStopped);
      }
      return;
    }

    if (speak) {
      await _speak(_l10n.navNoActiveRoute);
    }
  }

  Future<void> speakStatus() async {
    final current = state.value.currentLocation;
    final route = state.value.activeRoute;

    if (route == null || current == null) {
      await _speak(_l10n.navRouteNotStarted);
      return;
    }

    final destinationDistance = distanceMeters(
      current,
      route.destination.point,
    );
    final nextStep = _nextStep(route);
    final stepDistance = nextStep == null
        ? destinationDistance
        : distanceMeters(current, route.polyline[nextStep.polylineIndex]);

    final summary = _adaptInstruction(
      _l10n.navSummaryDistanceInstruction(
        _formatDistance(destinationDistance),
        nextStep == null
            ? _l10n.navKeepCurrentRoute
            : _instructionEngine.formatDistancePrompt(nextStep, stepDistance),
      ),
    );
    await _speak(summary);
  }

  Future<void> speakNextStep() async {
    final current = state.value.currentLocation;
    final route = state.value.activeRoute;
    if (route == null || current == null) {
      await _speak(_l10n.navRouteNotStarted);
      return;
    }
    final step = _nextStep(route);
    if (step == null) {
      await _speak(_l10n.navRouteAlmostCompleted);
      return;
    }
    final stepPoint = route.polyline[step.polylineIndex];
    final distance = distanceMeters(current, stepPoint);
    final prompt = _adaptInstruction(
      _instructionEngine.formatDistancePrompt(step, distance),
    );
    _setState(state.value.copyWith(lastInstruction: prompt));
    await _speak(prompt);
  }

  Future<void> speakStopRoutes(String query) async {
    if (!state.value.modeEnabled) {
      await _speak(_l10n.navEnableFirst);
      return;
    }
    final stopQuery = query.trim();
    if (stopQuery.isEmpty) {
      await _speak(_transitSayStopNamePrompt());
      return;
    }
    try {
      final candidates = await _resolveTransitStops(stopQuery, limit: 3);
      if (candidates.isEmpty) {
        await _speak(_transitStopNotFoundMessage(stopQuery));
        return;
      }
      if (candidates.length == 1) {
        await _announceStopRoutes(candidates.first);
        return;
      }
      _pendingCandidateAction = _PendingCandidateAction.stopRoutes;
      _pendingTransitRouteName = null;
      await _speakCandidateChoices(candidates);
    } on TransitServiceUnavailable catch (error) {
      _log('[TRANSIT] routes unavailable: $error');
      await _speak(_transitUnavailableMessage());
    } catch (error) {
      _log('[TRANSIT] routes error: $error');
      await _speak(_transitUnavailableMessage());
    }
  }

  Future<void> speakScheduledArrivals({
    required String stopQuery,
    required String routeName,
  }) async {
    if (!state.value.modeEnabled) {
      await _speak(_l10n.navEnableFirst);
      return;
    }
    final cleanStopQuery = stopQuery.trim();
    final cleanRouteName = routeName.trim();
    if (cleanStopQuery.isEmpty || cleanRouteName.isEmpty) {
      await _speak(_transitSchedulePrompt());
      return;
    }
    try {
      final candidates = await _resolveTransitStops(cleanStopQuery, limit: 3);
      if (candidates.isEmpty) {
        await _speak(_transitStopNotFoundMessage(cleanStopQuery));
        return;
      }
      if (candidates.length == 1) {
        await _announceStopSchedule(candidates.first, cleanRouteName);
        return;
      }
      _pendingCandidateAction = _PendingCandidateAction.stopSchedule;
      _pendingTransitRouteName = cleanRouteName;
      await _speakCandidateChoices(candidates);
    } on TransitServiceUnavailable catch (error) {
      _log('[TRANSIT] schedule unavailable: $error');
      await _speak(_transitUnavailableMessage());
    } catch (error) {
      _log('[TRANSIT] schedule error: $error');
      await _speak(_transitUnavailableMessage());
    }
  }

  Future<DestinationCandidate?> resolveDestinationCandidate(
    String query, {
    NavigationDestinationKind destinationKind =
        NavigationDestinationKind.generic,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return null;
    final hasPermission = await _locationProvider.ensurePermission();
    if (!hasPermission) return null;
    final origin = await _ensureCurrentLocation();
    if (origin == null) return null;
    final candidates = await _resolveCandidates(
      query: cleanQuery,
      origin: origin,
      limit: 1,
      destinationKind: destinationKind,
    );
    if (candidates.isEmpty) return null;
    return candidates.first;
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _transitService.dispose();
    state.dispose();
  }

  Future<void> _buildRoute(DestinationCandidate destination) async {
    final origin = await _ensureCurrentLocation();
    if (origin == null) {
      await _speak(_l10n.navLocationUnavailable);
      return;
    }

    _setState(
      state.value.copyWith(
        navStatus: NavigationStatus.buildingRoute,
        clearError: true,
      ),
    );

    try {
      final result = await _routeService.buildPedestrianRoute(
        origin: origin,
        destination: destination.point,
      );

      final route = ActiveRoute(
        destination: destination,
        polyline: result.polyline,
        steps: result.steps,
        totalDistanceMeters: result.totalDistanceMeters,
        estimatedDuration: result.estimatedDuration,
      );

      _offRouteSince = null;
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.navigating,
          activeRoute: route,
          candidates: const [],
          clearError: true,
          lastInstruction: _l10n.navRouteBuilt,
        ),
      );

      _log(
        '[NAV] start destination="${destination.displayLabel}" '
        'distance=${result.totalDistanceMeters.toStringAsFixed(0)}m',
      );

      final etaMinutes = route.estimatedDuration.inMinutes;
      final etaPart = etaMinutes > 0 ? _l10n.navEtaPart(etaMinutes) : '.';
      final intro = _adaptInstruction(
        _l10n.navRouteBuiltWithEta(
          _formatDistance(route.totalDistanceMeters),
          etaPart,
        ),
      );
      await _speak(intro);
      final onRouteBuilt = _onRouteBuilt;
      if (onRouteBuilt != null) {
        await onRouteBuilt(
          NavigationRouteBuiltEvent(
            queryText: _lastRouteQuery,
            source: _lastRouteSource,
            resolvedAddress: destination.displayLabel,
            destination: destination.point,
          ),
        );
      }
      await speakNextStep();
    } catch (error) {
      _log('[NAV] build error: $error');
      await _handleRouteBuildFailure(
        error.toString(),
        destination: destination,
      );
    }
  }

  Future<void> _handleRouteBuildFailure(
    String error, {
    DestinationCandidate? destination,
  }) async {
    _setState(
      state.value.copyWith(
        navStatus: NavigationStatus.error,
        error: error,
        clearActiveRoute: true,
      ),
    );

    await _speak(_l10n.navRouteBuildFailed);
  }

  Future<bool> _openExternalNavigator(DestinationCandidate? destination) async {
    final current = state.value.currentLocation;
    if (current == null) return false;

    final uris = <Uri>[];
    if (destination != null) {
      final from = '${current.latitude},${current.longitude}';
      final to = '${destination.point.latitude},${destination.point.longitude}';
      uris.add(Uri.parse('https://yandex.ru/maps/?rtext=$from~$to&rtt=pd'));
      uris.add(
        Uri.parse(
          'https://2gis.kz/routeSearch/rsType/pedestrian/'
          'from/${current.longitude},${current.latitude}/'
          'to/${destination.point.longitude},${destination.point.latitude}',
        ),
      );
    }

    if (_lastRouteQuery.isNotEmpty) {
      uris.add(
        Uri.parse(
          'https://yandex.ru/maps/?text=${Uri.encodeComponent(_lastRouteQuery)}',
        ),
      );
    }

    for (final uri in uris) {
      try {
        final ok = await _launchUrlFn(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (ok) {
          _log('[NAV] fallback_external $uri');
          return true;
        }
      } catch (_) {}
    }

    return false;
  }

  Future<NavPoint?> _ensureCurrentLocation() async {
    final current = state.value.currentLocation;
    if (current != null) return current;

    try {
      final fresh = await _locationProvider.getCurrentLocation();
      _setState(state.value.copyWith(currentLocation: fresh));
      return fresh;
    } catch (error) {
      _log('[NAV] current location error: $error');
      return null;
    }
  }

  void _onLocationUpdate(NavPoint point) {
    final previous = state.value;
    _setState(previous.copyWith(currentLocation: point));
    final route = state.value.activeRoute;
    if (route == null) return;

    final destinationDistance = distanceMeters(point, route.destination.point);
    if (destinationDistance <= 16) {
      _log('[NAV] completed');
      final arrivalMessage = _arrivalMessageForDestination(route.destination);
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.completed,
          clearActiveRoute: true,
          lastInstruction: arrivalMessage,
          candidates: const [],
        ),
      );
      unawaited(_speak(arrivalMessage));
      return;
    }

    final updatedRoute = _progressRouteByStep(route, point);
    if (updatedRoute != route) {
      _setState(state.value.copyWith(activeRoute: updatedRoute));
    }

    final nextStep = _nextStep(updatedRoute);
    if (nextStep != null) {
      final stepPoint = updatedRoute.polyline[nextStep.polylineIndex];
      final stepDistance = distanceMeters(point, stepPoint);
      if (stepDistance <= 55 &&
          updatedRoute.announcedStepIndex != nextStep.index) {
        final prompt = _adaptInstruction(
          _instructionEngine.formatDistancePrompt(nextStep, stepDistance),
        );
        _setState(
          state.value.copyWith(
            activeRoute: updatedRoute.copyWith(
              announcedStepIndex: nextStep.index,
            ),
            lastInstruction: prompt,
          ),
        );
        _log('[NAV] step $prompt');
        unawaited(_speak(prompt));
      }
    }

    _handleOffRoute(point, updatedRoute);
  }

  ActiveRoute _progressRouteByStep(ActiveRoute route, NavPoint current) {
    var stepIndex = route.currentStepIndex;
    while (stepIndex < route.steps.length - 1) {
      final step = route.steps[stepIndex];
      final stepPoint = route.polyline[step.polylineIndex];
      final distance = distanceMeters(current, stepPoint);
      if (distance > 14) break;
      stepIndex++;
    }

    if (stepIndex == route.currentStepIndex) return route;
    return route.copyWith(currentStepIndex: stepIndex);
  }

  void _handleOffRoute(NavPoint current, ActiveRoute route) {
    final offset = distanceToPolylineMeters(current, route.polyline);
    if (offset <= _rerouteDistanceMeters) {
      _offRouteSince = null;
      return;
    }

    final now = DateTime.now();
    _offRouteSince ??= now;
    final offRouteFor = now.difference(_offRouteSince!);
    if (offRouteFor < _offRouteConfirmation) {
      return;
    }

    if (_rerouteInProgress) return;
    if (_lastRerouteAt != null &&
        now.difference(_lastRerouteAt!) < _rerouteCooldown) {
      return;
    }

    _log('[NAV] offroute offset=${offset.toStringAsFixed(1)}m');
    unawaited(_reroute(route.destination));
  }

  Future<void> _reroute(DestinationCandidate destination) async {
    _rerouteInProgress = true;
    _lastRerouteAt = DateTime.now();
    _offRouteSince = null;

    _setState(state.value.copyWith(navStatus: NavigationStatus.rerouting));
    _log('[NAV] reroute');

    try {
      await _buildRoute(destination);
      if (state.value.navStatus == NavigationStatus.navigating) {
        await _speak(_l10n.navRouteRerouted);
      }
    } finally {
      _rerouteInProgress = false;
    }
  }

  NavStep? _nextStep(ActiveRoute route) {
    if (route.steps.isEmpty) return null;
    final clampedIndex = route.currentStepIndex.clamp(
      0,
      route.steps.length - 1,
    );
    return route.steps[clampedIndex];
  }

  void _setState(NavigationModeState nextState) {
    state.value = nextState;
  }

  static double _parseDoubleEnv(String key, double fallback) {
    final raw = _readEnv(key);
    if (raw.isEmpty) return fallback;
    return double.tryParse(raw) ?? fallback;
  }

  static int _parseIntEnv(String key, int fallback) {
    final raw = _readEnv(key);
    if (raw.isEmpty) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  static String _readEnv(String key) {
    try {
      return (dotenv.env[key] ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  String _formatDistance(double distanceMeters) {
    if (distanceMeters < 1000) {
      return _l10n.distanceFullMeters(
        '${distanceMeters.round().clamp(1, 9999)}',
      );
    }
    final km = distanceMeters / 1000;
    return _l10n.distanceFullKilometers(km.toStringAsFixed(km >= 10 ? 0 : 1));
  }

  String _candidatePromptLabel(DestinationCandidate candidate) {
    final rawTitle = candidate.title.trim();
    final rawSubtitle = candidate.subtitle.trim();
    var title = rawTitle;
    var subtitle = rawSubtitle;

    if (candidate.kind == NavigationDestinationKind.transitStop) {
      final strippedTitle = _stripStopPrefix(rawTitle);
      if (_language == AppLanguage.kk) {
        title = '$strippedTitle аялдамасы';
      } else {
        title = 'Остановка $strippedTitle';
      }
    }

    if (subtitle.isEmpty) return title;
    if (rawTitle.isEmpty) return subtitle;
    if (subtitle.toLowerCase().contains(rawTitle.toLowerCase())) {
      return title;
    }
    final shortSubtitle = subtitle.length > 56
        ? '${subtitle.substring(0, 56)}...'
        : subtitle;
    return '$title, $shortSubtitle';
  }

  String _adaptInstruction(String text) {
    final adapter = _instructionAdapter;
    if (adapter == null) return text;
    final adapted = adapter(text).trim();
    if (adapted.isEmpty) return text;
    return adapted;
  }

  String _arrivalMessageForDestination(DestinationCandidate destination) {
    if (destination.kind != NavigationDestinationKind.transitStop) {
      return _l10n.navArrivedDestination;
    }
    final rawLabel = destination.title.trim().isNotEmpty
        ? destination.title.trim()
        : destination.displayLabel.trim();
    final label = _stripStopPrefix(rawLabel);
    if (_language == AppLanguage.kk) {
      return 'Сіз $label аялдамасына келдіңіз.';
    }
    return 'Вы у остановки $label.';
  }

  Future<List<DestinationCandidate>> _resolveCandidates({
    required String query,
    required NavPoint origin,
    required int limit,
    required NavigationDestinationKind destinationKind,
  }) async {
    if (destinationKind != NavigationDestinationKind.transitStop) {
      _pendingCandidateAction = _PendingCandidateAction.routeBuild;
      _pendingTransitRouteName = null;
      return _routeService.searchCandidates(
        query: query,
        origin: origin,
        limit: limit,
        destinationKind: destinationKind,
      );
    }
    return _resolveTransitStops(query, limit: limit);
  }

  Future<List<DestinationCandidate>> _resolveTransitStops(
    String query, {
    int limit = 3,
  }) async {
    final origin =
        state.value.currentLocation ?? await _ensureCurrentLocation();
    final nearLocation = origin ?? _astanaFallbackLocation();
    final stops = await _transitService.searchStops(
      query: query,
      nearLocation: nearLocation,
      limit: limit,
    );
    return stops
        .map(
          (stop) => DestinationCandidate(
            title: stop.title,
            subtitle: stop.subtitle,
            point: stop.point,
            kind: NavigationDestinationKind.transitStop,
            transitStop: stop,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _speakCandidateChoices(
    List<DestinationCandidate> candidates,
  ) async {
    _setState(
      state.value.copyWith(
        navStatus: NavigationStatus.awaitingChoice,
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

  Future<void> _announceStopRoutes(DestinationCandidate candidate) async {
    final stop = candidate.transitStop;
    if (stop == null) {
      await _speak(_transitUnavailableMessage());
      return;
    }
    final routes = await _transitService.getStopRoutes(
      stop: stop,
      nearLocation: state.value.currentLocation,
    );
    if (routes.isEmpty) {
      final message = _transitStopRoutesUnavailableMessage(candidate.title);
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final labels = routes
        .map((route) => _routeLabel(route))
        .toList(growable: false);
    final preview = labels.take(6).join(', ');
    final extra = labels.length > 6
        ? _transitExtraRoutesSuffix(labels.length - 6)
        : '';
    final cleanStopName = _stripStopPrefix(candidate.title);
    final message = _language == AppLanguage.kk
        ? '$cleanStopName аялдамасында: $preview$extra.'
        : 'На остановке $cleanStopName: $preview$extra.';
    _setState(state.value.copyWith(lastInstruction: message, clearError: true));
    await _speak(message);
  }

  Future<void> _announceStopSchedule(
    DestinationCandidate candidate,
    String routeName,
  ) async {
    final stop = candidate.transitStop;
    if (stop == null) {
      await _speak(_transitUnavailableMessage());
      return;
    }

    final routes = await _transitService.getStopRoutes(
      stop: stop,
      nearLocation: state.value.currentLocation,
    );
    final normalizedRouteName = _normalizeTransitRouteName(routeName);
    final matchingRoute = routes.where((route) {
      return _normalizeTransitRouteName(route.displayName) ==
          normalizedRouteName;
    }).toList();
    if (matchingRoute.isEmpty) {
      final message = _transitRouteMissingAtStopMessage(
        routeName: routeName,
        stopName: candidate.title,
      );
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final entries = await _transitService.getScheduledArrivals(
      stop: stop,
      routeName: routeName,
      nearLocation: state.value.currentLocation,
    );
    if (entries.isEmpty) {
      final message = _transitScheduleUnavailableMessage(
        routeName: routeName,
        stopName: candidate.title,
      );
      _setState(
        state.value.copyWith(lastInstruction: message, clearError: true),
      );
      await _speak(message);
      return;
    }

    final message = _formatTransitScheduleMessage(
      stopName: candidate.title,
      routeName: routeName,
      entries: entries,
    );
    _setState(state.value.copyWith(lastInstruction: message, clearError: true));
    await _speak(message);
  }

  void _clearPendingCandidateAction() {
    _pendingCandidateAction = _PendingCandidateAction.routeBuild;
    _pendingTransitRouteName = null;
  }

  NavPoint _astanaFallbackLocation() {
    return const NavPoint(latitude: 51.1284, longitude: 71.4304);
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
    if (primary.sourceType == TransitScheduleSourceType.precise &&
        primary.exactTimes.isNotEmpty) {
      final exactTimes = primary.exactTimes.take(3).join(', ');
      if (_language == AppLanguage.kk) {
        return 'Кестеге сәйкес, $routeName$directionPart автобусы $cleanStopName аялдамасына $exactTimes уақыттарында келуі тиіс.';
      }
      return 'По расписанию автобус $routeName$directionPart должен приехать на остановку $cleanStopName в $exactTimes.';
    }

    final interval = primary.intervalMinutes ?? 0;
    if (_language == AppLanguage.kk) {
      return 'Кесте бойынша, $routeName$directionPart автобусы $cleanStopName аялдамасына шамамен әр $interval минут сайын келіп тұрады.';
    }
    return 'По расписанию автобус $routeName$directionPart должен приезжать на остановку $cleanStopName примерно каждые $interval минут.';
  }

  String _normalizeTransitRouteName(String routeName) {
    return routeName.replaceAll(RegExp(r'[\s-]+'), '').toUpperCase();
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
  }) {
    final cleanStopName = _stripStopPrefix(stopName);
    return _language == AppLanguage.kk
        ? '$routeName бағыты $cleanStopName аялдамасында табылмады.'
        : 'Маршрут $routeName не найден на остановке $cleanStopName.';
  }

  String _transitScheduleUnavailableMessage({
    required String routeName,
    required String stopName,
  }) {
    final cleanStopName = _stripStopPrefix(stopName);
    return _language == AppLanguage.kk
        ? '$routeName бағыты үшін $cleanStopName аялдамасындағы кестені ала алмадым.'
        : 'Не удалось получить расписание для маршрута $routeName на остановке $cleanStopName.';
  }

  String _transitExtraRoutesSuffix(int extraCount) {
    if (extraCount <= 0) return '';
    if (_language == AppLanguage.kk) {
      return ' және тағы $extraCount';
    }
    return ' и ещё $extraCount';
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
