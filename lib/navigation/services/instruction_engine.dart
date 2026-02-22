import '../../l10n/app_locale_controller.dart';
import '../../l10n/app_localizations.dart';
import '../models/navigation_mode_state.dart';
import 'navigation_utils.dart';

class InstructionEngine {
  InstructionEngine({AppLanguage language = AppLanguage.ru})
    : _language = language;

  AppLanguage _language;

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  AppLocalizations get _l10n => lookupAppLocalizations(_language.locale);

  List<NavStep> buildSteps(List<NavPoint> polyline) {
    if (polyline.length < 2) return const [];

    final cumulative = _buildCumulativeDistances(polyline);
    final steps = <NavStep>[];
    var stepIndex = 0;

    for (var i = 1; i < polyline.length - 1; i++) {
      final previous = polyline[i - 1];
      final current = polyline[i];
      final next = polyline[i + 1];

      final bearingIn = bearingDegrees(previous, current);
      final bearingOut = bearingDegrees(current, next);
      final delta = normalizeDeltaDegrees(bearingOut - bearingIn);
      final absDelta = delta.abs();

      if (absDelta < 35) {
        continue;
      }

      final maneuver = absDelta >= 150
          ? NavManeuverType.uTurn
          : (delta < 0 ? NavManeuverType.turnLeft : NavManeuverType.turnRight);

      steps.add(
        NavStep(
          index: stepIndex++,
          polylineIndex: i,
          maneuverType: maneuver,
          instruction: _instructionForManeuver(maneuver),
          distanceFromRouteStartMeters: cumulative[i],
        ),
      );
    }

    steps.add(
      NavStep(
        index: stepIndex,
        polylineIndex: polyline.length - 1,
        maneuverType: NavManeuverType.arrive,
        instruction: _l10n.instructionArrive,
        distanceFromRouteStartMeters: cumulative.last,
      ),
    );

    return steps;
  }

  String formatDistancePrompt(NavStep step, double distanceMeters) {
    if (step.maneuverType == NavManeuverType.arrive) {
      if (distanceMeters <= 15) return _l10n.instructionArrivedToDestination;
      return _l10n.instructionDistanceToDestination(
        _formatDistance(distanceMeters),
      );
    }

    if (distanceMeters <= 12) {
      return step.instruction;
    }

    return _l10n.instructionInDistance(
      _formatDistance(distanceMeters),
      step.instruction.toLowerCase(),
    );
  }

  String _instructionForManeuver(NavManeuverType maneuver) {
    switch (maneuver) {
      case NavManeuverType.turnLeft:
        return _l10n.instructionTurnLeft;
      case NavManeuverType.turnRight:
        return _l10n.instructionTurnRight;
      case NavManeuverType.uTurn:
        return _l10n.instructionUTurn;
      case NavManeuverType.arrive:
        return _l10n.instructionArrive;
      case NavManeuverType.straight:
        return _l10n.instructionGoStraight;
    }
  }

  List<double> _buildCumulativeDistances(List<NavPoint> polyline) {
    final cumulative = List<double>.filled(polyline.length, 0);
    var total = 0.0;
    for (var i = 1; i < polyline.length; i++) {
      total += distanceMeters(polyline[i - 1], polyline[i]);
      cumulative[i] = total;
    }
    return cumulative;
  }

  String _formatDistance(double distanceMeters) {
    if (distanceMeters < 1000) {
      final rounded = distanceMeters.round().clamp(1, 9999);
      return _l10n.distanceShortMeters('$rounded');
    }
    final km = distanceMeters / 1000;
    return _l10n.distanceShortKilometers(km.toStringAsFixed(km >= 10 ? 0 : 1));
  }
}
