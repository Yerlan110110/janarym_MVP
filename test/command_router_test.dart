import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/logic/command_router.dart';
import 'package:janarym_app2/navigation/models/navigation_mode_state.dart';

void main() {
  group('CommandRouter', () {
    final router = CommandRouter();

    test('parses enter navigation mode intent', () {
      final decision = router.route('Жанарым, включи режим маршрута');
      expect(decision.modeIntent, AssistantModeIntent.enterNavMode);
    });

    test('parses exit navigation mode intent', () {
      final decision = router.route('выйти из режима маршрута');
      expect(decision.modeIntent, AssistantModeIntent.exitNavMode);
    });

    test('parses enter bus mode intent', () {
      final decision = router.route('включи режим автобуса');
      expect(decision.modeIntent, AssistantModeIntent.enterBusMode);
    });

    test('parses exit bus mode intent', () {
      final decision = router.route('выйти из режима автобуса');
      expect(decision.modeIntent, AssistantModeIntent.exitBusMode);
    });

    test('parses nav start and extracts destination', () {
      final decision = router.route('маршрут до абая 10 алматы');
      expect(decision.modeIntent, AssistantModeIntent.navStart);
      expect(decision.destinationQuery, 'абая 10 алматы');
      expect(decision.destinationKindHint, NavigationDestinationKind.generic);
    });

    test('parses route to stop as transit stop destination', () {
      final decision = router.route('маршрут до остановки университет');
      expect(decision.modeIntent, AssistantModeIntent.navStart);
      expect(decision.destinationQuery, 'университет');
      expect(
        decision.destinationKindHint,
        NavigationDestinationKind.transitStop,
      );
    });

    test('parses stop routes query', () {
      final decision = router.route('какие маршруты на остановке университет');
      expect(decision.modeIntent, AssistantModeIntent.busStopRoutes);
      expect(decision.destinationQuery, 'университет');
      expect(
        decision.destinationKindHint,
        NavigationDestinationKind.transitStop,
      );
    });

    test('parses stop schedule query', () {
      final decision = router.route(
        'когда автобус 10 на остановке университет',
      );
      expect(decision.modeIntent, AssistantModeIntent.busStopSchedule);
      expect(decision.destinationQuery, 'университет');
      expect(decision.transitRouteName, '10');
      expect(
        decision.destinationKindHint,
        NavigationDestinationKind.transitStop,
      );
    });

    test('parses reordered stop schedule query with route number word', () {
      final decision = router.route(
        'когда придет автобус номер 10 на остановку университет',
      );
      expect(decision.modeIntent, AssistantModeIntent.busStopSchedule);
      expect(decision.destinationQuery, 'университет');
      expect(decision.transitRouteName, '10');
    });

    test('parses stop-first stop schedule query', () {
      final decision = router.route(
        'на остановке университет когда придет автобус 10',
      );
      expect(decision.modeIntent, AssistantModeIntent.busStopSchedule);
      expect(decision.destinationQuery, 'университет');
      expect(decision.transitRouteName, '10');
    });

    test('parses through-how-long stop schedule query', () {
      final decision = router.route(
        'через сколько придет автобус 10 на остановку университет',
      );
      expect(decision.modeIntent, AssistantModeIntent.busStopSchedule);
      expect(decision.destinationQuery, 'университет');
      expect(decision.transitRouteName, '10');
    });

    test('does not confuse route to stop with route to saved label', () {
      final decision = router.route('маршрут до остановки университет');
      expect(decision.modeIntent, isNot(AssistantModeIntent.routeToPlaceLabel));
    });

    test('parses nav status and next-step commands', () {
      expect(
        router.route('статус маршрута').modeIntent,
        AssistantModeIntent.navStatus,
      );
      expect(
        router.route('что дальше').modeIntent,
        AssistantModeIntent.navNextStep,
      );
    });

    test('parses repeat and vision commands', () {
      expect(router.route('повтори').modeIntent, AssistantModeIntent.repeat);
      final vision = router.route('что справа');
      expect(vision.modeIntent, AssistantModeIntent.visionDescribe);
      expect(vision.directionRu, 'справа');
    });

    test('parses explicit read-text action commands', () {
      expect(router.route('прочитай').modeIntent, AssistantModeIntent.readText);
      expect(
        router.route('прочитать текст').modeIntent,
        AssistantModeIntent.readText,
      );
    });

    test('parses explicit voice-language switch commands', () {
      expect(
        router.route('қазақша жауап бер').modeIntent,
        AssistantModeIntent.switchVoiceLanguage,
      );
      expect(
        router.route('на русском').modeIntent,
        AssistantModeIntent.switchVoiceLanguage,
      );
    });

    test('extracts candidate choice index', () {
      final second = router.route('второй вариант');
      expect(second.candidateChoiceIndex, 1);

      final first = router.route('первый');
      expect(first.candidateChoiceIndex, 0);

      final third = router.route('номер три');
      expect(third.candidateChoiceIndex, 2);
    });

    test('parses candidate reject command', () {
      final reject = router.route('никакой');
      expect(reject.modeIntent, AssistantModeIntent.navRejectChoice);
    });

    test('parses kazakh navigation commands', () {
      expect(
        router.route('маршрут режимін қос').modeIntent,
        AssistantModeIntent.enterNavMode,
      );
      expect(
        router.route('маршрут режимінен шық').modeIntent,
        AssistantModeIntent.exitNavMode,
      );
      expect(
        router.route('маршрут құр қабанбай батыр 60/9').modeIntent,
        AssistantModeIntent.navStart,
      );
      expect(
        router.route('маршрут күйі').modeIntent,
        AssistantModeIntent.navStatus,
      );
      expect(
        router.route('әрі қарай не').modeIntent,
        AssistantModeIntent.navNextStep,
      );
      expect(
        router.route('ешқайсысы').modeIntent,
        AssistantModeIntent.navRejectChoice,
      );
      expect(
        router.route('аялдамаға дейін маршрут университет').modeIntent,
        AssistantModeIntent.navStart,
      );
      expect(
        router.route('аялдамаға дейін маршрут университет').destinationKindHint,
        NavigationDestinationKind.transitStop,
      );
      expect(
        router.route('аялдама университет қандай маршруттар').modeIntent,
        AssistantModeIntent.busStopRoutes,
      );
      expect(
        router.route('аялдама университет автобус 10 қашан').modeIntent,
        AssistantModeIntent.busStopSchedule,
      );
    });

    test('parses kazakh describe and choice commands', () {
      final direction = router.route('оң жақта не бар');
      expect(direction.modeIntent, AssistantModeIntent.visionDescribe);
      expect(direction.directionRu, 'справа');

      final first = router.route('бірінші нұсқа');
      expect(first.candidateChoiceIndex, 0);
      final second = router.route('екінші');
      expect(second.candidateChoiceIndex, 1);
      final third = router.route('үшінші');
      expect(third.candidateChoiceIndex, 2);
    });

    test('parses yes/no confirmation intents', () {
      final yes = router.route('да правильно');
      expect(yes.modeIntent, AssistantModeIntent.confirmYes);
      expect(yes.isAffirmative, isTrue);

      final no = router.route('жоқ қате');
      expect(no.modeIntent, AssistantModeIntent.confirmNo);
      expect(no.isNegative, isTrue);
    });

    test('parses label and fear intents', () {
      final label = router.route('поставь метку дом адрес абая 10');
      expect(label.modeIntent, AssistantModeIntent.setPlaceLabel);
      expect(label.placeLabelName, contains('дом'));
      expect(label.freeAddressText, contains('абая 10'));

      final fear = router.route('я боюсь пешеходных переходов');
      expect(fear.modeIntent, AssistantModeIntent.updateUserFear);
      expect(fear.fearText, contains('пешеходных переходов'));
    });

    test('parses onboarding intent', () {
      final intent = router.route('давай пройти персонализацию');
      expect(intent.modeIntent, AssistantModeIntent.startOnboarding);
    });

    test('strips aggressive wake variants before routing', () {
      expect(
        router.stripWakeWords('женарим включи режим маршрута'),
        'включи режим маршрута',
      );
      expect(
        router.route('джанар начни опрос').modeIntent,
        AssistantModeIntent.startOnboarding,
      );
    });

    test('parses explicit onboarding start phrases', () {
      expect(
        router.route('начни опрос').modeIntent,
        AssistantModeIntent.startOnboarding,
      );
      expect(
        router.route('давай начнем опрос').modeIntent,
        AssistantModeIntent.startOnboarding,
      );
    });

    test('parses restart onboarding intent', () {
      final intent = router.route('начать сначала');
      expect(intent.modeIntent, AssistantModeIntent.restartOnboarding);
    });
  });
}
