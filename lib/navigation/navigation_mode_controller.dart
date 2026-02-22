import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_locale_controller.dart';
import '../l10n/app_localizations.dart';
import 'models/navigation_mode_state.dart';
import 'services/instruction_engine.dart';
import 'services/location_provider.dart';
import 'services/navigation_route_service.dart';
import 'services/navigation_utils.dart';

typedef NavigationSpeakFn = Future<void> Function(String text);
typedef NavigationLogFn = void Function(String message);

class NavigationModeController {
  NavigationModeController({
    required NavigationSpeakFn speak,
    NavigationLogFn? log,
    NavigationRouteService? routeService,
    NavigationLocationProvider? locationProvider,
    InstructionEngine? instructionEngine,
    Future<bool> Function(Uri uri, {LaunchMode mode})? launchUrlFn,
    AppLanguage language = AppLanguage.ru,
  }) : _speak = speak,
       _log = log ?? debugPrint,
       _routeService = routeService ?? YandexNavigationRouteService(),
       _locationProvider =
           locationProvider ?? const GeolocatorNavigationLocationProvider(),
       _instructionEngine = instructionEngine ?? InstructionEngine(),
       _launchUrlFn = launchUrlFn ?? launchUrl,
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
  }

  final NavigationSpeakFn _speak;
  final NavigationLogFn _log;
  final NavigationRouteService _routeService;
  final NavigationLocationProvider _locationProvider;
  final InstructionEngine _instructionEngine;
  final Future<bool> Function(Uri uri, {LaunchMode mode}) _launchUrlFn;
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

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  void setLanguage(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    _instructionEngine.setLanguage(language);
    _routeService.setLanguage(language);
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

    _setState(
      NavigationModeState.initial.copyWith(navStatus: NavigationStatus.idle),
    );
    _log('[MODE] exit');
    await _speak(_l10n.navModeDisabled);
  }

  Future<void> startRoute(String query) async {
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
      final candidates = await _routeService.searchCandidates(
        query: cleanQuery,
        origin: origin,
        limit: 3,
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
    await _buildRoute(candidates[index]);
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
    _log('[NAV] candidates rejected');
    await _speak(_l10n.navDictateAnotherAddress);
  }

  Future<void> stopRoute({bool speak = true}) async {
    final hasRoute = state.value.activeRoute != null;
    _offRouteSince = null;
    _rerouteInProgress = false;

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

    final summary = _l10n.navSummaryDistanceInstruction(
      _formatDistance(destinationDistance),
      nextStep == null
          ? _l10n.navKeepCurrentRoute
          : _instructionEngine.formatDistancePrompt(nextStep, stepDistance),
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
    final prompt = _instructionEngine.formatDistancePrompt(step, distance);
    _setState(state.value.copyWith(lastInstruction: prompt));
    await _speak(prompt);
  }

  Future<void> dispose() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
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
      final intro = _l10n.navRouteBuiltWithEta(
        _formatDistance(route.totalDistanceMeters),
        etaPart,
      );
      await _speak(intro);
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

    final fallbackOpened = await _openExternalNavigator(destination);
    if (fallbackOpened) {
      await _speak(_l10n.navRouteBuildFailedOpenExternal);
      return;
    }

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
      _setState(
        state.value.copyWith(
          navStatus: NavigationStatus.completed,
          clearActiveRoute: true,
          lastInstruction: _l10n.navArrivedDestination,
          candidates: const [],
        ),
      );
      unawaited(_speak(_l10n.navArrivedDestination));
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
        final prompt = _instructionEngine.formatDistancePrompt(
          nextStep,
          stepDistance,
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
    final title = candidate.title.trim();
    final subtitle = candidate.subtitle.trim();
    if (subtitle.isEmpty) return title;
    if (title.isEmpty) return subtitle;
    if (subtitle.toLowerCase().contains(title.toLowerCase())) {
      return title;
    }
    final shortSubtitle = subtitle.length > 56
        ? '${subtitle.substring(0, 56)}...'
        : subtitle;
    return '$title, $shortSubtitle';
  }
}
